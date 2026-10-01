import AVFoundation
import CoreText
import Vision
import XCTest
import LoupecastCore
@testable import LoupecastRender

/// Runs the real export on a synthetic recording (no screen permission needed).
final class ExportTests: XCTestCase {
    static let size = CGSize(width: 1600, height: 1000)   // 16:10 like a laptop panel
    static let duration = 10.0
    static let outDir: URL = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build/loupecast-test")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Square position (normalized, top-left origin) at time t; the cursor follows it.
    static let display = DisplayBounds(x: -1600, y: 0, width: 800, height: 520, topInset: 20)

    static func target(_ t: Double) -> Point {
        let tt = (4...6).contains(t) ? 4 : (t > 6 ? t - 2 : t)   // frozen while the screen is static
        return Point(x: 0.15 + 0.7 * (tt / 8), y: 0.35 + 0.15 * sin(tt))
    }

    // MARK: synthetic project

    func makeProject() -> Project {
        let host0 = CMClockGetTime(CMClockGetHostTimeClock()).seconds   // same clock SCStream stamps with
        var log = InputLog()
        // a secondary 2× display whose 20 pt menu bar is left out: the movie is the 800×500 pt below it
        let d = Self.display
        func g(_ p: Point) -> (Double, Double) { (d.x + p.x * d.width, d.y + d.topInset + p.y * (d.height - d.topInset)) }
        for i in stride(from: -30, through: 630, by: 1) {                 // 60 Hz, starts before the session
            let t = Double(i) / 60, (x, y) = g(Self.target(max(0, t)))
            log.append(.init(host: host0 + t, gx: x, gy: y, kind: .move))
        }
        for t in [3.0, 3.5] {
            let (x, y) = g(Self.target(t))
            log.append(.init(host: host0 + t, gx: x, gy: y, kind: .click(.left)))
        }
        log.append(.init(host: host0 - 0.5, gx: -1500, gy: 10, kind: .click(.left)))   // before session start
        log.append(.init(host: host0 + 12, gx: -1500, gy: 10, kind: .click(.left)))    // after stop
        log.append(.init(host: host0 + 1, gx: 0, gy: 0, kind: .key(0)))
        let r = log.relativized(sessionStartHost: host0, duration: Self.duration, display: d)
        var p = Project(name: "Synthetic", duration: Self.duration, pixelWidth: Int(Self.size.width),
                        pixelHeight: Int(Self.size.height), pointPixelScale: 2,
                        cursor: r.cursor, clicks: r.clicks, keys: r.keys)
        p.setTrimIn(2.0)
        p.setTrimOut(7.5)
        return p
    }

    func testEventTimesAreRecordingRelative() throws {
        let p = makeProject()
        XCTAssertEqual(p.clicks.count, 2)
        XCTAssertEqual(p.clicks.map(\.t), [3.0, 3.5].map { $0 }, accuracy: 1e-6)
        // normalized against the cropped capture rect: the stored click is exactly where the square was
        XCTAssertEqual(p.clicks.map(\.x), [3.0, 3.5].map { Self.target($0).x }, accuracy: 1e-9)
        XCTAssertEqual(p.clicks.map(\.y), [3.0, 3.5].map { Self.target($0).y }, accuracy: 1e-9)
        XCTAssertEqual(Self.display.pixelSize(scale: 2).width, Int(Self.size.width))
        XCTAssertEqual(Self.display.pixelSize(scale: 2).height, Int(Self.size.height))
        for t in p.clicks.map(\.t) + p.cursor.map(\.t) + p.keys.map(\.t) {
            XCTAssertGreaterThanOrEqual(t, 0); XCTAssertLessThanOrEqual(t, p.duration)
        }
        // stored project file has only relative seconds: no value anywhere near host uptime
        let url = Self.outDir.appendingPathComponent("synthetic-project.json")
        try p.save(to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("\"host\""))
        XCTAssertLessThanOrEqual(try Project.load(from: url).clicks.map(\.t).max() ?? 0, p.duration)
    }

    func testExportMatchesTrim() async throws {
        let mov = Self.outDir.appendingPathComponent("synthetic.mov")
        try await Self.writeSyntheticMovie(to: mov)
        let project = makeProject()
        XCTAssertEqual(project.zooms.count, 1, "two nearby clicks → one zoom")
        try project.save(to: Self.outDir.appendingPathComponent("project.json"))

        let out = Self.outDir.appendingPathComponent("export.mp4")
        let start = Date()
        try await Exporter.export(project: project, videoURL: mov, to: out)
        print("export took \(Date().timeIntervalSince(start)) s → \(out.path)")

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 5.5, accuracy: 1.0 / 60, "duration \(duration)")

        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let v = try XCTUnwrap(video.first)
        let (natural, nominal, fmts) = try await v.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        XCTAssertEqual(natural, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(Double(nominal), 60, accuracy: 0.01)
        let fmt = try XCTUnwrap(fmts.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fmt), kCMVideoCodecType_H264)

