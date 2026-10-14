import AVFoundation
import LoupecastCore
import os
import VideoToolbox

/// Frame rate and file size of an MP4 export. The preview always plays at 60 fps.
public struct ExportOptions: Sendable, Equatable {
    /// 60 or 30.
    public var fps: Int
    /// Upper bound for the file in bytes; nil: the full 16 Mbps.
    public var targetBytes: Int?
    public init(fps: Int = 60, targetBytes: Int? = nil) { self.fps = fps; self.targetBytes = targetBytes }

    public static let audioBitRate = 192_000
    static let fullBitRate = 16_000_000

    /// Video bit rate and frame rate for `seconds` of composition. A target leaves 10 % of it for the container and
    /// the audio's 192 kbps; below 1 Mbps a 60 fps export drops to 30 fps, so each frame gets twice the bits.
    public func plan(seconds: Double, hasAudio: Bool) -> (bitRate: Int, fps: Int) {
        guard let targetBytes else { return (Self.fullBitRate, fps) }
        let budget = Double(targetBytes) * 8 * 0.9 / max(0.1, seconds) - (hasAudio ? Double(Self.audioBitRate) : 0)
        return (Int(min(Double(Self.fullBitRate), max(100_000, budget))), budget < 1_000_000 ? 30 : fps)
    }
}

/// H.264 at the project's aspect (1920×1080, 1080×1920 or 1080×1080), constant 60 or 30 fps, + one stereo AAC track
/// (system and mic mixed at the project's volumes).
/// The composition is the kept clips back to back, so the file is exactly their total length.
public enum Exporter {
    public static var moviesDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies") }

    /// `<name>.mp4` (or .gif) in `dir`, `Loupecast <yyyy-MM-dd HH.mm.ss>` without a name, numbered " 2", " 3"… when that
    /// name is on disk or in `taken` (exports still running), so an export never replaces an earlier one.
    public static func defaultURL(name: String? = nil, now: Date = Date(), in dir: URL = moviesDir, taken: Set<URL> = [],
                                  fileExtension: String = "mp4") -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = name.map(fileName).flatMap { $0.isEmpty ? nil : $0 } ?? "Loupecast \(f.string(from: now))"
        return (1...).lazy.map { n in dir.appendingPathComponent("\(base)\(n == 1 ? "" : " \(n)").\(fileExtension)") }
            .first { !taken.contains($0) && !FileManager.default.fileExists(atPath: $0.path) }!
    }

    /// `/` and `:` can't be in a file name (Finder shows `:` as `/`); a leading dot would hide the file.
    static func fileName(_ name: String) -> String {
        let s = String(name.map { "/:".contains($0) ? "-" : $0 }.prefix(200))
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    public static func export(project: Project, videoURL: URL, to output: URL, options: ExportOptions = ExportOptions(),
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let edit = try Composer.make(project: project, source: try await SourceTracks.load(videoURL, camera: project.camera?.file))
        let duration = edit.asset.duration
        let audioTracks = edit.asset.tracks(withMediaType: .audio)
        let plan = options.plan(seconds: duration.seconds, hasAudio: !audioTracks.isEmpty)
        let reader = try AVAssetReader(asset: edit.asset)

        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: edit.asset.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let vc = edit.videoComposition.mutableCopy() as! AVMutableVideoComposition
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
        vOut.videoComposition = vc
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let size = Composer.renderSize(project.aspect)
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.bitRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: plan.fps,
            AVVideoMaxKeyFrameIntervalKey: plan.fps * 2,
            AVVideoAllowFrameReorderingKey: false,   // no B-frames: PTS == DTS, no edit-list offset
        ]
        func settings() -> [String: Any] { [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ] }
        if options.targetBytes != nil {
            // a size target also caps every second at 1.5× the average, so a busy stretch can't blow the budget
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [plan.bitRate / 8 * 3 / 2, 1]
            if !writer.canApply(outputSettings: settings(), forMediaType: .video) {
                compression[kVTCompressionPropertyKey_DataRateLimits as String] = nil
            }
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings())
        writer.add(vIn)
        var audio: Pumps.Job?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            o.alwaysCopiesSampleData = true      // the cut fades are written into these buffers
            o.audioMix = Composer.audioMix(edit.asset, project: project, micTracks: edit.micTracks, fades: false)
            o.audioTimePitchAlgorithm = Composer.pitchAlgorithm
            reader.add(o)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: ExportOptions.audioBitRate,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            writer.add(i)
            audio = (o, i)
        }

        // a cancelled or failed export leaves no half-written file behind
        do {
            guard reader.startReading() else { throw reader.error ?? LoupecastError("Couldn’t start reading.") }
            guard writer.startWriting() else { throw writer.error ?? LoupecastError("Couldn’t start writing.") }
            writer.startSession(atSourceTime: .zero)

            let total = duration.seconds
            let pumps = Pumps(reader: reader, writer: writer, video: (vOut, vIn), audio: audio, cuts: project.clips.cutTimes)
            // both pumps finish at their next buffer, then the check below throws
            try await withTaskCancellationHandler {
                try await pumps.run { progress(min(1, $0 / total)) }
            } onCancel: { pumps.stop() }
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? LoupecastError("Reading failed") }
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            if writer.status != .completed { throw writer.error ?? LoupecastError("Writing failed") }
        } catch {
            reader.cancelReading()   // safe here: both pumps have returned
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
    }
}

