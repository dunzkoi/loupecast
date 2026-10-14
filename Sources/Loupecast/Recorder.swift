import AVFoundation
import AppKit
import Carbon.HIToolbox
import LoupecastCore
@preconcurrency import ScreenCaptureKit

/// One recording: SCStream (screen + system audio, optional mic) → AVAssetWriter .mov, plus an input log
/// stamped with the host clock the sample buffers use.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static var recordingsDir: URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["LOUPECAST_RECORDINGS_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Loupecast/Recordings", isDirectory: true)
    }
    /// An event-free project written at start: the size and name a crashed recording is recovered with.
    static let recoveryFile = "recovery.json"

    let dir: URL
    var onStreamError: (@MainActor (Error) -> Void)?

    private let queue = DispatchQueue(label: "loupecast.capture", qos: .userInteractive)
    private var stream: SCStream!
    private let writer: AVAssetWriter
    private let videoIn: AVAssetWriterInput
    private let systemIn: AVAssetWriterInput?
    private let micIn: AVAssetWriterInput?
    private let display: DisplayBounds
    /// The webcam, when 카메라 함께 녹화 is on.
    private var camera: CameraRecorder?
    private let pixelSize: (Int, Int)
    private let scale: Double
    // capture queue only
    private var sessionStart: CMTime?
    private var lastVideo = CMTime.invalid
    private var dropped = 0
    /// Host-clock pauses; an open one ends at `.invalid`. Samples stamped inside one are never written.
    private var pauses: [(start: CMTime, end: CMTime)] = []
    // main thread only
    private var log = InputLog()
    private var monitors: [Any] = []
    private var cursorTimer: Timer?
    private var cursorShapes: CursorShapes?
    private var ticks = 0
    /// The stretch of typing in progress (host clock) and where its text goes; the last click, global coordinates.
    private var typingSpan: (start: Double, last: Double, at: CGPoint)?
    private var lastClick: CGPoint?

    #if DEBUG
    deinit { NSLog("Loupecast: recorder released") }
    #endif

    /// `hideMenuBar` crops the menu-bar strip (or notch) off the top of the display; an `area` records only that rect
    /// of its display instead. `camera` records the default camera next to it (started first: it takes a moment).
    @MainActor
    static func start(microphone: Bool, systemAudio: Bool, hideMenuBar: Bool, area: RecordingArea? = nil, camera: Bool = false,
                      shortcuts: Bool = false, typing: Bool = false) async throws -> Recorder {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let display = area.map { a in content.displays.first { $0.displayID == a.displayID } }
            ?? content.displays.first(where: { $0.frame.contains(mouse) }) ?? content.displays.first
        guard let scDisplay = display else {
            throw area == nil ? LoupecastError("Couldn’t find a display to record.") : LoupecastError("The display with the chosen area isn’t connected.")
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: scDisplay, excludingApplications: me, exceptingWindows: [])
        var inset = 0.0
        if hideMenuBar, area == nil, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == scDisplay.displayID
        }) {
            inset = DisplayBounds.menuBarInset(frameMaxY: screen.frame.maxY, visibleMaxY: screen.visibleFrame.maxY,
                                               safeAreaTop: screen.safeAreaInsets.top)
        }
        let dir = recordingsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {   // no empty .mov or folder left behind
            let r = try Recorder(dir: dir, filter: filter, displayID: scDisplay.displayID, topInset: inset, area: area?.rect,
                                 microphone: microphone, systemAudio: systemAudio)
            do {
                if camera {
                    r.camera = try CameraRecorder(dir: dir)
                    await r.camera?.start()
                }
                try await r.stream.startCapture()
            } catch {
                r.writer.cancelWriting()
                _ = await r.camera?.stop()
                throw error
            }
            r.startInputMonitors(shortcuts: shortcuts, typing: typing)
            return r
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private init(dir: URL, filter: SCContentFilter, displayID: CGDirectDisplayID, topInset: Double, area: Rect?,
                 microphone: Bool, systemAudio: Bool) throws {
        scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
        let b = CGDisplayBounds(displayID)
        display = DisplayBounds(x: b.minX, y: b.minY, width: b.width, height: b.height, topInset: topInset, area: area)
        pixelSize = display.pixelSize(scale: scale)
        let (w, h) = pixelSize

        let cfg = SCStreamConfiguration()
        let r = display.captureRect
        cfg.sourceRect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        cfg.width = w
        cfg.height = h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = false   // the compositor draws it from the samples and shapes below (CursorOverlay)
        cfg.queueDepth = 8
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.capturesAudio = systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = microphone

        self.dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("recording.mov"), fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)   // a crash keeps all but the last ≤ 5 s
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
        guard writer.startWriting() else { throw writer.error ?? LoupecastError("Couldn’t create the recording file.") }
        try Project(name: Self.name(Date()), duration: 0, pixelWidth: w, pixelHeight: h, pointPixelScale: scale, cursor: [], clicks: [])
            .save(to: dir.appendingPathComponent(Self.recoveryFile))

        super.init()
        stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
    }

    // MARK: capture queue

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !isPaused(at: sb.presentationTimeStamp) else { return }
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

    private func isPaused(at pts: CMTime) -> Bool {
        pauses.contains { pts >= $0.start && (!$0.end.isValid || pts < $0.end) }
    }

    /// Pausing keeps the stream running but writes nothing, so a paused screen never lands in the file.
    func setPaused(_ on: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        queue.async { [self] in
            if on, pauses.last.map({ $0.end.isValid }) ?? true { pauses.append((now, .invalid)) }
            if !on, let last = pauses.last, !last.end.isValid { pauses[pauses.count - 1].end = now }
        }
        camera?.setPaused(on)
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

    @MainActor private func startInputMonitors(shortcuts: Bool, typing: Bool) {
        let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            let p = e.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
            let kind: InputLog.Raw.Kind = .click(e.type == .rightMouseDown ? .right : .left)
            MainActor.assumeIsolated {
                self?.log.append(.init(host: Self.hostTime(e.timestamp), gx: p.x, gy: p.y, kind: kind))
                self?.lastClick = p
            }
        }
        // Keys only for 단축키 표시 and 타이핑 구간 확대: InputLog.appendKey keeps nothing but combinations with ⌘ or ⌃, and
        // typing leaves only where each stretch began and ended, so typed text (passwords included) never goes into
        // project.json. Needs Accessibility; without it macOS sends no key events.
        let keys = !shortcuts && !typing ? nil : NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard !e.isARepeat, !IsSecureEventInputEnabled() else { return }   // a password field: nothing at all
            let f = e.modifierFlags
            var m = KeyModifiers()
            if f.contains(.control) { m.insert(.control) }
            if f.contains(.option) { m.insert(.option) }
            if f.contains(.shift) { m.insert(.shift) }
            if f.contains(.command) { m.insert(.command) }
            let host = Self.hostTime(e.timestamp), special = Self.specialKeys[Int(e.keyCode)]
            // every key but the special ones may type text (dead keys like ⌥E included)
            let name = special ?? (e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers ?? "?").uppercased()
            let types = special == nil || [kVK_Space, kVK_Tab].contains(Int(e.keyCode))   // ⌥Space types a no-break space
            MainActor.assumeIsolated {
                if shortcuts { self?.log.appendKey(host: host, modifiers: m, key: name, typesText: types) }
                if typing, m.isDisjoint(with: [.command, .control]) { self?.typed(at: host) }
            }
        }
        monitors = [clicks, keys].compactMap { $0 }
        let shapes = CursorShapes(dir: dir)
        shapes.note()
        cursorShapes = shapes
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let p = CGEvent(source: nil)?.location else { return }
            let host = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log.append(.init(host: host, gx: p.x, gy: p.y, kind: .move))
                self.ticks += 1
                if self.ticks % 6 == 0 { self.cursorShapes?.note() }   // 10 Hz: a read takes ~2.4 ms
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    /// One more key of typing: extends the current stretch, or (after 0.8 s without a key) logs it and starts a new one
    /// where the text goes.
    @MainActor private func typed(at host: Double) {
        if let s = typingSpan, host - s.last <= TypingSpan.gap { typingSpan?.last = host; return }
        endTyping()
        let p = Self.typingFocus() ?? lastClick ?? CGEvent(source: nil)?.location ?? .zero
        typingSpan = (host, host, p)
    }

    @MainActor private func endTyping() {
        guard let s = typingSpan else { return }
        log.append(.init(host: s.start, gx: s.at.x, gy: s.at.y, kind: .typing(untilHost: s.last)))
        typingSpan = nil
    }

    /// Where typed text goes, in global CG coordinates: the caret (the selection's bounds), else the focused element's
    /// center. Nil without Accessibility or when the app doesn't say (AX calls give up after 0.25 s).
    @MainActor static func typingFocus() -> CGPoint? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, "AXFocusedUIElement" as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        func rect(_ v: CFTypeRef?) -> CGRect? {
            guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
            var r = CGRect.zero
            return AXValueGetValue(v as! AXValue, .cgRect, &r) && r.width + r.height > 0 ? r : nil
        }
        var range: CFTypeRef?, bounds: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &range) == .success, let range,
           AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForRange" as CFString, range, &bounds) == .success,
           let caret = rect(bounds) {
            return CGPoint(x: caret.midX, y: caret.midY)
        }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &size) == .success, let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
    }

    /// Named keys, by key code, as the video shows them (all but Space and Tab type no text); any other key shows its
    /// unshifted character.
    nonisolated static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖",
        kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

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
        endTyping()
        try? await stream.stopCapture()
        for t in [SCStreamOutputType.screen, .audio, .microphone] { try? stream.removeStreamOutput(self, type: t) }
        stream = nil
        let cameraStart = await camera?.stop()

        // drain the capture queue, then close the file
        let (start, last, dropped, pauses): (CMTime?, CMTime, Int, [(start: CMTime, end: CMTime)]) = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: (self.sessionStart, self.lastVideo, self.dropped, self.pauses)) }
        }
        guard let start else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dir)
            throw LoupecastError("No screen frames arrived. Check the Screen Recording permission.")
        }
        let end = max(stopHost, last)
        videoIn.markAsFinished(); systemIn?.markAsFinished(); micIn?.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LoupecastError("Couldn’t finish the recording file.") }
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
        let paused = pauses.map { ClipRange(start: max(0, ($0.start - start).seconds), end: (($0.end.isValid ? $0.end : end) - start).seconds) }
        var project = Project(name: Self.name(Date()), duration: duration,
                              pixelWidth: pixelSize.0, pixelHeight: pixelSize.1, pointPixelScale: scale,
                              cursor: events.cursor, clicks: events.clicks, shortcuts: events.shortcuts, typing: events.typing,
                              paused: paused)
        project.camera = cameraStart.map { CameraOverlay(offset: $0 - start.seconds) }   // recording-relative, like everything stored
        project.cursorOverlay = cursorShapes?.overlay(sessionStartHost: start.seconds)
        project.motionBlur = true                        // new recordings blur their zooms (older files stay sharp)
        LookDefaults.saved?.apply(to: &project)          // the aspect, background… picked last in an editor
        try project.save(to: dir.appendingPathComponent(Project.fileName))
        return project
    }

    static func name(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = String(localized: "MMM d HH.mm.ss", comment: "Date in a recording's name")
        return String(localized: "Recording \(f.string(from: date))")
    }
}