        // actual frames: count and spacing, read without decoding
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(o)
        XCTAssertTrue(reader.startReading())
        var pts: [Double] = []
        while let b = o.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(b) > 0 { pts.append(CMSampleBufferGetPresentationTimeStamp(b).seconds) }
        }
        pts.sort()
        XCTAssertEqual(pts.count, 330, "5.5 s × 60 fps")
        let gaps = zip(pts.dropFirst(), pts).map { $0 - $1 }
        XCTAssertEqual(gaps.max() ?? 0, 1.0 / 60, accuracy: 1e-4, "constant 60 fps, static part duplicated")
        XCTAssertEqual(gaps.min() ?? 0, 1.0 / 60, accuracy: 1e-4)
        XCTAssertEqual(pts.first ?? -1, 0, accuracy: 1e-6)

        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "system + mic mixed into one track")
        let (afmts, arange) = try await audio[0].load(.formatDescriptions, .timeRange)
        let afmt = try XCTUnwrap(afmts.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(afmt)?.pointee)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(arange.duration.seconds, 5.5, accuracy: 1.0 / 60)

        try await assertClickInsideZoom(export: asset, project: project)
    }

    /// Export time 2.0 s = recording 4.0 s, inside the zoom from the clicks at 3.0/3.5 s. The blue
    /// square (where the cursor clicked) must be visible in the zoomed frame, where camera(t) puts it.
    func assertClickInsideZoom(export asset: AVURLAsset, project: Project) async throws {
        let t = 4.0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let cg = try await gen.image(at: CMTime(seconds: t - project.trimIn, preferredTimescale: 600)).image
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, r = px[i], g = px[i + 1], b = px[i + 2]
            if r < 70, g > 90, g < 180, b > 210 { sx += Double(x); sy += Double(y); n += 1 }   // the blue square
        } }
        XCTAssertGreaterThan(n, 1000, "blue square not found in the zoomed export frame")
        let cam = CameraPath(project: project).camera(at: t)
        XCTAssertEqual(cam.scale, 2, accuracy: 1e-6, "the click zoom is fully in at \(t) s")
        let frame = LoupecastCompositor.frameRect(source: Self.size, canvas: Composer.renderSize, style: .standard)
        let p = Self.target(t), half = 0.5 / cam.scale
        let u = (p.x - (cam.center.x - half)) * cam.scale, v = (p.y - (cam.center.y - half)) * cam.scale
        XCTAssertTrue((0...1).contains(u) && (0...1).contains(v), "click point outside the zoom rect: \(u), \(v)")
        let expected = (x: frame.minX + u * frame.width, y: (Composer.renderSize.height - frame.maxY) + v * frame.height)
        print("zoom check: square at (\(sx / n), \(sy / n)) px, camera(t) predicts (\(expected.x), \(expected.y)), window uv (\(u), \(v))")
        XCTAssertEqual(sx / n, expected.x, accuracy: 4)
        XCTAssertEqual(sy / n, expected.y, accuracy: 4)
    }

    // MARK: cut list (REVISION 3)

    /// Clips [1,3] and [5,8] concatenated: 5.0 s, and composition 2.0 s is recording 5.0 s.
    func testExportConcatenatesClips() async throws {
        let mov = Self.outDir.appendingPathComponent("synthetic-cuts.mov")
        try await Self.writeSyntheticMovie(to: mov, staticScreen: false)   // every frame shows its own time
        var project = makeProject()
        project.clips = [ClipRange(start: 1, end: 3), ClipRange(start: 5, end: 8)]
        let out = Self.outDir.appendingPathComponent("export-cuts.mp4")
        try await Exporter.export(project: project, videoURL: mov, to: out)

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 5.0, accuracy: 1.0 / 60, "sum of clip lengths, got \(duration)")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let v = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(o)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let b = o.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(b) }
        XCTAssertEqual(frames, 300, "5.0 s × 60 fps")

        // burned-in timecode on both sides of the cut
        for (c, expected) in [(1.0, "2.00"), (1.0 + 59.0 / 60, "2.98"), (2.0, "5.00"), (4.5, "7.50")] {
            let text = try await Self.timecode(in: asset, at: c)
            print("frame at composition \(c) s reads \(text ?? "nothing")")
            XCTAssertEqual(text, expected, "composition \(c) s should show recording \(expected) s")
        }

        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "audio track present")
        // 10 ms fade out/in at the cut: the tone dips to silence at composition 2.0 instead of jumping
        let pcm = try await Self.monoSamples(asset)
        func level(_ a: Double, _ b: Double) -> Double {
            let s = pcm[Int(a * 48_000)..<Int(b * 48_000)]
            return s.map { abs(Double($0)) }.reduce(0, +) / Double(s.count)
        }
        print("exported audio, 2 ms bins from 1.986 s:", stride(from: 1.986, to: 2.014, by: 0.002).map { String(format: "%.2f", level($0, $0 + 0.002)) }.joined(separator: " "))
        let steady = level(1.5, 1.6)
        XCTAssertGreaterThan(steady, 0.3)
        XCTAssertLessThan(level(1.999, 2.001), steady * 0.25, "faded to silence at the cut")
        XCTAssertEqual(level(1.97, 1.985), steady, accuracy: steady * 0.08, "full level before the fade")
        XCTAssertEqual(level(2.015, 2.03), steady, accuracy: steady * 0.08, "full level after the fade-in")
        XCTAssertEqual(cutGain(at: 1.995, cuts: [2]), 0.5, accuracy: 1e-9)
        XCTAssertEqual(cutGain(at: 2.0, cuts: [2]), 0)
        XCTAssertEqual(cutGain(at: 2.02, cuts: [2]), 1)
    }

    /// The "t = 0.00 s" label, read with Vision.
    static func timecode(in asset: AVURLAsset, at seconds: Double) async throws -> String? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let cg = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        for s in strings {
            if let r = s.range(of: #"\d+\.\d\d"#, options: .regularExpression), s.contains("=") { return String(s[r]) }
        }
        return nil
    }

    static var pcmSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ] }

    /// Decoded audio of the exported file, first channel.
    static func monoSamples(_ asset: AVURLAsset) async throws -> [Float] {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: pcmSettings)
        reader.add(o)
        XCTAssertTrue(reader.startReading())
        return firstChannel(o)
    }

    static func firstChannel(_ o: AVAssetReaderOutput) -> [Float] {
        var out: [Float] = []
        while let b = o.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(b) {
            var length = 0, pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { f in
                for i in stride(from: 0, to: length / 4, by: 2) { out.append(f[i]) }
            }
        }
        return out
    }

    // MARK: synthetic movie

    static func writeSyntheticMovie(to url: URL, staticScreen: Bool = true) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(size.width), h = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(vIn)
        let sys = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        writer.add(sys); writer.add(mic)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // interleave audio and video, or the writer stalls one input waiting for the other
        let rate = 48_000, total = Int(duration) * rate
        var audioFrame = 0
        func feedAudio(until t: Double) async throws {
            while audioFrame < min(total, Int(t * Double(rate))) {
                let n = min(1024, total - audioFrame)
                for (input, channels, amp) in [(sys, 2, 0.4), (mic, 1, 0.2)] {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                    input.append(tone(start: audioFrame, count: n, channels: channels, amplitude: amp))
                }
                audioFrame += n
            }
        }
        for i in 0..<Int(duration * 60) {
            let t = Double(i) / 60
            try await feedAudio(until: t + 0.25)
            if staticScreen, t >= 4, t < 6, i != 240 { continue }   // static screen: SCStream sends no complete frames
            while !vIn.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            draw(into: pb!, t: t)
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 60))
        }
        try await feedAudio(until: duration)
        vIn.markAsFinished(); sys.markAsFinished(); mic.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    /// A fake desktop: window with text rows, a blue square the cursor follows, and a big time label.
    static func draw(into pb: CVPixelBuffer, t: Double) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let H = CGFloat(h)
        func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect { CGRect(x: x, y: H - y - rh, width: rw, height: rh) }
        ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.24, blue: 0.36, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(rect(120, 90, 1360, 820))
        ctx.setFillColor(CGColor(gray: 0.88, alpha: 1)); ctx.fill(rect(120, 90, 1360, 56))
        for (k, c) in [(0, CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1)), (1, CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1)), (2, CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1))] {
            ctx.setFillColor(c); ctx.fillEllipse(in: rect(146 + CGFloat(k) * 34, 108, 20, 20))
        }
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        for row in 0..<12 { ctx.fill(rect(180, 200 + CGFloat(row) * 52, CGFloat(500 + (row * 137) % 600), 18)) }
        let p = target(t)
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1))
        ctx.fill(rect(CGFloat(p.x) * CGFloat(w) - 40, CGFloat(p.y) * H - 40, 80, 80))
        let label = String(format: "t = %.2f s", t)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 64, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)]))
        ctx.textPosition = CGPoint(x: 900, y: H - 860)
        CTLineDraw(line, ctx)
    }

    /// 1 kHz sine, float32 interleaved, as an LPCM sample buffer.
    static func tone(start: Int, count: Int, channels: Int, amplitude: Double) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var samples = [Float](repeating: 0, count: count * channels)
        for i in 0..<count {
            let v = Float(amplitude * sin(2 * .pi * 1000 * Double(start + i) / 48_000))
            for c in 0..<channels { samples[i * channels + c] = v }
        }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!,
                                                             sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb!
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