/// AVFoundation objects are thread-safe for this producer/consumer use; the box only satisfies Swift 6.
private struct Pumps: @unchecked Sendable {
    typealias Job = (AVAssetReaderOutput, AVAssetWriterInput)
    let reader: AVAssetReader, writer: AVAssetWriter, video: Job, audio: Job?
    let cuts: [Double]
    /// Checked by each pump on its own queue. cancelReading() from another thread while a pump is inside
    /// copyNextSampleBuffer() crashes in AVFoundation (measured: EXC_BREAKPOINT when quitting mid-export).
    let stopped = OSAllocatedUnfairLock(initialState: false)

    /// Both pumps mark their input finished at the next buffer they would have read.
    func stop() { stopped.withLock { $0 = true } }

    /// Runs the video and (optional) audio pumps concurrently; `progress` gets the video time.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws {
        async let v: Void = pump(video, progress: progress)
        if let audio { try await pump(audio, fade: cuts, progress: { _ in }) }
        try await v
    }

    private func pump(_ job: Job, fade cuts: [Double] = [], progress: @escaping @Sendable (Double) -> Void) async throws {
        nonisolated(unsafe) let (output, input) = job   // see Pumps doc comment
        let queue = DispatchQueue(label: "loupecast.export.\(input.mediaType.rawValue)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard !stopped.withLock({ $0 }), let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if reader.status == .failed { cont.resume(throwing: reader.error ?? LoupecastError("Reading failed")) }
                        else { cont.resume() }
                        return
                    }
                    if !cuts.isEmpty { Self.applyCutFades(buffer, cuts: cuts) }
                    guard input.append(buffer) else {
                        stop()
                        cont.resume(throwing: writer.error ?? LoupecastError("Writing failed"))
                        return
                    }
                    progress(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                }
            }
        }
    }

    /// Exact 10 ms fade out/in at each cut, on interleaved float PCM (the mix output's format).
    static func applyCutFades(_ buffer: CMSampleBuffer, cuts: [Double]) {
        guard let fmt = CMSampleBufferGetFormatDescription(buffer).flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?.pointee,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let rate = fmt.mSampleRate, channels = Int(fmt.mChannelsPerFrame), frames = CMSampleBufferGetNumSamples(buffer)
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds, end = start + Double(frames) / rate
        guard cuts.contains(where: { $0 + Project.cutFade > start && $0 - Project.cutFade < end }) else { return }
        var contiguous = 0, total = 0
        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &total, dataPointerOut: &data) == noErr,
              let data, contiguous == total, total >= frames * channels * 4 else { return }
        data.withMemoryRebound(to: Float.self, capacity: frames * channels) { s in
            for i in 0..<frames {
                let g = Float(cutGain(at: start + Double(i) / rate, cuts: cuts))
                guard g < 1 else { continue }
                for c in 0..<channels { s[i * channels + c] *= g }
            }
        }
    }
}