/// The system cursor's shapes during a recording: each new one is saved as cursors/<n>.png in the recording folder, with
/// the host time it started showing. Keyed by its pixels and hot spot.
@MainActor
final class CursorShapes {
    let dir: URL
    private(set) var images: [CursorOverlay.Image] = []
    private(set) var changes: [(host: Double, image: Int)] = []
    private var last: Int?

    init(dir: URL) { self.dir = dir }

    /// Saves the system's current shape if it changed (an arrow when macOS won't say which).
    func note(_ shown: NSCursor? = NSCursor.currentSystem) {
        let cursor = shown ?? NSCursor.arrow
        guard let cg = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = cg.dataProvider?.data else { return }
        var h = Hasher()
        h.combine(data as Data); h.combine(cursor.hotSpot.x); h.combine(cursor.hotSpot.y)
        let key = h.finalize()
        guard key != last else { return }
        last = key
        let host = ProcessInfo.processInfo.systemUptime
        if let i = keys.firstIndex(of: key) { changes.append((host, i)); return }   // seen before: no second file
        let file = "cursors/\(images.count).png", url = dir.appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            NSLog("Loupecast: cursor image not saved: %@", describe(error))
            return
        }
        images.append(.init(file: file, width: cursor.image.size.width, height: cursor.image.size.height, hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y))
        keys.append(key)
        changes.append((host, images.count - 1))
    }
    private var keys: [Int] = []

    /// Recording-relative; a shape from before the first frame shows from 0.
    func overlay(sessionStartHost: Double) -> CursorOverlay {
        CursorOverlay(images: images, shapes: changes.map { .init(t: max(0, $0.host - sessionStartHost), image: $0.image) })
    }
}

#if DEBUG
extension Recorder {
    nonisolated(unsafe) static var lastSessionStartHost = 0.0
}
#endif
