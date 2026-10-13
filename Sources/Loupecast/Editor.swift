import AVFoundation
import AVKit
import AppKit
import Carbon.HIToolbox
import LoupecastCore
import LoupecastRender
import SwiftUI

enum ExportState: Equatable {
    case idle, running(Double), done(URL), failed(String)
}

enum Selection: Equatable {
    case none, clip(UUID), zoom(UUID)
}

@MainActor @Observable
final class EditorModel {
    let dir: URL
    /// The window's undo manager (EditorController hands it to the window).
    let undo = UndoManager()
    var project: Project {
        didSet { if project != oldValue { projectChanged(old: oldValue) } }
    }
    /// Playhead in recording time, always on kept material (or at the very end of it).
    var playhead = 0.0
    var isPlaying = false
    var selection = Selection.none
    var thumbnails: [NSImage] = []
    var exportState = ExportState.idle
    /// Audio tracks in the recording; the volume controls show only these.
    private(set) var hasSystemAudio = false
    private(set) var hasMicrophone = false

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private(set) var edit: EditComposition?
    @ObservationIgnored private var source: SourceTracks?
    /// Clips the player's current item was built from: player time ↔ recording time goes through these.
    @ObservationIgnored private var built: [ClipRange] = []
    /// Project before the drag in progress; the drag becomes one undo step and one player update.
    @ObservationIgnored private var dragBase: Project?
    /// Project before a volume slider moved: the player hears every value, the drag is one undo step.
    @ObservationIgnored private var volumeBase: Project?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?

    init(dir: URL, project: Project) {
        self.dir = dir
        self.project = project
        playhead = project.trimIn
    }

    var videoURL: URL { dir.appendingPathComponent(project.videoFile) }
    var selectedZoom: ZoomSegment? { project.zooms.first { selection == .zoom($0.id) } }
    /// Composition time of the playhead and total kept length, as the time label shows them.
    var position: Double { project.clips.compositionTime(playhead) }
    var total: Double { project.clips.totalLength }

