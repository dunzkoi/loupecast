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

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private(set) var edit: EditComposition?
    @ObservationIgnored private var source: SourceTracks?
    /// Clips the player's current item was built from: player time ↔ recording time goes through these.
    @ObservationIgnored private var built: [ClipRange] = []
    /// Project before the drag in progress; the drag becomes one undo step and one player update.
    @ObservationIgnored private var dragBase: Project?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
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
            source = try await SourceTracks.load(videoURL)
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
        saveTask?.cancel()
        save()
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

    /// Same kept material, new camera path: only the video composition changes.
    private func refreshComposition() {
        guard let item = player.currentItem, let edit else { return }
        built = project.clips
        if player.rate == 0 { seek(playhead) }   // off the item's last instant first, then re-render this frame
        item.videoComposition = Composer.videoComposition(project: project, trackID: edit.videoTrackID, duration: edit.asset.duration)
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

    func edit(_ name: String, _ change: (inout Project) -> Void) {
        let before = project
        change(&project)
        if dragBase == nil, project != before { undo.registerChange(self, \.project, before: before, name: name) }
    }

    func undoEdit() { if dragBase == nil, undo.canUndo { undo.undo() } }
    func redoEdit() { if dragBase == nil, undo.canRedo { undo.redo() } }

    private var clipAtPlayhead: ClipRange? {
        project.clips.index(containing: playhead).map { project.clips[$0] } ?? project.clips.last
    }

    func markIn() { if let c = clipAtPlayhead { edit("시작 지점") { $0.setClipStart(id: c.id, playhead) } } }
    func markOut() { if let c = clipAtPlayhead { edit("끝 지점") { $0.setClipEnd(id: c.id, playhead) } } }
    func split() { edit("자르기") { $0.split(at: playhead) } }

    func addZoom() { edit("줌 추가") { selection = .zoom($0.addZoom(at: playhead).id) } }

    func deleteSelected() {
        switch selection {
        case .clip(let id): edit("클립 삭제") { $0.removeClip(id: id) }
        case .zoom(let id): edit("줌 삭제") { $0.removeZoom(id: id) }
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
        edit("다듬기") { edge == .leading ? $0.setClipStart(id: id, t) : $0.setClipEnd(id: id, t) }
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        playhead = edge == .leading ? c.start : max(c.start, c.end - Project.frameDuration)
        if built.index(containing: playhead) != nil {
            player.seek(to: Composer.time(built.compositionTime(playhead)), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func dragZoom(_ id: UUID, edge: HorizontalEdge, to t: Double) {
        beginDrag()
        edit("줌 길이") { edge == .leading ? $0.setZoomStart(id: id, t) : $0.setZoomEnd(id: id, t) }
    }

    func endDrag(_ name: String) {
        guard let base = dragBase else { return }
        dragBase = nil
        guard project != base else { return }
        undo.registerChange(self, \.project, before: base, name: name)
        applyToPlayer(old: base)
    }

    private func projectChanged(old: Project) {
        scheduleSave()
        if case .clip(let id) = selection, !project.clips.contains(where: { $0.id == id }) { selection = .none }
        if case .zoom(let id) = selection, !project.zooms.contains(where: { $0.id == id }) { selection = .none }
        if dragBase == nil { applyToPlayer(old: old) }
    }

    private func applyToPlayer(old: Project) {
        func material(_ c: [ClipRange]) -> [[Double]] { c.keptRanges.map { [$0.start, $0.end] } }
        if material(project.clips) != material(built) { rebuild() }
        else if project.zooms != old.zooms || project.clips != built { refreshComposition() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        do { try project.save(to: dir.appendingPathComponent(Project.fileName)) }
        catch { NSLog("Loupecast: autosave failed: %@", describe(error)) }
    }

    // MARK: export

    func export() {
        if exportState.isRunning { return }
        exportState = .running(0)
        let project = project, video = videoURL, url = Exporter.defaultURL()
        Task {
            do {
                try await Exporter.export(project: project, videoURL: video, to: url) { p in
                    Task { @MainActor in
                        if self.exportState.isRunning { self.exportState = .running(p) }
                    }
                }
                exportState = .done(url)
            } catch {
                exportState = .failed(describe(error))
            }
        }
    }

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
            PlayerView(player: model.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)                // a click here must not take keyboard focus
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

struct ControlBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(model.isPlaying ? "일시정지 (스페이스)" : "재생 (스페이스)")
            .accessibilityLabel(model.isPlaying ? "일시정지" : "재생")

            Text("\(Text(timecode(model.position)))\(Text(" / \(timecode(model.total))").foregroundStyle(.secondary))")
                .font(.callout.monospacedDigit())
            let removed = model.project.duration - model.total
            if removed > 0.005 {
                Label {
                    Text("잘라냄 \(timecode(removed))")
                } icon: {
                    Image(systemName: "scissors").imageScale(.small)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("잘라낸 길이 (D 자르기, Delete 삭제, ⌘Z 되돌리기)")
            }

            Spacer(minLength: 12)

            if let seg = model.selectedZoom {
                Toggle("줌 사용", isOn: Binding(get: { seg.isEnabled },
                                              set: { on in model.edit(on ? "줌 켜기" : "줌 끄기") { $0.setZoomEnabled(id: seg.id, on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .focusable(false)
                Button(role: .destructive, action: model.deleteSelected) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("선택한 줌 삭제 (Delete)")
                    .accessibilityLabel("선택한 줌 삭제")
                Divider().frame(height: 18)
            }
            ExportStatus(model: model)
            Button(action: model.addZoom) { Label("줌 추가", systemImage: "plus.magnifyingglass") }
                .buttonStyle(.bordered)
                .focusable(false)
                .help("재생 위치에 2초 줌 추가")
            Button(action: model.export) { Label("내보내기", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .focusable(false)
                .disabled(model.exportState.isRunning || model.edit == nil)
        }
    }
}

extension ExportState {
    var isRunning: Bool { if case .running = self { true } else { false } }
}

struct ExportStatus: View {
    @Bindable var model: EditorModel
    var body: some View {
        switch model.exportState {
        case .idle:
            EmptyView()
        case .running(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 110)
                Text("\(Int(p * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
        case .done(let url):
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
                .focusable(false)
                .help(url.path)
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
                .accessibilityLabel("타임라인")

                ForEach(clips) { clip in
                    ClipHandles(selected: model.selection == .clip(clip.id), width: x(clip.end) - x(clip.start), height: H,
                                drag: { edge, px in model.dragClip(clip.id, edge: edge, to: t(px)) },
                                ended: { model.endDrag("다듬기") })
                        .offset(x: x(clip.start))
                }

                ZoomLane(model: model, x: x, t: t)
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
            .accessibilityLabel(edge == .leading ? "클립 시작 지점 조절" : "클립 끝 지점 조절")
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
    @GestureState private var dragging = false
    let x: (Double) -> CGFloat
    let t: (CGFloat) -> Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: TimelineView.radius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
                .contentShape(Rectangle())
                .onTapGesture { model.selection = .none }
            ForEach(model.project.zooms) { seg in
                capsule(seg)
                    .frame(width: max(8, x(seg.end) - x(seg.start)), height: Self.capsuleHeight)
                    .offset(x: x(seg.start))
            }
        }
        .onChange(of: dragging) { _, now in if !now { model.endDrag("줌 길이") } }
    }

    private func capsule(_ seg: ZoomSegment) -> some View {
        let isSelected = model.selection == .zoom(seg.id)
        let w = x(seg.end) - x(seg.start)
        let tint = seg.isEnabled ? Color.accentColor : Color.gray
        return Capsule()
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
            .overlay(alignment: .leading) { edge(seg.id, .leading) }
            .overlay(alignment: .trailing) { edge(seg.id, .trailing) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("줌")
            .accessibilityValue("\(timecode(seg.start))–\(timecode(seg.end))\(seg.isEnabled ? "" : ", 꺼짐")")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func edge(_ id: UUID, _ edge: HorizontalEdge) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .updating($dragging) { _, d, _ in d = true }
                .onChanged { model.dragZoom(id, edge: edge, to: t($0.location.x)) })
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
