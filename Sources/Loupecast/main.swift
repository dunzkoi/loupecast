import AVFoundation
import AppKit
import Carbon.HIToolbox
import Combine
import LoupecastCore
import LoupecastRender
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    /// UserDefaults keys; both apply to the next recording.
    static let micKey = "recordMicrophone", systemAudioKey = "recordSystemAudio", hideMenuBarKey = "hideMenuBar"
    static let screenRequestedKey = "screenAccessRequested"
    static let soundsKey = "playSounds", cameraKey = "recordCamera"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var recorder: Recorder?
    private var startedAt: TimeInterval?
    /// While paused: when the pause began. The elapsed time leaves out every pause.
    private var pausedAt: TimeInterval?
    private var pausedTotal: TimeInterval = 0
    private var ticker: Timer?
    private var busy = false
    private var editors: [URL: EditorController] = [:]
    private var permissionWindow: NSWindow?
    private var launcher: NSWindow?
    /// Also waits for exports: one keeps writing after its editor closes.
    private var isIdle: Bool { recorder == nil && editors.isEmpty && !busy && EditorModel.exports.isEmpty }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.micKey: false, Self.systemAudioKey: true, Self.hideMenuBarKey: true, Self.soundsKey: true,
                                                  Self.cameraKey: false])
        NSApp.mainMenu = Self.mainMenu()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        Updater.finishRelaunch { HotKey.register { [weak self] in self?.toggleRecording() } }
        Updater.start { [weak self] in self?.isIdle ?? false }
        Task { await Library.recoverCrashed() }
        // the user went to another app instead of clicking the floating window: stop floating
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { for w in NSApp.windows where w is LoupecastWindow { w.level = .normal } }
        }
        #if DEBUG
        DebugHooks.run(self)
        #endif
    }

    /// Dock icon click: the frontmost editor comes back (un-minimized), or a small launcher opens.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        #if DEBUG
        print("LOUPECAST: applicationShouldHandleReopen (editors: \(editors.count))"); fflush(stdout)
        #endif
        let windows = editors.values.map(\.window)
        if let w = NSApp.orderedWindows.first(where: { windows.contains($0) }) ?? windows.first {
            w.bringToFront()
        } else {
            showLauncher()
        }
        return false
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false   // isEnabled below is the source of truth (greyed while recording)
        let recording = startedAt != nil

        let rec = item(recording ? String(localized: "Stop Recording") : String(localized: "Start Recording"), #selector(toggleRecording))
        rec.keyEquivalent = "2"
        rec.keyEquivalentModifierMask = [.command, .shift]
        rec.isEnabled = !busy
        menu.addItem(rec)
        if !recording {
            let area = item(String(localized: "Record Area…"), #selector(recordArea))
            area.isEnabled = !busy
            menu.addItem(area)
        }
        if recording {
            let pause = item(pausedAt == nil ? String(localized: "Pause Recording") : String(localized: "Resume Recording"), #selector(togglePause))
            pause.isEnabled = !busy
            menu.addItem(pause)
        }
        if let reason = HotKey.failure {
            let line = NSMenuItem(title: String(localized: "Shortcut unavailable: \(HotKey.label)"), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = reason
            menu.addItem(line)
        }
        menu.addItem(.separator())

        for (title, key) in [(String(localized: "Record Microphone"), Self.micKey), (String(localized: "Record Computer Audio"), Self.systemAudioKey),
                             (String(localized: "Record Camera"), Self.cameraKey),
                             (String(localized: "Hide Menu Bar in Video"), Self.hideMenuBarKey), (String(localized: "Start and Stop Sounds"), Self.soundsKey)] {
            let toggle = item(title, #selector(toggleSetting(_:)))
            toggle.representedObject = key
            toggle.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            toggle.isEnabled = !recording && !busy
            menu.addItem(toggle)
        }
        menu.addItem(.separator())

        for editor in editors.values.sorted(by: { $0.model.project.name < $1.model.project.name }) {
            let e = item(String(localized: "Edit: \(editor.model.project.name)"), #selector(showEditor(_:)))
            e.representedObject = editor.model.dir
            menu.addItem(e)
        }
        let recent = NSMenuItem(title: String(localized: "Recent Recordings"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let items = Library.recent(5)
        if items.isEmpty {
            let none = NSMenuItem(title: String(localized: "No Recordings"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for (dir, name) in items {
            let i = item(name, #selector(openRecent(_:)))
            i.representedObject = dir
            sub.addItem(i)
            let del = item(String(localized: "Move to Trash: \(name)"), #selector(trashRecent(_:)))   // shown while ⌥ is held
            del.representedObject = dir
            del.keyEquivalentModifierMask = .option
            del.isAlternate = true
            del.isEnabled = editors[dir] == nil
            sub.addItem(del)
        }
        sub.addItem(.separator())
        sub.addItem(item(String(localized: "Open Recording…"), #selector(openRecordingPanel)))   // older than the five above
        let hint = NSMenuItem(title: String(localized: "Hold ⌥ to delete one at a time"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        sub.addItem(hint)
        let bytes = Library.diskUsage()   // the originals pile up out of sight: ~4 MB/s
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let folder = item(bytes > 0 ? String(localized: "Open Recordings Folder (\(size))") : String(localized: "Open Recordings Folder"),
                          #selector(openLink(_:)))
        folder.representedObject = Recorder.recordingsDir
        sub.addItem(folder)
        let all = item(String(localized: "Move All to Trash"), #selector(trashAllRecent))
        all.isEnabled = !recording && !busy && !items.isEmpty
        sub.addItem(all)
        recent.submenu = sub
        menu.addItem(recent)
        let saved = item(String(localized: "Open Exports Folder"), #selector(openLink(_:)))
        saved.representedObject = EditorModel.exportDir
        menu.addItem(saved)
        menu.addItem(.separator())
        if let tag = Updater.available {
            let title = !Updater.canInstall ? String(localized: "Open the \(tag) Download Page")
                : isIdle ? String(localized: "Install \(tag) and Restart")
                : String(localized: "\(tag) update: installs once recording and exports finish and editors are closed")
            let u = item(title, #selector(installUpdate))
            u.isEnabled = isIdle || !Updater.canInstall
            menu.addItem(u)
            menu.addItem(.separator())
        }
        let version = NSMenuItem(title: Updater.justUpdated ? String(localized: "Loupecast \(Updater.current) · just updated") : "Loupecast \(Updater.current)",
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item(String(localized: "Check for Updates…"), #selector(checkForUpdates)))
        let github = item("GitHub", #selector(openLink(_:)))
        github.representedObject = URL(string: "https://github.com/\(Updater.repo)")!
        menu.addItem(github)
        let sponsor = item(String(localized: "Sponsor…"), #selector(openLink(_:)))
        sponsor.representedObject = URL(string: "https://github.com/sponsors/dunzkoi")!
        menu.addItem(sponsor)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    /// Picks a rect on the display under the mouse, then records only that. Without the permission it asks first.
    @objc private func recordArea() {
        guard !busy, recorder == nil else { return }
        guard CGPreflightScreenCaptureAccess() else { return toggleRecording() }
        busy = true
        Task {
            if let area = await AreaPicker.pick() {
                RecordingArea.last = area
                await start(area: area)
            }
            busy = false
        }
    }

    /// The paused stretch is cut from the recording when it stops (Recorder.setPaused, Project's `paused`).
    @objc private func togglePause() {
        guard let r = recorder, !busy else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let p = pausedAt { pausedTotal += now - p; pausedAt = nil } else { pausedAt = now }
        r.setPaused(pausedAt != nil)
        updateStatusItem()
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, recorder == nil else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc private func showEditor(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        editors[dir]?.show()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        openRecording(dir)
    }

    /// Any recording folder, starting in Recordings: the menu lists only the newest five.
    @objc private func openRecordingPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Recorder.recordingsDir
        panel.prompt = String(localized: "Open")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openRecording(url)
    }

    /// An editor already open on the folder comes to the front (matched by path: a panel URL and a listed one can
    /// differ in the trailing slash).
    func openRecording(_ url: URL) {
        let dir = editors.keys.first { $0.path == url.path } ?? url
        do {
            let project = try editors[dir]?.model.project ?? Project.load(from: dir.appendingPathComponent(Project.fileName))
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(project.videoFile).path) else {
                throw LoupecastError("The recording’s video file is missing.")
            }
            openEditor(dir: dir, project: project)
        } catch {
            alert(String(localized: "Couldn’t open the recording"), error)
        }
    }

    @objc private func installUpdate() { Updater.installFromMenu() }

    @objc private func checkForUpdates() { Updater.checkFromMenu() }

    /// A folder (created first: Recordings may not exist before the first recording) or a web page.
    @objc private func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if url.isFileURL { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        NSWorkspace.shared.open(url)
    }

    @objc private func trashRecent(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL, editors[dir] == nil else { return }
        do { try Library.trash(dir) }
        catch { alert(String(localized: "Couldn’t delete the recording"), error) }
    }

    /// Every finished recording not open in an editor; the one being recorded has no project file yet.
    @objc private func trashAllRecent() {
        guard recorder == nil else { return }
        do { for (dir, _) in Library.recent(.max) where editors[dir] == nil { try Library.trash(dir) } }
        catch { alert(String(localized: "Couldn’t delete the recording"), error) }
    }

    func openEditor(dir: URL, project: Project) {
        let editor = editors[dir] ?? {
            let e = EditorController(dir: dir, project: project)
            e.onClose = { [weak self] in
                self?.editors[dir] = nil
                self?.updateActivationPolicy()
                Updater.installIfIdle()
            }
            editors[dir] = e
            return e
        }()
        updateActivationPolicy()
        editor.show()
        launcher?.close()
    }

    var openEditors: [EditorController] { Array(editors.values) }

    /// Dock + ⌘Tab while a Loupecast window is open, menu bar only otherwise.
    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = editors.isEmpty && launcher == nil ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func showLauncher() {
        if launcher == nil {
            let w = LoupecastWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Loupecast"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: LauncherView { [weak self, weak w] in
                w?.close()
                self?.toggleRecording()
            })
            w.center()
            launcher = w
        }
        updateActivationPolicy()
        launcher?.bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === launcher else { return }
        launcher = nil
        updateActivationPolicy()
    }

    // MARK: recording

    @objc func toggleRecording() {
        guard !busy else { return }
        busy = true
        Task {
            if let r = recorder { await stop(r) } else { await start() }
            busy = false
        }
    }

    private func start(area: RecordingArea? = nil) async {
        let defaults = UserDefaults.standard
        let mic = defaults.bool(forKey: Self.micKey), camera = defaults.bool(forKey: Self.cameraKey)
        var prompted = false   // macOS showed its own prompt; our window on top of it would be a duplicate
        if mic, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if camera, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        let screenOK = CGPreflightScreenCaptureAccess()
        let micOK = !mic || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let cameraOK = !camera || AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard screenOK, micOK, cameraOK else {
            if !screenOK {
                let reset = await Self.resetStaleScreenGrantOnce()
                // the system prompt appears only while the app has no record yet: first request, or right after a reset
                prompted = reset || !defaults.bool(forKey: Self.screenRequestedKey)
                defaults.set(true, forKey: Self.screenRequestedKey)
                CGRequestScreenCaptureAccess()   // registers Loupecast in the list
            }
            if !prompted { showPermissions(needsMic: mic, needsCamera: camera) }
            return
        }
        await Self.chime("loupecast-start", wait: true)   // Resources/loupecast-start.wav (NSSound(named:) checks the bundle first)
        do {
            let r = try await Recorder.start(microphone: mic, systemAudio: defaults.bool(forKey: Self.systemAudioKey),
                                             hideMenuBar: defaults.bool(forKey: Self.hideMenuBarKey), area: area, camera: camera)
            r.onStreamError = { [weak self] error in self?.streamFailed(error) }
            recorder = r
            startedAt = ProcessInfo.processInfo.systemUptime
            pausedAt = nil
            pausedTotal = 0
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItem() }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
            updateStatusItem()
        } catch {
            alert(String(localized: "Couldn’t start recording"), error)
        }
    }

    /// `quitting`: the file and project.json are written, but no chime and no editor.
    private func stop(_ r: Recorder, quitting: Bool = false) async {
        recorder = nil
        startedAt = nil
        pausedAt = nil
        ticker?.invalidate()
        ticker = nil
        updateStatusItem()
        do {
            let project = try await r.stop()
            if quitting { return }
            await Self.chime("loupecast-stop", wait: false)
            openEditor(dir: r.dir, project: project)
        }
        catch { alert(String(localized: "Couldn’t save the recording"), error) }
    }

    /// Played outside the capture: the start sound finishes before the stream opens and the stop sound
    /// plays after it closes, so neither lands in a recording that captures system audio.
    static func chime(_ name: String, wait: Bool) async {
        guard UserDefaults.standard.bool(forKey: soundsKey), let s = NSSound(named: name) else { return }
        s.play()
        if wait { try? await Task.sleep(for: .seconds(s.duration)) }
    }

    private func streamFailed(_ error: Error) {
        guard let r = recorder else { return }
        NSLog("Loupecast: stream stopped: %@", describe(error))
        Task { await stop(r) }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if let startedAt {
            let paused = pausedAt != nil
            let config = NSImage.SymbolConfiguration(paletteColors: [paused ? .systemOrange : .systemRed])
            button.image = NSImage(systemSymbolName: paused ? "pause.circle" : "record.circle",
                                   accessibilityDescription: paused ? String(localized: "Recording paused") : String(localized: "Recording in progress"))?
                .withSymbolConfiguration(config)
            let s = Int((pausedAt ?? ProcessInfo.processInfo.systemUptime) - startedAt - pausedTotal)
            button.attributedTitle = NSAttributedString(string: String(format: " %02d:%02d", s / 60, s % 60), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
            button.imagePosition = .imageLeading
        } else {
            let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Loupecast")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    #if DEBUG
    func debugMenuTitles() -> [String] {
        let m = NSMenu()
        menuNeedsUpdate(m)
        return m.items.flatMap { item -> [String] in
            if item.isSeparatorItem { return ["────"] }
            let mods = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { item.keyEquivalentModifierMask.contains($0.0) }.map(\.1).joined()
            let key = item.keyEquivalent.isEmpty ? "" : " [\(mods)\(item.keyEquivalent.uppercased())]"
            let line = (item.state == .on ? "✓ " : "") + item.title + key + (item.isEnabled ? "" : " (disabled)")
            return [line] + (item.submenu?.items.map { "  └ " + $0.title + ($0.isEnabled ? "" : " (disabled)") } ?? [])
        }
    }

    /// Renders the recording state without recording; returns the status button and the menu.
    func debugRecordingState(elapsed: TimeInterval, paused: Bool = false) -> (NSView?, NSMenu?) {
        startedAt = ProcessInfo.processInfo.systemUptime - elapsed
        pausedAt = paused ? ProcessInfo.processInfo.systemUptime : nil
        updateStatusItem()
        if let menu = statusItem.menu { menuNeedsUpdate(menu) }
        return (statusItem.button, statusItem.menu)
    }

    func debugReopen() { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }
    var debugIsIdle: Bool { isIdle }
    #endif

    // MARK: quit

    /// Quit (menu, ⌘Q, logout) never loses work: a recording is finished and saved first (it shows up in
    /// 최근 녹화), and running exports are cancelled, partial files deleted, only when the user says so.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !EditorModel.exports.isEmpty, !confirmQuitDuringExport() { return .terminateCancel }
        guard recorder != nil || busy || !EditorModel.exports.isEmpty else { return .terminateNow }
        Task {
            while busy { try? await Task.sleep(for: .milliseconds(50)) }   // a start or stop already running
            busy = true                                    // from here on: no hot-key start, no update install
            let exports = Array(EditorModel.exports.values)
            exports.forEach { $0.cancel() }
            for e in exports { await e.value }
            if let r = recorder { await stop(r, quitting: true) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Open editors write their pending (debounced) edits.
    func applicationWillTerminate(_ notification: Notification) {
        editors.values.forEach { $0.model.close() }
    }

    private func confirmQuitDuringExport() -> Bool {
        #if DEBUG
        if let answer = DebugHooks.env["LOUPECAST_QUIT_ANSWER"] { return answer == "quit" }
        #endif
        let a = NSAlert()
        a.messageText = String(localized: "An export is in progress")
        a.informativeText = String(localized: "The file is complete only when the export finishes. Quitting now cancels the export and deletes the unfinished file.")
        a.addButton(withTitle: String(localized: "Cancel"))
        a.addButton(withTitle: String(localized: "Quit")).hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertSecondButtonReturn
    }

    // MARK: permissions + alerts

    /// Builds up to 0.3.0 were ad-hoc signed, so their Screen Recording grant is pinned to that build's cdhash.
    /// The switch in System Settings stays on but no longer matches, and toggling it doesn't refresh the pin.
    /// Dropping the record once lets the request above re-register it against the release certificate.
    /// Once only: after the user switches it on, preflight stays false until relaunch, and a second reset would undo it.
    static func resetStaleScreenGrantOnce() async -> Bool {
        let key = "screenGrantResetForReleaseCert"
        guard !UserDefaults.standard.bool(forKey: key), let id = Bundle.main.bundleIdentifier else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", id]
        // off the main thread: a hung tccutil must not freeze the menu
        let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            p.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
            do { try p.run() } catch { done.resume(returning: false) }
        }
        if ok { UserDefaults.standard.set(true, forKey: key) }   // a failed reset is retried next time
        return ok
    }

    func showPermissions(needsMic: Bool, needsCamera: Bool = false) {
        permissionWindow?.close()
        let w = LoupecastWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = String(localized: "Loupecast Permissions")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PermissionView(needsMic: needsMic, needsCamera: needsCamera) { [weak w] in w?.close() })
        w.center()
        permissionWindow = w
        w.bringToFront()
    }

    private func alert(_ title: String, _ error: Error) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = describe(error)
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Shown only while the app is .regular (an editor is open): quit lives in the app menu.
    static func mainMenu() -> NSMenu {
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: String(localized: "Quit Loupecast"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let main = NSMenu()
        main.addItem(app)
        return main
    }
}

/// Every Loupecast window. macOS refuses activation while the user is busy in another app (measured:
/// granted with Raycast frontmost, refused with KakaoTalk frontmost), and a refused app's window is
/// ordered just below the active app's. So bringToFront floats it until it first becomes key.
class LoupecastWindow: NSWindow {
    #if DEBUG
    /// Harness only: draw and dispatch as the key window without activating Loupecast.
    var debugKey = false
    override var isKeyWindow: Bool { debugKey || super.isKeyWindow }
    #endif
    override func becomeKey() {
        super.becomeKey()
        level = .normal
    }
}

extension NSWindow {
    /// Above every other app: activate, order front regardless, and float until the first key.
    func bringToFront() {
        if isMiniaturized { deminiaturize(nil) }
        if self is LoupecastWindow, !isKeyWindow { level = .floating }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

struct LauncherView: View {
    let start: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Button(action: start) {
                Label("Start Recording", systemImage: "record.circle").frame(minWidth: 128)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text(HotKey.failure == nil ? String(localized: "You can also start from the menu bar icon or \(HotKey.label).")
                                        : String(localized: "You can also start from the menu bar icon."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(minWidth: 320)
    }
}

struct PermissionView: View {
    let needsMic: Bool
    let needsCamera: Bool
    let close: () -> Void
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recording needs permission").font(.title3.weight(.semibold))
                    Text("Turn on the items below in System Settings.").foregroundStyle(.secondary)
                }
            }
            PermissionRow(granted: screen, title: "Screen & System Audio Recording",
                          detail: "In System Settings › Privacy & Security › Screen & System Audio Recording, turn on Loupecast.",
                          pane: "Privacy_ScreenCapture")
            if needsMic {
                PermissionRow(granted: mic, title: "Microphone",
                              detail: "In System Settings › Privacy & Security › Microphone, turn on Loupecast.",
                              pane: "Privacy_Microphone")
            }
            if needsCamera {
                PermissionRow(granted: camera, title: "Camera",
                              detail: "In System Settings › Privacy & Security › Camera, turn on Loupecast.",
                              pane: "Privacy_Camera")
            }
            Text("Screen recording takes effect after you quit and reopen Loupecast. If this window keeps appearing while it is on, select Loupecast in the list, remove it with −, and start recording again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(refresh) { _ in
            screen = CGPreflightScreenCaptureAccess()
            mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }
}

struct PermissionRow: View {
    let granted: Bool
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let pane: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityLabel(granted ? String(localized: "Allowed") : String(localized: "Needed"))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum Library {
    /// Recordings on disk, newest first, with their names. The menu asks on every open and an hour-long
    /// project.json takes hundreds of ms to decode, so a file is decoded again only when it changed.
    @MainActor static func recent(_ n: Int) -> [(dir: URL, name: String)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Recorder.recordingsDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let dated = dirs.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        var out: [(dir: URL, name: String)] = []
        for (dir, _) in dated.sorted(by: { $0.1 > $1.1 }) where out.count < n {
            let file = dir.appendingPathComponent(Project.fileName)
            guard let changed = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if names[file]?.changed != changed {
                guard let p = try? Project.load(from: file) else { continue }
                names[file] = (changed, p.name, p.videoFile)
            }
            guard let entry = names[file], FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry.videoFile).path) else { continue }
            out.append((dir, entry.name))
        }
        return out
    }
    @MainActor private static var names: [URL: (changed: Date, name: String, videoFile: String)] = [:]

    /// Bytes on disk under Recordings. Summed again only when Recordings or a recording folder in it changed
    /// (a recording starts, stops or is saved, or one is trashed), not on every menu open.
    @MainActor static func diskUsage() -> Int64 {
        let fm = FileManager.default, root = Recorder.recordingsDir
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let changed = ([root] + dirs).compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        if let usage, usage.changed == changed { return usage.bytes }
        let files = fm.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])?.allObjects as? [URL] ?? []
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        usage = (changed, bytes)
        return bytes
    }
    @MainActor private static var usage: (changed: Date?, bytes: Int64)?

    /// Folders a crash left behind: no project.json. A movie that plays (the recorder writes a fragment every
    /// 5 s) becomes a project without input events, so it shows up in 최근 녹화; anything else goes to the Trash.
    /// Folders written to in the last minute are skipped: another Loupecast may be recording into one.
    static func recoverCrashed() async {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: Recorder.recordingsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        where !fm.fileExists(atPath: dir.appendingPathComponent(Project.fileName).path) {
            let movie = dir.appendingPathComponent("recording.mov")
            let touched = [movie, dir].lazy.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.first
            guard (touched ?? .distantPast) < Date(timeIntervalSinceNow: -60) else { continue }
            do {
                if let p = await recovered(dir, movie: movie) { try p.save(to: dir.appendingPathComponent(Project.fileName)) }
                else { try trash(dir) }
                NSLog("Loupecast: crashed recording %@ %@", dir.lastPathComponent, fm.fileExists(atPath: dir.path) ? "recovered" : "trashed")
            } catch {
                NSLog("Loupecast: recovering %@ failed: %@", dir.lastPathComponent, describe(error))
            }
        }
    }

    private static func recovered(_ dir: URL, movie: URL) async -> Project? {
        guard let video = try? await AVURLAsset(url: movie).loadTracks(withMediaType: .video).first,
              let (range, size) = try? await video.load(.timeRange, .naturalSize), range.end.seconds > 0 else { return nil }
        let base = try? Project.load(from: dir.appendingPathComponent(Recorder.recoveryFile))
        return Project(name: String(localized: "\(base?.name ?? Recorder.name(Date())) (Recovered)"), duration: range.end.seconds,
                       pixelWidth: base?.pixelWidth ?? Int(size.width), pixelHeight: base?.pixelHeight ?? Int(size.height),
                       pointPixelScale: base?.pointPixelScale ?? 1, cursor: [], clicks: [])
    }

    /// A debug run on LOUPECAST_RECORDINGS_DIR moves to "<that dir>-trash" instead, so tests never fill the user's Trash.
    static func trash(_ url: URL) throws {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["LOUPECAST_RECORDINGS_DIR"] {
            let bin = URL(fileURLWithPath: dir + "-trash", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            return try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }
        #endif
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// ⌘⇧2 (next to the system ⌘⇧3/4/5 screenshot keys) via Carbon RegisterEventHotKey.
/// Handler and hot key live on the event dispatcher target: it sees a hot-key event before any
/// application-target handler can consume it, and the handler ignores other apps' signatures.
@MainActor
enum HotKey {
    static let label = "⌘⇧2"
    nonisolated static let signature = OSType(0x4C4F_5550)   // 'LOUP'
    /// Why the shortcut is unavailable, shown in the menu; nil once registered.
    private(set) static var failure: String?
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            #if DEBUG
            print("LOUPECAST: hot-key handler fired"); fflush(stdout)
            #endif
            MainActor.assumeIsolated { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        if status == noErr {
            status = RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: signature, id: 1),
                                         GetEventDispatcherTarget(), 0, &ref)
        }
        if status != noErr {
            failure = status == OSStatus(eventHotKeyExistsErr) ? String(localized: "Another app is already using it.")
                : String(localized: "Couldn’t register it (OSStatus \(String(status))).")
            NSLog("Loupecast: %@ hot key unavailable (%d)", label, status)
        }
        #if DEBUG
        print("LOUPECAST: hot key \(label) status \(status)")
        #endif
    }

    #if DEBUG
    /// What the WindowServer does on a key press: a kEventHotKeyPressed in the main queue.
    static func debugPostPressed() -> OSStatus {
        var e: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &e)
        var hid = EventHotKeyID(signature: signature, id: 1)
        SetEventParameter(e, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hid)
        var t: EventTargetRef? = GetEventDispatcherTarget()
        SetEventParameter(e, EventParamName(kEventParamPostTarget), EventParamType(typeEventTargetRef), MemoryLayout<EventTargetRef?>.size, &t)
        return PostEventToQueue(GetMainEventQueue(), e, EventPriority(kEventPriorityStandard))
    }

    static func debugFail(_ reason: String) { failure = reason }
    #endif
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