    func load() async {
        do {
            let source = try await SourceTracks.load(videoURL)
            self.source = source
            hasSystemAudio = source.hasSystemAudio
            hasMicrophone = source.hasMicrophone
            rebuild()
            timeObserver = player.addPeriodicTimeObserver(forInterval: Composer.frameDuration, queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.dragBase == nil else { return }
                    self.playhead = self.built.recordingTime(t.seconds)
                }
            }
            rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, change in
                let playing = (change.newValue ?? 0) != 0
                Task { @MainActor in self?.isPlaying = playing }
            }
            thumbnails = await makeThumbnails(count: 24)
        } catch {
            exportState = .failed(describe(error))
        }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObserver = nil
        if let saveTask { saveTask.cancel(); save() }   // an edit still inside its debounce
        Self.saves.sync {}   // the last save is on disk before the window goes away (or the app quits)
        undo.removeAllActions()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: player

    /// New item from the kept clips; the playhead stays on the same recording moment.
    private func rebuild() {
        guard let source else { return }
        do {
            let e = try Composer.make(project: project, source: source)
            let item = AVPlayerItem(asset: e.asset)
            item.videoComposition = e.videoComposition
            item.audioMix = e.audioMix
            item.audioTimePitchAlgorithm = Composer.pitchAlgorithm
            let resume = player.rate != 0
            edit = e
            built = project.clips
            player.replaceCurrentItem(with: item)
            seek(playhead)
            if resume { player.play() }
        } catch {
            exportState = .failed(describe(error))
        }
    }

    /// Same kept material, new camera path and volumes: the video composition and the audio mix change.
    private func refreshComposition() {
        guard let item = player.currentItem, let edit else { return }
        built = project.clips
        if player.rate == 0 { seek(playhead) }   // off the item's last instant first, then re-render this frame
        item.videoComposition = Composer.videoComposition(project: project, trackID: edit.videoTrackID, duration: edit.asset.duration)
        refreshAudio()
    }

    private func refreshAudio() {
        guard let item = player.currentItem, let edit else { return }
        item.audioMix = Composer.audioMix(edit.asset, project: project, micTracks: edit.micTracks)
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); return }
        if player.currentItem?.status == .failed {
            NSLog("Loupecast: preview failed, rebuilding: %@", player.currentItem?.error.map(describe) ?? "?")
            rebuild()
        }
        let c = built.compositionTime(playhead)
        let start = built.playStart(from: c)
        guard start != c else { player.play(); return }
        // play only once the jump back has landed: playing first runs out the last frame and ends there
        seek(built.recordingTime(start)) { [weak self] in self?.player.play() }
    }

    /// Moves the playhead to recording time `t`, snapped onto kept material. The player never parks
    /// on the composition's last instant; that is where a paused item cannot preroll.
    func seek(_ t: Double, then: (@MainActor () -> Void)? = nil) {
        playhead = project.clips.recordingTime(project.clips.compositionTime(t))
        let last = max(0, built.totalLength - Project.frameDuration)
        let c = min(built.compositionTime(playhead), last)
        player.seek(to: Composer.time(c), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished, let then else { return }     // superseded: the newer seek decides
            Task { @MainActor in then() }
        }
    }

    func step(_ frames: Int) {
        player.pause()
        let f = (position / Project.frameDuration).rounded() + Double(frames)
        let last = max(0, (total / Project.frameDuration).rounded(.up) - 1)
        seek(project.clips.recordingTime(min(max(0, f), last) * Project.frameDuration))
    }

    // MARK: edits (each one undo step)

    func edit(_ name: String.LocalizationValue, _ change: (inout Project) -> Void) {
        let before = project
        change(&project)
        if dragBase == nil, project != before { undo.registerChange(self, \.project, before: before, name: String(localized: name)) }
    }

    func undoEdit() { if dragBase == nil, undo.canUndo { undo.undo() } }
    func redoEdit() { if dragBase == nil, undo.canRedo { undo.redo() } }

    private var clipAtPlayhead: ClipRange? {
        project.clips.index(containing: playhead).map { project.clips[$0] } ?? project.clips.last
    }

    func markIn() { if let c = clipAtPlayhead { edit("Set Start") { $0.setClipStart(id: c.id, playhead) } } }
    func markOut() { if let c = clipAtPlayhead { edit("Set End") { $0.setClipEnd(id: c.id, playhead) } } }
    func split() { edit("Split") { $0.split(at: playhead) } }

    /// Zoom levels the editor offers; Add Zoom uses the one picked last.
    static let zoomLevels = [1.5, 2, 2.5, 3]
    static let zoomScaleKey = "zoomScale"

    func addZoom() {
        let scale = UserDefaults.standard.object(forKey: Self.zoomScaleKey) as? Double ?? AutoZoom.defaultScale
        edit("Add Zoom") { selection = .zoom($0.addZoom(at: playhead, scale: scale).id) }
    }

    /// `f`: the click as a fraction of the preview (top-left origin), which shows the whole canvas.
    func pinFocus(_ id: UUID, at f: CGPoint) {
        let canvas = Composer.renderSize(project.aspect)
        guard let p = Composer.recordingPoint(canvas: CGPoint(x: f.x * canvas.width, y: f.y * canvas.height), project: project, at: playhead)
        else { return }
        edit("Zoom Focus") { $0.setZoomFocus(id: id, p) }
    }

    /// Slider moves: applied live, recorded as one undo step by `endVolumeChange`.
    func changeVolume(_ track: WritableKeyPath<Project, Double>, to v: Double) {
        if volumeBase == nil { volumeBase = project }
        project[keyPath: track] = Project.volumes.clamp(v)
    }

    func endVolumeChange() {
        guard let base = volumeBase else { return }
        volumeBase = nil
        if project != base { undo.registerChange(self, \.project, before: base, name: String(localized: "Volume")) }
    }

    func setZoomScale(_ id: UUID, _ scale: Double) {
        UserDefaults.standard.set(scale, forKey: Self.zoomScaleKey)
        edit("Zoom Level") { $0.setZoomScale(id: id, scale) }
    }

    func deleteSelected() {
        switch selection {
        case .clip(let id): edit("Delete Clip") { $0.removeClip(id: id) }
        case .zoom(let id): edit("Delete Zoom") { $0.removeZoom(id: id) }
        case .none: return
        }
    }

    // MARK: timeline gestures

    /// Press on the strip: select the clip under it (nothing over removed material) and scrub there.
    func scrub(_ t: Double, began: Bool) {
        if began {
            player.pause()
            selection = project.clips.index(containing: t).map { .clip(project.clips[$0].id) } ?? .none
        }
        seek(t)
    }

    func beginDrag() {
        guard dragBase == nil else { return }
        dragBase = project
        player.pause()
    }

    /// Clip edge drag: live timeline, preview frame when the edge is on material the player has.
    func dragClip(_ id: UUID, edge: HorizontalEdge, to t: Double) {
        beginDrag()
        selection = .clip(id)
        edit("Trim") { edge == .leading ? $0.setClipStart(id: id, t) : $0.setClipEnd(id: id, t) }
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        playhead = edge == .leading ? c.start : max(c.start, c.end - Project.frameDuration)
        if built.index(containing: playhead) != nil {
            player.seek(to: Composer.time(built.compositionTime(playhead)), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func dragZoom(_ id: UUID, edge: HorizontalEdge, to t: Double) {
        beginDrag()
        edit("Zoom Length") { edge == .leading ? $0.setZoomStart(id: id, t) : $0.setZoomEnd(id: id, t) }
    }

    func endDrag(_ name: String.LocalizationValue) {
        guard let base = dragBase else { return }
        dragBase = nil
        guard project != base else { return }
        undo.registerChange(self, \.project, before: base, name: String(localized: name))
        applyToPlayer(old: base)
    }

    private func projectChanged(old: Project) {
        scheduleSave()
        if case .clip(let id) = selection, !project.clips.contains(where: { $0.id == id }) { selection = .none }
        if case .zoom(let id) = selection, !project.zooms.contains(where: { $0.id == id }) { selection = .none }
        if dragBase == nil { applyToPlayer(old: old) }
    }

    private func applyToPlayer(old: Project) {
        func material(_ c: [ClipRange]) -> [[Double]] { c.keptRanges.map { [$0.start, $0.end, $0.speed] } }
        var volumesOnly = project
        volumesOnly.systemVolume = old.systemVolume; volumesOnly.micVolume = old.micVolume
        // same material: every other edit (zooms, clip ids, aspect, style…) is a new video composition
        if material(project.clips) != material(built) { rebuild() }
        else if volumesOnly == old { refreshAudio() }       // a volume slider moving: the picture stays put
        else { refreshComposition() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
            self?.saveTask = nil
        }
    }

    /// One serial queue for every editor: saves land in order, and encoding an hour-long project (~20 MB of
    /// cursor samples, hundreds of ms) never blocks the main thread. The value is copied here, on the main actor.
    private static let saves = DispatchQueue(label: "loupecast.autosave", qos: .utility)

    private func save() {
        let project = project, url = dir.appendingPathComponent(Project.fileName)
        Self.saves.async {
            do { try project.save(to: url) }
            catch { NSLog("Loupecast: autosave failed: %@", describe(error)) }
        }
    }

    // MARK: export

    /// Running exports by output file, across all editors: an export keeps going after its window closes.
    static private(set) var exports: [URL: Task<Void, Never>] = [:]
    static var exportDir = Exporter.moviesDir

    enum ExportFormat { case mp4, gif }

    func export(_ format: ExportFormat = .mp4) {
        if exportState.isRunning { return }
        exportState = .running(0)
        let project = project, video = videoURL
        let url = Exporter.defaultURL(in: Self.exportDir, taken: Set(Self.exports.keys), fileExtension: format == .gif ? "gif" : "mp4")
        let task = Task {
            do {
                let progress: @Sendable (Double) -> Void = { p in
                    Task { @MainActor in
                        if self.exportState.isRunning { self.exportState = .running(p) }
                    }
                }
                switch format {
                case .mp4: try await Exporter.export(project: project, videoURL: video, to: url, progress: progress)
                case .gif: try await GIFExporter.export(project: project, videoURL: video, to: url, progress: progress)
                }
                exportState = .done(url)
            } catch {
                exportState = Task.isCancelled ? .idle : .failed(describe(error))
            }
            Self.exports[url] = nil
            exportTask = nil
            Updater.installIfIdle()   // an update waits for running exports
        }
        Self.exports[url] = task
        exportTask = task
    }

    /// The exporter stops reading, cancels the writer and deletes the partial file; the state goes back to idle.
    func cancelExport() { exportTask?.cancel() }

    private func makeThumbnails(count: Int) async -> [NSImage] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        gen.maximumSize = CGSize(width: 320, height: 200)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = gen.requestedTimeToleranceBefore
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) / Double(count) * project.duration, preferredTimescale: 600) }
        var out: [NSImage] = []
        for await r in gen.images(for: times) {
            if let cg = try? r.image { out.append(NSImage(cgImage: cg, size: .zero)) }
        }
        return out
    }
}

