import AVFoundation
import AppKit
import LoupecastCore
@preconcurrency import ScreenCaptureKit

/// One recording: SCStream (screen + system audio, optional mic) → AVAssetWriter .mov, plus an input log
/// stamped with the host clock the sample buffers use.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static var recordingsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loupecast/Recordings", isDirectory: true)
    }

    let dir: URL
    var onStreamError: (@MainActor (Error) -> Void)?

    private let queue = DispatchQueue(label: "loupecast.capture", qos: .userInteractive)
    private var stream: SCStream!
    private let writer: AVAssetWriter
    private let videoIn: AVAssetWriterInput
    private let systemIn: AVAssetWriterInput?
    private let micIn: AVAssetWriterInput?
    private let display: DisplayBounds
    private let pixelSize: (Int, Int)
    private let scale: Double
    // capture queue only
    private var sessionStart: CMTime?
    private var lastVideo = CMTime.invalid
    private var dropped = 0
    // main thread only
    private var log = InputLog()
    private var monitors: [Any] = []
    private var cursorTimer: Timer?

    #if DEBUG
    deinit { NSLog("Loupecast: recorder released") }
    #endif

    /// `hideMenuBar` crops the menu-bar strip (or notch) off the top of the display.
    @MainActor
    static func start(microphone: Bool, systemAudio: Bool, hideMenuBar: Bool) async throws -> Recorder {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = CGEvent(source: nil)?.location ?? .zero
        guard let scDisplay = content.displays.first(where: { $0.frame.contains(mouse) }) ?? content.displays.first else {
            throw LoupecastError("녹화할 디스플레이를 찾지 못했습니다.")
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: me, exceptingWindows: [])
        var inset = 0.0
        if hideMenuBar, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == scDisplay.displayID
        }) {
            inset = DisplayBounds.menuBarInset(frameMaxY: screen.frame.maxY, visibleMaxY: screen.visibleFrame.maxY,
                                               safeAreaTop: screen.safeAreaInsets.top)
        }
        let r = try Recorder(filter: filter, displayID: scDisplay.displayID, topInset: inset, microphone: microphone, systemAudio: systemAudio)
        try await r.stream.startCapture()
        r.startInputMonitors()
        return r
    }

    private init(filter: SCContentFilter, displayID: CGDirectDisplayID, topInset: Double, microphone: Bool, systemAudio: Bool) throws {
        scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
        let b = CGDisplayBounds(displayID)
        display = DisplayBounds(x: b.minX, y: b.minY, width: b.width, height: b.height, topInset: topInset)
        pixelSize = display.pixelSize(scale: scale)
        let (w, h) = pixelSize

        let cfg = SCStreamConfiguration()
        let r = display.captureRect
        cfg.sourceRect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = true
        cfg.queueDepth = 8
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.capturesAudio = systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = microphone

        dir = Self.recordingsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("recording.mov"), fileType: .mov)
        videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, Int(Double(w * h * 60) * 0.05)),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        systemIn = systemAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000]) : nil
        micIn = microphone ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]) : nil
        for i in [videoIn, systemIn, micIn].compactMap({ $0 }) {
            i.expectsMediaDataInRealTime = true
            writer.add(i)
        }
        guard writer.startWriting() else { throw writer.error ?? LoupecastError("녹화 파일을 만들지 못했습니다.") }

        super.init()
        stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }

    // MARK: capture queue

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            let pts = sb.presentationTimeStamp
            if sessionStart == nil {
                writer.startSession(atSourceTime: pts)
                sessionStart = pts
            }
            if videoIn.isReadyForMoreMediaData, videoIn.append(sb) { lastVideo = pts } else { dropped += 1 }
        case .audio:
            if let systemIn { appendAudio(sb, to: systemIn) }
        case .microphone:
            if let micIn { appendAudio(sb, to: micIn) }
        @unknown default:
            break
        }
    }

    private func appendAudio(_ sb: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard let start = sessionStart, sb.presentationTimeStamp >= start, input.isReadyForMoreMediaData else { return }
        input.append(sb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = onStreamError
        Task { @MainActor in handler?(error) }
    }

    // MARK: input log (main thread)

    @MainActor private func startInputMonitors() {
        let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            let p = e.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
            let kind: InputLog.Raw.Kind = .click(e.type == .rightMouseDown ? .right : .left)
            MainActor.assumeIsolated { self?.log.append(.init(host: Self.hostTime(e.timestamp), gx: p.x, gy: p.y, kind: kind)) }
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode, host = Self.hostTime(e.timestamp)
            MainActor.assumeIsolated { self?.log.append(.init(host: host, gx: 0, gy: 0, kind: .key(code))) }
        }
        monitors = [clicks, keys].compactMap { $0 }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let p = CGEvent(source: nil)?.location else { return }
            let host = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated { self?.log.append(.init(host: host, gx: p.x, gy: p.y, kind: .move)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    /// NSEvent.timestamp and SCStream PTS share the mach host clock (CMClockGetHostTimeClock ==
    /// systemUptime). Synthetic events can carry no timestamp; fall back to "now" for those.
    static func hostTime(_ eventTimestamp: TimeInterval) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        return abs(eventTimestamp - now) < 5 ? eventTimestamp : now
    }

    // MARK: stop

    @MainActor
    func stop() async throws -> Project {
        let stopHost = CMClockGetTime(CMClockGetHostTimeClock())
        cursorTimer?.invalidate()
        cursorTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        try? await stream.stopCapture()
        for t in [SCStreamOutputType.screen, .audio, .microphone] { try? stream.removeStreamOutput(self, type: t) }
        stream = nil

        // drain the capture queue, then close the file
        let (start, last, dropped): (CMTime?, CMTime, Int) = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: (self.sessionStart, self.lastVideo, self.dropped)) }
        }
        guard let start else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dir)
            throw LoupecastError("화면 프레임을 하나도 받지 못했습니다. 화면 녹화 권한을 확인해 주세요.")
        }
        let end = max(stopHost, last)
        videoIn.markAsFinished(); systemIn?.markAsFinished(); micIn?.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LoupecastError("녹화 파일을 마무리하지 못했습니다.") }
        if dropped > 0 { NSLog("Loupecast: writer was busy for %d frames", dropped) }

        let movie = AVURLAsset(url: writer.outputURL)
        var duration = (end - start).seconds
        if let v = try await movie.loadTracks(withMediaType: .video).first {
            duration = min(duration, try await v.load(.timeRange).end.seconds)
        }
        #if DEBUG
        Self.lastSessionStartHost = start.seconds
        #endif
        let events = log.relativized(sessionStartHost: start.seconds, duration: duration, display: display)
        let f = DateFormatter()
        f.dateFormat = "M월 d일 HH.mm.ss"
        let project = Project(name: "녹화 \(f.string(from: Date()))", duration: duration,
                              pixelWidth: pixelSize.0, pixelHeight: pixelSize.1, pointPixelScale: scale,
                              cursor: events.cursor, clicks: events.clicks, keys: events.keys)
        try project.save(to: dir.appendingPathComponent(Project.fileName))
        return project
    }
}

#if DEBUG
extension Recorder {
    nonisolated(unsafe) static var lastSessionStartHost = 0.0
}
#endif
