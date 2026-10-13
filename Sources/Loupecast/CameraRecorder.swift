import AVFoundation
import LoupecastCore

/// The default camera into `camera.mov` next to the recording. Its first frame's host time is returned at stop, so
/// the project can line it up with the screen (both are stamped on the host clock).
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let fileName = "camera.mov"

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "loupecast.camera", qos: .userInitiated)
    private let writer: AVAssetWriter
    // capture queue only
    private var input: AVAssetWriterInput?
    private var first: CMTime?
    private var pauses: [(start: CMTime, end: CMTime)] = []

    init(dir: URL) throws {
        guard let device = AVCaptureDevice.default(for: .video) else { throw LoupecastError("No camera is connected.") }
        let camera = try AVCaptureDeviceInput(device: device)
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        guard session.canAddInput(camera), session.canAddOutput(output) else { throw LoupecastError("Couldn’t start the camera.") }
        session.addInput(camera)
        session.addOutput(output)
        output.alwaysDiscardsLateVideoFrames = true
        writer = try AVAssetWriter(outputURL: dir.appendingPathComponent(Self.fileName), fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)   // like the screen: a crash keeps most of it
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// startRunning blocks until the camera is on, so it runs off the main thread.
    func start() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning(); done.resume() }
        }
    }

    /// Same pauses as the screen: nothing from them is written.
    func setPaused(_ on: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            if on, pauses.last.map({ $0.end.isValid }) ?? true { pauses.append((now, .invalid)) }
            if !on, let last = pauses.last, !last.end.isValid { pauses[pauses.count - 1].end = now }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = sb.presentationTimeStamp
        let host = session.synchronizationClock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        guard !pauses.contains(where: { host >= $0.start && (!$0.end.isValid || host < $0.end) }) else { return }
        if input == nil {   // the camera's own size is known only now
            guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
            ])
            i.expectsMediaDataInRealTime = true
            guard writer.canAdd(i) else { return }
            writer.add(i)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: pts)
            input = i
            first = host
        }
        if let input, input.isReadyForMoreMediaData { input.append(sb) }
    }

    /// Host-clock seconds of the first frame written; nil (and no file) when the camera sent nothing usable.
    func stop() async -> Double? {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning(); done.resume() }
        }
        let (input, first) = await withCheckedContinuation { cont in queue.async { cont.resume(returning: (self.input, self.first)) } }
        guard let input, let first else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: writer.outputURL)
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            NSLog("Loupecast: camera file failed: %@", writer.error.map(describe) ?? "?")
            try? FileManager.default.removeItem(at: writer.outputURL)
            return nil
        }
        return first.seconds
    }
}