func describe(_ error: Error) -> String {
    let ns = error as NSError
    var parts = [ns.localizedDescription]
    if let reason = ns.localizedFailureReason, !parts.contains(reason) { parts.append(reason) }
    if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append("\(u.localizedDescription) (\(u.domain) \(u.code))") }
    return parts.joined(separator: " — ")
}

func timecode(_ t: Double) -> String {
    let cs = Int((max(0, t) * 100).rounded())
    return String(format: "%d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
}

// MARK: - Window

@MainActor
final class EditorController: NSObject, NSWindowDelegate {
    let model: EditorModel
    let window: NSWindow
    var onClose: (() -> Void)?
    private var keyMonitor: Any?

    init(dir: URL, project: Project) {
        model = EditorModel(dir: dir, project: project)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        let host = NSHostingView(rootView: EditorView(model: model))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.title = project.name
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        // One key handler for the whole window, ahead of whichever view holds focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) ?? false } ? nil : e
        }
        Task { await model.load() }
    }

    func show() { window.bringToFront() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }

    /// Space play/pause, ← → one frame, I / O clip in/out, D split, Delete removes the selection,
    /// ⌘Z / ⇧⌘Z undo/redo. Returns true when the key was consumed.
    func handle(_ e: NSEvent) -> Bool {
        // addressed to this window, or to no window while this one is key
        guard (e.window ?? (window.isKeyWindow ? window : nil)) === window else { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(e.keyCode)
        if mods.contains(.command) {
            switch (key, mods) {
            case (kVK_ANSI_W, [.command]): window.performClose(nil)
            case (kVK_ANSI_Z, [.command]): model.undoEdit()
            case (kVK_ANSI_Z, [.command, .shift]): model.redoEdit()
            default: return false
            }
            return true
        }
        guard mods.isEmpty else { return false }
        let arrows = [kVK_LeftArrow, kVK_RightArrow]
        if e.isARepeat, !arrows.contains(key) { return [kVK_Space, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_D, kVK_Delete, kVK_ForwardDelete].contains(key) }
        #if DEBUG
        DebugHooks.keyLog(e, model)
        #endif
        switch key {
        case kVK_Space: model.togglePlay()
        case kVK_LeftArrow: model.step(-1)
        case kVK_RightArrow: model.step(1)
        case kVK_ANSI_I: model.markIn()
        case kVK_ANSI_O: model.markOut()
        case kVK_ANSI_D: model.split()
        case kVK_Delete, kVK_ForwardDelete: model.deleteSelected()
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.close()
        onClose?()
    }
}

/// A click never parks keyboard focus on a control here (buttons, the zoom switch), so nothing but
/// the window's key handler sees Space and friends. SwiftUI's `.focusable(false)` alone leaves its
/// NSButton accepting first responder.
final class EditorWindow: LoupecastWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        responder is NSControl ? false : super.makeFirstResponder(responder)
    }
}

