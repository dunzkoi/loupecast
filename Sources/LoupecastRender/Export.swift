import AVFoundation
import LoupecastCore

/// H.264 1920×1080 constant 60 fps + one stereo AAC track (system and mic mixed).
/// The composition is the kept clips back to back, so the file is exactly their total length.
public enum Exporter {
    public static func defaultURL(now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Loupecast \(f.string(from: now)).mp4")
    }

    public static func export(project: Project, videoURL: URL, to output: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let edit = try Composer.make(project: project, source: try await SourceTracks.load(videoURL))
        let duration = edit.asset.duration
        let reader = try AVAssetReader(asset: edit.asset)

        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: edit.asset.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = edit.videoComposition
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(Composer.renderSize.width), AVVideoHeightKey: Int(Composer.renderSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoAllowFrameReorderingKey: false,   // no B-frames: PTS == DTS, no edit-list offset
            ],
        ])
        writer.add(vIn)
        let audioTracks = edit.asset.tracks(withMediaType: .audio)
        var audio: Pumps.Job?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            o.alwaysCopiesSampleData = true      // the cut fades are written into these buffers
            reader.add(o)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            writer.add(i)
            audio = (o, i)
        }

        guard reader.startReading() else { throw reader.error ?? LoupecastError("읽기를 시작하지 못했습니다.") }
        guard writer.startWriting() else { throw writer.error ?? LoupecastError("쓰기를 시작하지 못했습니다.") }
        writer.startSession(atSourceTime: .zero)

        let total = duration.seconds
        try await Pumps(reader: reader, writer: writer, video: (vOut, vIn), audio: audio, cuts: project.clips.cutTimes)
            .run { progress(min(1, $0 / total)) }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? LoupecastError("읽기 실패") }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? LoupecastError("쓰기 실패") }
        progress(1)
    }
}

/// AVFoundation objects are thread-safe for this producer/consumer use; the box only satisfies Swift 6.
private struct Pumps: @unchecked Sendable {
    typealias Job = (AVAssetReaderOutput, AVAssetWriterInput)
    let reader: AVAssetReader, writer: AVAssetWriter, video: Job, audio: Job?
    let cuts: [Double]

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
                    guard let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if reader.status == .failed { cont.resume(throwing: reader.error ?? LoupecastError("읽기 실패")) }
                        else { cont.resume() }
                        return
                    }
                    if !cuts.isEmpty { Self.applyCutFades(buffer, cuts: cuts) }
                    guard input.append(buffer) else {
                        reader.cancelReading()
                        cont.resume(throwing: writer.error ?? LoupecastError("쓰기 실패"))
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
