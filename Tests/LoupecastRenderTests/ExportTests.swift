import AVFoundation
import CoreText
import UniformTypeIdentifiers
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

    /// An 800 × 500 pt area of a 2× display (area recording): the movie is that rect.
    static let areaDisplay = DisplayBounds(x: 300, y: -900, width: 1200, height: 900, area: Rect(x: 150, y: 220, width: 800, height: 500))

    static func makeProject(display d: DisplayBounds = display) -> Project {
        let host0 = CMClockGetTime(CMClockGetHostTimeClock()).seconds   // same clock SCStream stamps with
        var log = InputLog()
        // a secondary 2× display whose 20 pt menu bar is left out: the movie is the 800×500 pt below it
        let cap = d.captureRect
        func g(_ p: Point) -> (Double, Double) { (d.x + cap.x + p.x * cap.width, d.y + cap.y + p.y * cap.height) }
        if d.area != nil { log.append(.init(host: host0 + 5, gx: d.x + 20, gy: d.y + 20, kind: .click(.left))) }   // outside the area
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
        let r = log.relativized(sessionStartHost: host0, duration: Self.duration, display: d)
        var p = Project(name: "Synthetic", duration: Self.duration, pixelWidth: Int(Self.size.width),
                        pixelHeight: Int(Self.size.height), pointPixelScale: 2,
                        cursor: r.cursor, clicks: r.clicks)
        p.setTrimIn(2.0)
        p.setTrimOut(7.5)
        return p
    }

    func testEventTimesAreRecordingRelative() throws {
        let p = Self.makeProject()
        XCTAssertEqual(p.clicks.count, 2)
        XCTAssertEqual(p.clicks.map(\.t), [3.0, 3.5].map { $0 }, accuracy: 1e-6)
        // normalized against the cropped capture rect: the stored click is exactly where the square was
        XCTAssertEqual(p.clicks.map(\.x), [3.0, 3.5].map { Self.target($0).x }, accuracy: 1e-9)
        XCTAssertEqual(p.clicks.map(\.y), [3.0, 3.5].map { Self.target($0).y }, accuracy: 1e-9)
        XCTAssertEqual(Self.display.pixelSize(scale: 2).width, Int(Self.size.width))
        XCTAssertEqual(Self.display.pixelSize(scale: 2).height, Int(Self.size.height))
        for t in p.clicks.map(\.t) + p.cursor.map(\.t) {
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
        // GitHub's macOS VMs have no hardware scaler/encoder (AppleM2ScalerParavirtDriver missing) and the
        // video pipeline hangs there; these run locally on real hardware.
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.exportMatchesTrim() }
    }

    /// The same checks for a 9:16 export: 1080×1920, same length and frame count, the click still inside the zoom.
    func testPortraitExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.exportMatchesTrim(.portrait) }
    }

    /// Area recording: the click inside the area zooms where camera(t) says, the click outside makes no zoom.
    func testAreaRecordingExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.exportMatchesTrim(display: Self.areaDisplay) }
    }

    /// A zoom set to 300 %: the export magnifies three times, with the square where camera(t) puts it.
    func testZoomLevelExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.exportMatchesTrim(zoomScale: 3) }
    }

    /// 9:16 with 화면 채우기: the recording fills the frame (no background inside it) and the square sits where the
    /// fill window's camera(t) puts it.
    func testPortraitFillExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.exportMatchesTrim(.portrait, fill: true) }
    }

    /// Dark gradient: the exported background is that preset's color, the rest of the export as usual.
    func testStyledExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.exportMatchesTrim(style: .dark) }
    }

    /// 여백 없음: the recording reaches the canvas edges with square corners and no shadow, black where the aspects
    /// differ; the default keeps padding, rounded corners and a shadow. Rendered without video, through the compositor.
    func testPlainStyleHasNoPaddingCornersOrShadow() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: Self.size))
        func render(_ preset: StylePreset) -> (frame: CGRect, px: (Double, Double) -> (r: Int, g: Int, b: Int)) {
            let style = FrameStyle(preset)
            let image = LoupecastCompositor().render(source, camera: .identity, canvas: canvas, style: style)
            let cg = LoupecastCompositor.context.createCGImage(image, from: CGRect(origin: .zero, size: canvas))!
            return (LoupecastCompositor.frameRect(source: Self.size, canvas: canvas, style: style), { x, y in Self.pixel(cg, x, y) })
        }
        let plain = render(.plain)
        XCTAssertEqual(plain.frame, CGRect(x: 96, y: 0, width: 1728, height: 1080), "no padding: as tall as the canvas")
        let f = plain.frame
        for (x, y) in [(f.minX, f.minY), (f.maxX - 1, f.minY), (f.minX, f.maxY - 1), (f.maxX - 1, f.maxY - 1)] {
            let p = plain.px(x, y)
            XCTAssertTrue(p.r > 200 && p.g < 60 && p.b < 60, "square corner at \(x),\(y) shows the recording: \(p)")
        }
        for (x, y) in [(f.minX - 2, 540.0), (f.maxX + 1, 540), (f.maxX + 1, f.maxY - 2), (40, 1060)] {
            let p = plain.px(x, y)
            XCTAssertTrue(p.r < 3 && p.g < 3 && p.b < 3, "black, no shadow at \(x),\(y): \(p)")
        }
        let pastel = render(.pastel)
        XCTAssertLessThan(pastel.frame.height, 1000, "the default keeps its padding")
        let corner = pastel.px(pastel.frame.minX, pastel.frame.minY)
        XCTAssertFalse(corner.r > 200 && corner.g < 60, "rounded corner shows the background: \(corner)")
        let below = pastel.px(pastel.frame.midX, pastel.frame.maxY + 8), far = pastel.px(pastel.frame.midX, 1076)
        XCTAssertLessThan(below.r + below.g + below.b, far.r + far.g + far.b - 30, "shadow under the frame: \(below) vs \(far)")
    }

    /// A click on the preview maps back through the padding, the camera and the fill window: frame corners are the
    /// visible window's corners, the padding maps to nothing.
    func testPreviewPointMapsToRecording() {
        for (aspect, fill) in [(AspectRatio.landscape, false), (.portrait, true)] {
            var p = Self.makeProject()
            p.aspect = aspect; p.fill = fill
            let canvas = Composer.renderSize(aspect)
            let f = LoupecastCompositor.frameRect(source: Self.size, canvas: canvas, style: FrameStyle(p.style), fill: fill)
            let topLeft = CGPoint(x: f.minX, y: canvas.height - f.maxY), bottomRight = CGPoint(x: f.maxX, y: canvas.height - f.minY)
            for t in [2.1, 4.0] {                                       // before the zoom, fully zoomed in
                let path = Composer.cameraPath(p), cam = path.camera(at: t)
                let hx = path.window.width / 2 / cam.scale, hy = path.window.height / 2 / cam.scale
                let a = Composer.recordingPoint(canvas: topLeft, project: p, at: t)!, b = Composer.recordingPoint(canvas: bottomRight, project: p, at: t)!
                let mid = Composer.recordingPoint(canvas: CGPoint(x: f.midX, y: canvas.height - f.midY), project: p, at: t)!
                XCTAssertEqual(a.x, cam.center.x - hx, accuracy: 1e-9, "\(aspect) \(t)"); XCTAssertEqual(a.y, cam.center.y - hy, accuracy: 1e-9)
                XCTAssertEqual(b.x, cam.center.x + hx, accuracy: 1e-9); XCTAssertEqual(b.y, cam.center.y + hy, accuracy: 1e-9)
                XCTAssertEqual(mid.x, cam.center.x, accuracy: 1e-9); XCTAssertEqual(mid.y, cam.center.y, accuracy: 1e-9)
            }
            XCTAssertNil(Composer.recordingPoint(canvas: CGPoint(x: 5, y: 5), project: p, at: 4), "the padding is not the recording")
        }
        // unzoomed and not filling, the frame is the whole recording
        var p = Self.makeProject()
        p.zooms = []
        let canvas = Composer.renderSize(p.aspect), f = LoupecastCompositor.frameRect(source: Self.size, canvas: canvas, style: .standard)
        XCTAssertEqual(Composer.recordingPoint(canvas: CGPoint(x: f.minX, y: canvas.height - f.maxY), project: p, at: 3), Point(x: 0, y: 0))
    }

    /// sRGB 8-bit color at (x, y), top-left origin.
    static func pixel(_ cg: CGImage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: y - Double(cg.height) + 1, width: Double(cg.width), height: Double(cg.height)))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    static func exportMatchesTrim(_ aspect: AspectRatio = .landscape, zoomScale: Double? = nil, style: StylePreset = .pastel,
                                  fill: Bool = false, display: DisplayBounds = display) async throws {
        let mov = Self.outDir.appendingPathComponent("synthetic.mov")
        try await Self.writeSyntheticMovie(to: mov)
        var project = makeProject(display: display)
        XCTAssertEqual(display.pixelSize(scale: 2).width, Int(size.width)); XCTAssertEqual(display.pixelSize(scale: 2).height, Int(size.height))
        project.aspect = aspect
        XCTAssertEqual(project.zooms.count, 1, "two nearby clicks → one zoom")
        if let zoomScale { project.setZoomScale(id: project.zooms[0].id, zoomScale) }
        project.style = style
        project.fill = fill
        try project.save(to: Self.outDir.appendingPathComponent("project.json"))

        let out = Self.outDir.appendingPathComponent("export-\(aspect.pixels.width)x\(aspect.pixels.height)\(zoomScale.map { "-zoom\($0)" } ?? "")-\(style.rawValue)\(fill ? "-fill" : "")\(display.area == nil ? "" : "-area").mp4")
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
        XCTAssertEqual(natural, CGSize(width: aspect.pixels.width, height: aspect.pixels.height))
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

        // the top-left background is the preset's top-left color; the BT.709 round trip (render, H.264, decode to
        // sRGB) lifts dark tones by up to ~20 levels, while the presets differ by 100 or more
        let gen = AVAssetImageGenerator(asset: asset)
        let first = try await gen.image(at: .zero).image
        let corner = pixel(first, 4, 4), want = FrameStyle(style).topLeft
        if fill {   // inside the frame's top-left corner: recording, not the background around it
            let frame = LoupecastCompositor.frameRect(source: size, canvas: Composer.renderSize(aspect), style: FrameStyle(style), fill: true)
            XCTAssertEqual(frame.width, 952); XCTAssertEqual(frame.height, 1690)
            let inside = pixel(first, frame.minX + 30, frame.minY + 30)
            XCTAssertGreaterThan(abs(inside.r - corner.r) + abs(inside.g - corner.g) + abs(inside.b - corner.b), 60, "\(inside) vs \(corner)")
        }
        XCTAssertEqual(Double(corner.r), want.red * 255, accuracy: 24, "background \(corner) for \(style)")
        XCTAssertEqual(Double(corner.g), want.green * 255, accuracy: 24)
        XCTAssertEqual(Double(corner.b), want.blue * 255, accuracy: 24)
    }

    /// Export time 2.0 s = recording 4.0 s, inside the zoom from the clicks at 3.0/3.5 s. The blue
    /// square (where the cursor clicked) must be visible in the zoomed frame, where camera(t) puts it.
    static func assertClickInsideZoom(export asset: AVURLAsset, project: Project) async throws {
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
        let path = Composer.cameraPath(project), cam = path.camera(at: t)
        XCTAssertEqual(cam.scale, project.zooms[0].scale, accuracy: 1e-6, "the click zoom is fully in at \(t) s")
        let canvas = Composer.renderSize(project.aspect)
        let frame = LoupecastCompositor.frameRect(source: Self.size, canvas: canvas, style: FrameStyle(project.style), fill: project.fillsFrame)
        let p = Self.target(t), hx = path.window.width / 2 / cam.scale, hy = path.window.height / 2 / cam.scale
        let u = (p.x - (cam.center.x - hx)) / (2 * hx), v = (p.y - (cam.center.y - hy)) / (2 * hy)
        XCTAssertTrue((0...1).contains(u) && (0...1).contains(v), "click point outside the zoom rect: \(u), \(v)")
        let expected = (x: frame.minX + u * frame.width, y: (canvas.height - frame.maxY) + v * frame.height)
        print("zoom check: square at (\(sx / n), \(sy / n)) px, camera(t) predicts (\(expected.x), \(expected.y)), window uv (\(u), \(v))")
        XCTAssertEqual(sx / n, expected.x, accuracy: 4)
        XCTAssertEqual(sy / n, expected.y, accuracy: 4)
    }

    // MARK: cut list (REVISION 3)

    /// Clips [1,3] and [5,8] concatenated: 5.0 s, and composition 2.0 s is recording 5.0 s.
    func testExportConcatenatesClips() async throws {
        // GitHub's macOS VMs have no hardware scaler/encoder (AppleM2ScalerParavirtDriver missing) and the
        // video pipeline hangs there; these run locally on real hardware.
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.exportConcatenatesClips() }
    }

    static func exportConcatenatesClips() async throws {
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

    // MARK: volumes

    /// Computer audio is a 0.4 tone in stereo, the microphone a 0.2 tone in mono (same phase): muting one leaves
    /// exactly the other, and 2 doubles a track.
    func testTrackVolumes() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.trackVolumes() }
    }

    static func trackVolumes() async throws {
        let mov = outDir.appendingPathComponent("synthetic-volume.mov")
        try await writeSyntheticMovie(to: mov)
        let mean = { (amplitude: Double) in amplitude * 2 / .pi }      // mean |x| of a sine
        for (system, mic, expected) in [(1.0, 1.0, mean(0.6)), (0, 1, mean(0.2)), (1, 0, mean(0.4)), (2, 0, mean(0.8))] {
            var project = makeProject()
            project.clips = [ClipRange(start: 1, end: 3)]
            project.systemVolume = system; project.micVolume = mic
            let out = outDir.appendingPathComponent("export-volume-\(system)-\(mic).mp4")
            try await Exporter.export(project: project, videoURL: mov, to: out)
            let pcm = try await monoSamples(AVURLAsset(url: out))
            let s = pcm[48_000 / 2..<48_000 * 3 / 2]                    // the middle second
            let level = s.map { abs(Double($0)) }.reduce(0, +) / Double(s.count)
            print("volumes system \(system) mic \(mic): level \(level), expected \(expected)")
            XCTAssertEqual(level, expected, accuracy: expected * 0.05, "system \(system) mic \(mic)")
        }
    }

    // MARK: pause

    /// A recording paused from 4 to 6 s has no frames or sound there; its project starts with that stretch cut, so the
    /// export is 7.7 s and jumps from recording 3.98 straight to 6.00.
    func testPausedStretchIsCut() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.pausedStretchIsCut() }
    }

    static func pausedStretchIsCut() async throws {
        let mov = outDir.appendingPathComponent("synthetic-paused.mov")
        try await writeSyntheticMovie(to: mov, staticScreen: false, gap: 4..<6)
        let project = Project(name: "Paused", duration: duration, pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                              pointPixelScale: 2, cursor: [], clicks: [], paused: [ClipRange(start: 4, end: 6)])
        let out = outDir.appendingPathComponent("export-paused.mp4")
        try await Exporter.export(project: project, videoURL: mov, to: out)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4 + 3.7, accuracy: 1.0 / 60, "the pause is gone")
        for (c, expected) in [(239.0 / 60, "3.98"), (4.0, "6.00")] {
            let text = try await timecode(in: asset, at: c)
            print("paused export: composition \(c) s reads \(text ?? "nothing")")
            XCTAssertEqual(text, expected)
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
    }

    // MARK: speed

    /// [1,3] at 1×, [3,7] at 2×, [8,9] at 4×: 4.25 s, and the burned-in timecode runs at each clip's speed.
    func testSpeedExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.speedExport() }
    }

    static func speedExport() async throws {
        let mov = outDir.appendingPathComponent("synthetic-speed.mov")
        try await writeSyntheticMovie(to: mov, staticScreen: false)
        var project = makeProject()
        project.clips = [ClipRange(start: 1, end: 3), ClipRange(start: 3, end: 7, speed: 2), ClipRange(start: 8, end: 9, speed: 4)]
        let out = outDir.appendingPathComponent("export-speed.mp4")
        try await Exporter.export(project: project, videoURL: mov, to: out)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, project.clips.totalLength, accuracy: 1.0 / 60, "computed \(project.clips.totalLength), got \(duration)")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let v = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(o)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let b = o.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(b) }
        XCTAssertEqual(Double(frames), project.clips.totalLength * 60, accuracy: 1, "4.25 s × 60 fps")
        for (c, expected) in [(1.0, "2.00"), (3.0, "5.00"), (4.15, "8.60")] {   // on frame times: 4.15 s is frame 249
            let text = try await timecode(in: asset, at: c)
            print("speed export: composition \(c) s reads \(text ?? "nothing")")
            XCTAssertEqual(text, expected, "composition \(c) s should show recording \(expected) s")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let arange = try await XCTUnwrap(audio.first).load(.timeRange)
        XCTAssertEqual(arange.duration.seconds, duration, accuracy: 0.05, "sound sped up with the picture")
        // the 1 kHz tone stays 1 kHz inside the 2× clip (pitch kept): ~2000 sign changes a second, not ~4000
        let pcm = try await monoSamples(asset)
        let s = pcm[48_000 * 5 / 2..<48_000 * 7 / 2]
        let crossings = zip(s, s.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        print("speed export: \(crossings) zero crossings in one second of the 2× clip")
        XCTAssertEqual(Double(crossings), 2000, accuracy: 200)
    }

    // MARK: webcam

    /// A webcam movie that is green for its first 2 s and magenta after, starting 1 s into the recording: the circle
    /// shows the camera at recording time − 1, sits in its corner with a white ring, and is absent before the camera
    /// started.
    func testCameraOverlayExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.cameraOverlayExport() }
    }

    static func cameraOverlayExport() async throws {
        let mov = outDir.appendingPathComponent("synthetic.mov"), cam = outDir.appendingPathComponent("camera.mov")
        try await writeSyntheticMovie(to: mov)
        try await writeSyntheticCamera(to: cam)
        let canvas = Composer.renderSize(.landscape)
        func frame(_ project: Project, at c: Double, _ name: String) async throws -> CGImage {
            let out = outDir.appendingPathComponent("export-camera-\(name).mp4")
            try await Exporter.export(project: project, videoURL: mov, to: out)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: out))
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            return try await gen.image(at: CMTime(seconds: c, preferredTimescale: 600)).image
        }
        func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 150 && p.r < 90 && p.b < 90 }
        func isMagenta(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 150 && p.b > 150 && p.g < 90 }

        var project = makeProject()                                     // kept: recording 2.0 – 7.5
        project.camera = CameraOverlay(offset: 1)
        let c = LoupecastCompositor.cameraCircle(canvas: canvas, project.camera!)
        let center = (c.midX, canvas.height - c.midY), cornerOfBox = (c.minX + 4, canvas.height - c.minY - 4)
        let early = try await frame(project, at: 0.5, "a"), late = try await frame(project, at: 3.0, "b")
        print("camera: circle \(c), center \(pixel(early, center.0, center.1)) then \(pixel(late, center.0, center.1))")
        XCTAssertGreaterThan(c.minX, canvas.width / 2); XCTAssertLessThan(c.minY, canvas.height / 2)   // bottom right
        XCTAssertTrue(isGreen(pixel(early, center.0, center.1)), "recording 2.5 s = camera 1.5 s: green")
        XCTAssertTrue(isMagenta(pixel(late, center.0, center.1)), "recording 5 s = camera 4 s: magenta")
        let box = pixel(late, cornerOfBox.0, cornerOfBox.1)
        XCTAssertFalse(isMagenta(box), "a circle, not a square: \(box)")
        let ring = pixel(late, c.midX, canvas.height - c.maxY - 2)
        XCTAssertTrue(ring.r > 220 && ring.g > 220 && ring.b > 220, "white ring above the circle: \(ring)")

        // a camera that started 4 s in, shown top left: nothing before it started, then its first frames
        project.camera = CameraOverlay(offset: 4)
        project.camera?.corner = .topLeft
        let tl = LoupecastCompositor.cameraCircle(canvas: canvas, project.camera!)
        XCTAssertLessThan(tl.minX, canvas.width / 2); XCTAssertGreaterThan(tl.minY, canvas.height / 2)
        let before = try await frame(project, at: 0.5, "c"), after = try await frame(project, at: 3.0, "d")
        XCTAssertFalse(isGreen(pixel(before, tl.midX, canvas.height - tl.midY)), "recording 2.5 s: the camera hadn't started")
        XCTAssertTrue(isGreen(pixel(after, tl.midX, canvas.height - tl.midY)), "recording 5 s = camera 1 s: green, top left")

        project.camera?.isVisible = false
        let hidden = try await frame(project, at: 3.0, "e")
        XCTAssertFalse(isGreen(pixel(hidden, tl.midX, canvas.height - tl.midY)), "hidden camera: no circle")
    }

    /// 640 × 480 at 30 fps for 8 s: green until 2 s, magenta after.
    static func writeSyntheticCamera(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        nonisolated(unsafe) let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 480])
        nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 480])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        await feed(input, count: 240) { k in
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: 640, height: 480, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(k < 60 ? CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1) : CGColor(srgbRed: 0.9, green: 0, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: 30))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 8, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    // MARK: GIF

    /// The 5.5 s edit as a GIF: 960×540, looping forever, 15 frames a second, as long as the MP4 (delays 7, 7, 6…).
    func testGIFExport() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.gifExport() }
    }

    static func gifExport() async throws {
        let mov = outDir.appendingPathComponent("synthetic-gif.mov")
        try await writeSyntheticMovie(to: mov)
        let out = outDir.appendingPathComponent("export.gif")
        try await GIFExporter.export(project: makeProject(), videoURL: mov, to: out)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.gif.identifier)
        let n = CGImageSourceGetCount(src)
        XCTAssertEqual(Double(n), 5.5 * 15, accuracy: 1, "15 fps")
        let gif = try XCTUnwrap((CGImageSourceCopyProperties(src, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount] as? Int, 0, "loops forever")
        var total = 0.0
        for i in 0..<n {
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            total += ((p?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
        }
        XCTAssertEqual(total, 5.5, accuracy: 0.08, "as long as the edit")
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual([first.width, first.height], [960, 540])
        XCTAssertEqual(GIFExporter.size(.portrait), CGSize(width: 540, height: 960))
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        print("gif: \(n) frames, \(total) s, \(size / 1024) KB → \(out.path)")
    }

    // MARK: cancel and file names

    /// Cancelled at 20 %: the partial MP4 that existed then is gone and the export throws CancellationError.
    func testCancelledExportLeavesNoFile() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil, "no video hardware on CI VMs")
        try await withDeadline(Self.deadline) { try await Self.cancelledExport() }
    }

    static func cancelledExport() async throws {
        let mov = outDir.appendingPathComponent("synthetic-cancel.mov")
        try await writeSyntheticMovie(to: mov)
        let out = outDir.appendingPathComponent("export-cancel.mp4")
        let (reached, at20) = AsyncStream<Void>.makeStream()
        let export = Task {
            defer { at20.finish() }
            try await Exporter.export(project: makeProject(), videoURL: mov, to: out) { if $0 >= 0.2 { at20.yield() } }
        }
        for await _ in reached { break }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "the partial file exists while exporting")
        export.cancel()
        do {
            try await export.value
            XCTFail("the cancelled export finished")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "partial export left behind")
    }

    func testDefaultURLNeverReusesAName() throws {
        let dir = Self.outDir.appendingPathComponent("names", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Exporter.defaultURL(now: now, in: dir)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Loupecast 20") && first.lastPathComponent.hasSuffix(".mp4"))
        XCTAssertFalse(first.lastPathComponent.contains(" 2.mp4"))
        try Data().write(to: first)
        let second = Exporter.defaultURL(now: now, in: dir)
        XCTAssertEqual(second.lastPathComponent, first.deletingPathExtension().lastPathComponent + " 2.mp4", "an existing file is never the target")
        let third = Exporter.defaultURL(now: now, in: dir, taken: [second])
        XCTAssertEqual(third.lastPathComponent, first.deletingPathExtension().lastPathComponent + " 3.mp4", "a running export's name is taken too")
    }

    // MARK: time limit

    /// One export test takes ~6 s on Apple Silicon; a stuck one fails here instead of hanging `swift test`.
    static let deadline = 120.0

    /// Fails after `seconds` instead of hanging. A stuck AVFoundation wait can't be cancelled, so this doesn't wait
    /// for `body` to unwind; `executionTimeAllowance` only applies under xcodebuild with test timeouts on.
    func withDeadline(_ seconds: Double, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let work = Task(operation: body)
        let finished = XCTestExpectation(description: "finished within \(Int(seconds)) s")
        Task { _ = await work.result; finished.fulfill() }
        guard await XCTWaiter().fulfillment(of: [finished], timeout: seconds) == .completed else {
            work.cancel()
            XCTFail("timed out after \(Int(seconds)) s")
            return
        }
        try await work.value
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

    /// `gap`: seconds with neither frames nor sound, as a paused recording writes them.
    static func writeSyntheticMovie(to url: URL, staticScreen: Bool = true, gap: Range<Double>? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(size.width), h = Int(size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)   // fragmented, like Recorder's
        nonisolated(unsafe) let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(vIn)
        nonisolated(unsafe) let sys = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        nonisolated(unsafe) let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        writer.add(sys); writer.add(mic)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Each input pulls its own samples whenever the writer asks for them, so the writer does the interleaving.
        // Polling video while pushing audio a fixed 0.25 s ahead deadlocked: the writer held video until audio
        // covered more of its interleave window, with every encoder thread idle (sampled at the video wait).
        let frames = (0..<Int(duration * 60)).filter { (i: Int) -> Bool in
            let frozen: Bool = staticScreen && i > 240 && i < 360   // static screen: SCStream sends no complete frames
            let inGap: Bool = gap?.contains(Double(i) / 60) ?? false
            return !frozen && !inGap
        }
        let rate = 48_000, total = Int(duration) * rate, chunk = 1024, chunks = (total + chunk - 1) / chunk
        async let video: Void = feed(vIn, count: frames.count) { k in
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            draw(into: pb!, t: Double(frames[k]) / 60)
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(frames[k]), timescale: 60))
        }
        let silent: @Sendable (Int) -> Bool = { k in gap?.contains(Double(k * chunk) / Double(rate)) == true }
        async let system: Void = feed(sys, count: chunks) { k in
            if !silent(k) { sys.append(tone(start: k * chunk, count: min(chunk, total - k * chunk), channels: 2, amplitude: 0.4)) }
        }
        async let microphone: Void = feed(mic, count: chunks) { k in
            if !silent(k) { mic.append(tone(start: k * chunk, count: min(chunk, total - k * chunk), channels: 1, amplitude: 0.2)) }
        }
        _ = await (video, system, microphone)
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    /// Drives one writer input from its own queue: `append(k)` for k in 0..<count, whenever the input is ready.
    static func feed(_ input: AVAssetWriterInput, count: Int, _ append: @escaping @Sendable (Int) -> Void) async {
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) var k = 0   // touched only on the input's queue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "loupecast.synthetic.\(input.mediaType.rawValue)")) {
                guard k < count else { return }
                while input.isReadyForMoreMediaData, k < count { append(k); k += 1 }
                if k == count { input.markAsFinished(); done.resume() }
            }
        }
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