// MARK: - Views

/// 16 pt outer padding, 16 pt preview → toolbar, 12 pt toolbar → timeline, one window background.
struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            let size = Composer.renderSize(model.project.aspect)
            PlayerView(player: model.player)
                .allowsHitTesting(false)                // a click here must not take keyboard focus
                .aspectRatio(size.width / size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    // with a zoom selected, a click on the picture pins that zoom's focus there
                    if let seg = model.selectedZoom {
                        GeometryReader { g in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { p in model.pinFocus(seg.id, at: CGPoint(x: p.x / g.size.width, y: p.y / g.size.height)) }
                                .pointerStyle(.rectSelection)
                                .help("Click to hold the selected zoom on that spot")
                        }
                    }
                }
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ControlBar(model: model)
                .padding(.top, 16)
            TimelineView(model: model)
                .padding(.top, 12)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The composition is the whole picture, so every bit of AVPlayerView chrome is off.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.allowsVideoFrameAnalysis = false          // Live Text / visual-lookup button
        v.updatesNowPlayingInfoCenter = false
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

/// Transport and output on top, the selection's own controls below.
struct ControlBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            topRow
            SelectionBar(model: model)
        }
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(model.isPlaying ? String(localized: "Pause (Space)") : String(localized: "Play (Space)"))
            .accessibilityLabel(model.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            Text("\(Text(timecode(model.position)))\(Text(" / \(timecode(model.total))").foregroundStyle(.secondary))")
                .font(.callout.monospacedDigit())
                .fixedSize()
            let removed = model.project.duration - model.project.clips.reduce(0) { $0 + $1.length }   // recording time: a faster clip cuts nothing
            if removed > 0.005 {
                Label {
                    Text("Cut \(timecode(removed))")
                } icon: {
                    Image(systemName: "scissors").imageScale(.small)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Length cut out (D splits, Delete removes, ⌘Z undoes)")
            }

            Spacer(minLength: 12)

            ExportStatus(model: model)
            if model.hasSystemAudio || model.hasMicrophone { VolumeButton(model: model) }
            Menu {
                Picker("Background", selection: Binding(get: { model.project.style },
                                                        set: { s in model.edit("Background") { $0.style = s } })) {
                    ForEach(StylePreset.allCases, id: \.self) { p in
                        Label { Text(p.title) } icon: { Image(nsImage: p.swatch) }.tag(p)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(nsImage: model.project.style.swatch)
            }
            .menuIndicator(.visible)
            .fixedSize()
            .focusable(false)
            .help("Background")
            .accessibilityLabel("Background")
            Picker("Aspect Ratio", selection: Binding(get: { model.project.aspect },
                                              set: { a in model.edit("Aspect Ratio") { $0.aspect = a } })) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .focusable(false)
            .help("Export frame (16:9 landscape, 9:16 portrait, 1:1 square)")
            .accessibilityLabel("Export frame")
            if model.project.aspect != .landscape {
                Toggle("Fill Frame", isOn: Binding(get: { model.project.fill }, set: { on in model.edit("Fill Frame") { $0.fill = on } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .focusable(false)
                    .help("Crop the recording to fill the frame; it follows the cursor")
            }
            Button(action: model.addZoom) { Label("Add Zoom", systemImage: "plus.magnifyingglass") }
                .buttonStyle(.bordered)
                .focusable(false)
                .help("Add a 2-second zoom at the playhead")
            Menu {
                Button("MP4 Video") { model.export(.mp4) }
                Button("GIF (no sound, loops)") { model.export(.gif) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            } primaryAction: {
                model.export(.mp4)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .focusable(false)
            .disabled(model.exportState.isRunning || model.edit == nil)
            .help("Export an MP4, or pick GIF from the arrow")
        }
    }
}

/// One row tall whatever is selected, so selecting never moves the preview.
struct SelectionBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.selection {
            case .zoom:
                if let seg = model.selectedZoom { zoomControls(seg) }
            case .clip(let id):
                if let clip = model.project.clips.first(where: { $0.id == id }) {
                    // here "2×" is meant: it is playback speed
                    Picker("Speed", selection: Binding(get: { clip.speed }, set: { s in model.edit("Speed") { $0.setClipSpeed(id: id, s) } })) {
                        ForEach(Project.clipSpeeds, id: \.self) { Text(verbatim: "\(Int($0))×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .focusable(false)
                    .help("Play the selected clip faster")
                }
                hint("D splits at the playhead, Delete removes the selected clip.")
            case .none:
                hint("Select a zoom or a clip to change it.")
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }

    @ViewBuilder private func zoomControls(_ seg: ZoomSegment) -> some View {
        Toggle("Use Zoom", isOn: Binding(get: { seg.isEnabled },
                                      set: { on in model.edit(on ? "Turn Zoom On" : "Turn Zoom Off") { $0.setZoomEnabled(id: seg.id, on) } }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .focusable(false)
        // a percentage and a magnifier, never "2×": that reads as playback speed
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Zoom Level", selection: Binding(get: { seg.scale }, set: { model.setZoomScale(seg.id, $0) })) {
                ForEach(EditorModel.zoomLevels, id: \.self) { Text(verbatim: "\(Int($0 * 100))%").tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .focusable(false)
        }
        .help("Zoom level of the selected zoom")
        Toggle("Follow Cursor", isOn: Binding(get: { seg.followsCursor },
                                             set: { on in model.edit("Follow Cursor") { $0.setZoomFollowsCursor(id: seg.id, on) } }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .focusable(false)
            .help("Off: the zoom holds still. Click the preview to pick the spot.")
        Button(role: .destructive, action: model.deleteSelected) { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Delete the selected zoom (Delete)")
            .accessibilityLabel("Delete the selected zoom")
        hint("Click the preview to hold this zoom on a spot.")
    }
}

/// Speaker button with a popover: a slider and a mute button per audio track the recording has.
struct VolumeButton: View {
    @Bindable var model: EditorModel
    @State private var shown = false

    var body: some View {
        let muted = (!model.hasSystemAudio || model.project.systemVolume == 0) && (!model.hasMicrophone || model.project.micVolume == 0)
        Button { shown.toggle() } label: { Image(systemName: muted ? "speaker.slash" : "speaker.wave.2") }
            .buttonStyle(.bordered)
            .focusable(false)
            .help("Volume")
            .accessibilityLabel("Volume")
            .popover(isPresented: $shown, arrowEdge: .bottom) { VolumeControls(model: model) }
    }
}

/// A slider and a mute button per audio track the recording has.
struct VolumeControls: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasSystemAudio { row("Computer Audio", \.systemVolume) }
            if model.hasMicrophone { row("Microphone", \.micVolume) }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func row(_ title: LocalizedStringKey, _ track: WritableKeyPath<Project, Double>) -> some View {
        let v = model.project[keyPath: track]
        return HStack(spacing: 8) {
            Button {
                model.edit(v == 0 ? "Unmute" : "Mute") { $0[keyPath: track] = v == 0 ? 1 : 0 }
            } label: {
                Image(systemName: v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(v == 0 ? "Unmute" : "Mute")
            .accessibilityLabel(v == 0 ? "Unmute" : "Mute")
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: Binding(get: { v }, set: { model.changeVolume(track, to: $0) }), in: Project.volumes) { editing in
                if !editing { model.endVolumeChange() }
            }
            .accessibilityLabel(Text(title))
            Text(verbatim: "\(Int((v * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
    }
}

extension StylePreset {
    var title: String {
        switch self {
        case .pastel: String(localized: "Pastel Gradient")
        case .dark: String(localized: "Dark Gradient")
        case .light: String(localized: "Light Gray")
        case .graphite: String(localized: "Graphite")
        case .blue: String(localized: "Blue")
        case .plain: String(localized: "No Padding")
        }
    }

    /// The background's two corners as a small rounded gradient.
    var swatch: NSImage {
        let s = FrameStyle(self)
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSGradient(starting: NSColor(ciColor: s.topLeft), ending: NSColor(ciColor: s.bottomRight))?.draw(in: path, angle: -45)
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }
}

extension ExportState {
    var isRunning: Bool { if case .running = self { true } else { false } }
}

struct ExportStatus: View {
    @Bindable var model: EditorModel
    @State private var copied = false

    /// The file itself, as Finder copies it: Slack, GitHub issues and Mail attach it on paste.
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    var body: some View {
        switch model.exportState {
        case .idle:
            EmptyView()
        case .running(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 110)
                Text("\(Int(p * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Button(action: model.cancelExport) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .focusable(false)
                    .help("Cancel Export")
                    .accessibilityLabel("Cancel Export")
            }
        case .done(let url):
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .help("Drag the video into another app")
                    .accessibilityLabel(url.lastPathComponent)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                    .fixedSize()
                    .focusable(false)
                    .help(url.path)
                Button(copied ? "Copied" : "Copy") {
                    Self.copy(url)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(.link)
                .fixedSize()
                .focusable(false)
                .help("Copy the video to paste it into Slack, an issue or an email")
            }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: 340, alignment: .leading)
                .help(text)
        }
    }
}

/// The whole recording. Kept clips carry grips at both edges (the selected one is outlined);
/// removed ranges are dimmed and hatched.
struct TimelineView: View {
    @Bindable var model: EditorModel
    static let stripHeight: CGFloat = 56
    static let laneHeight: CGFloat = 28
    static let gap: CGFloat = 8
    static let radius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let d = max(model.project.duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / d) * w }
            let t: (CGFloat) -> Double = { Double(min(max(0, $0), w) / w) * d }
            let clips = model.project.clips
            let H = Self.stripHeight

            ZStack(alignment: .topLeading) {
                // click selects the clip under it and moves the playhead there; drag scrubs
                ZStack(alignment: .topLeading) {
                    ThumbnailStrip(images: model.thumbnails)
                    ForEach(Array(zip([0] + clips.map(\.end), clips.map(\.start) + [d])).filter { $0.1 - $0.0 > 1e-6 }, id: \.0) { a, b in
                        RemovedRange().frame(width: x(b) - x(a)).offset(x: x(a))
                    }
                }
                .frame(width: w, height: H)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { model.scrub(t($0.location.x), began: $0.translation == .zero) })
                .accessibilityLabel("Timeline")

                ForEach(clips) { clip in
                    ClipHandles(selected: model.selection == .clip(clip.id), speed: clip.speed, width: x(clip.end) - x(clip.start), height: H,
                                drag: { edge, px in model.dragClip(clip.id, edge: edge, to: t(px)) },
                                ended: { model.endDrag("Trim") })
                        .offset(x: x(clip.start))
                }

                ZoomLane(model: model, width: w, duration: d)
                    .frame(width: w, height: Self.laneHeight)
                    .offset(y: H + Self.gap)

                Playhead(height: H + Self.gap + Self.laneHeight)
                    .offset(x: x(model.playhead) - Playhead.width / 2, y: 0)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named("timeline"))
        }
        .frame(height: Self.stripHeight + Self.gap + Self.laneHeight)
    }
}

struct ThumbnailStrip: View {
    let images: [NSImage]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(images.indices, id: \.self) { i in
                    Image(nsImage: images[i])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width / CGFloat(max(1, images.count)), height: geo.size.height)
                        .clipped()
                }
            }
        }
        .background(.quaternary)
    }
}

/// Cut material: dimmed to 45 % and hatched.
struct RemovedRange: View {
    var body: some View {
        Color.black.opacity(0.55)
            .overlay { Hatch(color: .white.opacity(0.28)) }
            .clipped()
            .accessibilityHidden(true)
    }
}

/// Slim accent grips at both edges of a clip (the trim handles); the selected clip also gets
/// 2 pt rails across the top and bottom.
struct ClipHandles: View {
    static let grip: CGFloat = 8
    /// Resets on end and on cancel alike, so a drag can never stay open.
    @GestureState private var dragging = false
    let selected: Bool
    let speed: Double
    let width: CGFloat
    let height: CGFloat
    let drag: (HorizontalEdge, CGFloat) -> Void
    let ended: () -> Void

    var body: some View {
        let g = min(Self.grip, max(3, width / 2 - 1))
        ZStack(alignment: .leading) {
            ClipFrame(grip: g, rail: selected ? 2 : 0)
                .fill(Color.accentColor)
                .allowsHitTesting(false)
            grip(.leading, width: g)
            grip(.trailing, width: g).offset(x: width - g)
            if speed != 1, width > 2 * g + 24 {
                Text(verbatim: "\(Int(speed))×")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .background(Color.accentColor, in: Capsule())
                    .frame(width: width, height: height, alignment: .top)
                    .padding(.top, 3)
                    .allowsHitTesting(false)
                    .accessibilityLabel(String(localized: "Plays at \(Int(speed))× speed"))
            }
        }
        .frame(width: max(0, width), height: height, alignment: .leading)
        .onChange(of: dragging) { _, now in if !now { ended() } }
    }

    private func grip(_ edge: HorizontalEdge, width g: CGFloat) -> some View {
        Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: g, height: height)
            .contentShape(Rectangle().inset(by: -4))
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($dragging) { _, d, _ in d = true }
                .onChanged { drag(edge, $0.location.x + (edge == .leading ? -g / 2 : g / 2)) })
            .accessibilityLabel(edge == .leading ? String(localized: "Adjust Clip Start") : String(localized: "Adjust Clip End"))
    }
}

struct ClipFrame: Shape {
    let grip: CGFloat, rail: CGFloat
    func path(in r: CGRect) -> Path {
        let outer: CGFloat = 6, inner: CGFloat = 2
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: grip, height: r.height),
                         cornerRadii: .init(topLeading: outer, bottomLeading: outer, bottomTrailing: inner, topTrailing: inner))
        p.addRoundedRect(in: CGRect(x: r.maxX - grip, y: r.minY, width: grip, height: r.height),
                         cornerRadii: .init(topLeading: inner, bottomLeading: inner, bottomTrailing: outer, topTrailing: outer))
        if rail > 0, r.width > 2 * grip {
            p.addRect(CGRect(x: r.minX + grip, y: r.minY, width: r.width - 2 * grip, height: rail))
            p.addRect(CGRect(x: r.minX + grip, y: r.maxY - rail, width: r.width - 2 * grip, height: rail))
        }
        return p
    }
}

struct ZoomLane: View {
    static let capsuleHeight: CGFloat = 22
    @Bindable var model: EditorModel
    let width: CGFloat
    let duration: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: TimelineView.radius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
                .contentShape(Rectangle())
                .onTapGesture { model.selection = .none }
            ForEach(model.project.zooms) { seg in
                ZoomCapsule(model: model, seg: seg, isSelected: model.selection == .zoom(seg.id), width: width, duration: duration)
                    .equatable()
            }
        }
    }
}

/// One zoom on the lane. Compared by its values, so after an edit SwiftUI redraws only the capsules it changed:
/// an hour-long recording has hundreds, and redrawing all of them was most of an edit's main-thread time.
struct ZoomCapsule: View, Equatable {
    let model: EditorModel   // actions only; reading it in `body` would redraw every capsule on every change
    let seg: ZoomSegment
    let isSelected: Bool
    let width: CGFloat
    let duration: Double
    @GestureState private var dragging = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.seg == b.seg && a.isSelected == b.isSelected && a.width == b.width && a.duration == b.duration
    }

    private func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * width }

    var body: some View {
        let w = x(seg.end) - x(seg.start)
        let tint = seg.isEnabled ? Color.accentColor : Color.gray
        Capsule()
            .fill(tint.opacity(isSelected ? 1 : seg.isEnabled ? 0.35 : 0.4))
            .overlay { if !seg.isEnabled { Hatch(color: .secondary).opacity(0.5).clipShape(Capsule()) } }
            .overlay(Capsule().strokeBorder(isSelected ? .white : tint, lineWidth: isSelected ? 2 : 1))
            .overlay {
                // no scale text: users read "2.0×" as playback speed
                if w > 28 {
                    Image(systemName: seg.isEnabled ? "plus.magnifyingglass" : "eye.slash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : seg.isEnabled ? .primary : .secondary)
                }
            }
            .contentShape(Capsule())
            .onTapGesture { model.selection = .zoom(seg.id) }
            .overlay(alignment: .leading) { edge(.leading) }
            .overlay(alignment: .trailing) { edge(.trailing) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom")
            .accessibilityValue(seg.isEnabled ? "\(timecode(seg.start))–\(timecode(seg.end))" : String(localized: "\(timecode(seg.start))–\(timecode(seg.end)), off"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .frame(width: max(8, w), height: ZoomLane.capsuleHeight)
            .offset(x: x(seg.start))
            .onChange(of: dragging) { _, now in if !now { model.endDrag("Zoom Length") } }
    }

    private func edge(_ edge: HorizontalEdge) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($dragging) { _, d, _ in d = true }
                .onChanged { model.dragZoom(seg.id, edge: edge, to: Double(min(max(0, $0.location.x), width) / width) * duration) })
    }
}

/// Diagonal stripes: removed material and disabled zoom segments.
struct Hatch: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for x in stride(from: -size.height, to: size.width, by: 6) {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            ctx.stroke(p, with: .color(color), lineWidth: 1)
        }
    }
}

struct Playhead: View {
    static let width: CGFloat = 2
    let height: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(.white).frame(width: 9, height: 9)
            Rectangle().fill(.white).frame(width: Self.width)
        }
        .frame(width: 9, height: height + 4)
        .offset(x: -3.5, y: -4)
        .shadow(color: .black.opacity(0.6), radius: 1)
    }
}
