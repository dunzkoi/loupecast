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
    static let soundsKey = "playSounds"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var recorder: Recorder?
    private var startedAt: TimeInterval?
    private var ticker: Timer?
    private var busy = false
    private var editors: [URL: EditorController] = [:]
    private var permissionWindow: NSWindow?
    private var launcher: NSWindow?
    private var isIdle: Bool { recorder == nil && editors.isEmpty && !busy }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.micKey: false, Self.systemAudioKey: true, Self.hideMenuBarKey: true, Self.soundsKey: true])
        NSApp.mainMenu = Self.mainMenu()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
        HotKey.register { [weak self] in self?.toggleRecording() }
        Updater.start { [weak self] in self?.isIdle ?? false }
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

        let rec = item(recording ? "녹화 중지" : "녹화 시작", #selector(toggleRecording))
        rec.keyEquivalent = "2"
        rec.keyEquivalentModifierMask = [.command, .shift]
        rec.isEnabled = !busy
        menu.addItem(rec)
        if let reason = HotKey.failure {
            let line = NSMenuItem(title: "단축키 사용 불가: \(HotKey.label)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.toolTip = reason
            menu.addItem(line)
        }
        menu.addItem(.separator())

        for (title, key) in [("마이크 녹음", Self.micKey), ("컴퓨터 소리 녹음", Self.systemAudioKey), ("영상 속 메뉴 막대 숨기기", Self.hideMenuBarKey), ("시작·종료 효과음", Self.soundsKey)] {
            let toggle = item(title, #selector(toggleSetting(_:)))
            toggle.representedObject = key
            toggle.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            toggle.isEnabled = !recording && !busy
            menu.addItem(toggle)
        }
        menu.addItem(.separator())

        for editor in editors.values.sorted(by: { $0.model.project.name < $1.model.project.name }) {
            let e = item("편집: \(editor.model.project.name)", #selector(showEditor(_:)))
            e.representedObject = editor.model.dir
            menu.addItem(e)
        }
        let recent = NSMenuItem(title: "최근 녹화", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let items = Library.recent(5)
        if items.isEmpty {
            let none = NSMenuItem(title: "녹화 없음", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for (dir, project) in items {
            let i = item(project.name, #selector(openRecent(_:)))
            i.representedObject = dir
            sub.addItem(i)
            let del = item("휴지통으로: \(project.name)", #selector(trashRecent(_:)))   // shown while ⌥ is held
            del.representedObject = dir
            del.keyEquivalentModifierMask = .option
            del.isAlternate = true
            del.isEnabled = editors[dir] == nil
            sub.addItem(del)
        }
        sub.addItem(.separator())
        let hint = NSMenuItem(title: "⌥를 누르면 하나씩 지울 수 있습니다", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        sub.addItem(hint)
        let folder = item("녹화 원본 폴더 열기", #selector(openLink(_:)))
        folder.representedObject = Recorder.recordingsDir
        sub.addItem(folder)
        let all = item("모두 휴지통으로 보내기", #selector(trashAllRecent))
        all.isEnabled = !recording && !busy && !items.isEmpty
        sub.addItem(all)
        recent.submenu = sub
        menu.addItem(recent)
        let saved = item("저장 폴더 열기", #selector(openLink(_:)))
        saved.representedObject = Exporter.defaultURL().deletingLastPathComponent()
        menu.addItem(saved)
        menu.addItem(.separator())
        if let tag = Updater.available {
            let title = !Updater.canInstall ? "\(tag) 다운로드 페이지 열기"
                : isIdle ? "\(tag) 설치 후 다시 시작" : "\(tag) 업데이트: 녹화·편집 창을 닫으면 설치"
            let u = item(title, #selector(installUpdate))
            u.isEnabled = isIdle || !Updater.canInstall
            menu.addItem(u)
            menu.addItem(.separator())
        }
        let version = NSMenuItem(title: "Loupecast \(Updater.current)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("업데이트 확인…", #selector(checkForUpdates)))
        let github = item("GitHub", #selector(openLink(_:)))
        github.representedObject = URL(string: "https://github.com/\(Updater.repo)")!
        menu.addItem(github)
        let sponsor = item("후원하기…", #selector(openLink(_:)))
        sponsor.representedObject = URL(string: "https://github.com/sponsors/dunzkoi")!
        menu.addItem(sponsor)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
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
        do { openEditor(dir: dir, project: try Project.load(from: dir.appendingPathComponent(Project.fileName))) }
        catch { alert("녹화를 열지 못했습니다", error) }
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
        do { try FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
        catch { alert("녹화를 지우지 못했습니다", error) }
    }

    /// Every finished recording not open in an editor; the one being recorded has no project file yet.
    @objc private func trashAllRecent() {
        guard recorder == nil else { return }
        do { for (dir, _) in Library.recent(.max) where editors[dir] == nil { try FileManager.default.trashItem(at: dir, resultingItemURL: nil) } }
        catch { alert("녹화를 지우지 못했습니다", error) }
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

    private func start() async {
        let defaults = UserDefaults.standard
        let mic = defaults.bool(forKey: Self.micKey)
        var prompted = false   // macOS showed its own prompt; our window on top of it would be a duplicate
        if mic, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let screenOK = CGPreflightScreenCaptureAccess()
        let micOK = !mic || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard screenOK, micOK else {
            if !screenOK {
                let reset = await Self.resetStaleScreenGrantOnce()
                // the system prompt appears only while the app has no record yet: first request, or right after a reset
                prompted = reset || !defaults.bool(forKey: Self.screenRequestedKey)
                defaults.set(true, forKey: Self.screenRequestedKey)
                CGRequestScreenCaptureAccess()   // registers Loupecast in the list
            }
            if !prompted { showPermissions(needsMic: mic) }
            return
        }
        await Self.chime("start", wait: true)   // Resources/start.wav (NSSound(named:) checks the bundle first)
        do {
            let r = try await Recorder.start(microphone: mic, systemAudio: defaults.bool(forKey: Self.systemAudioKey), hideMenuBar: defaults.bool(forKey: Self.hideMenuBarKey))
            r.onStreamError = { [weak self] error in self?.streamFailed(error) }
            recorder = r
            startedAt = ProcessInfo.processInfo.systemUptime
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItem() }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
            updateStatusItem()
        } catch {
            alert("녹화를 시작하지 못했습니다", error)
        }
    }

    private func stop(_ r: Recorder) async {
        recorder = nil
        startedAt = nil
        ticker?.invalidate()
        ticker = nil
        updateStatusItem()
        do {
            let project = try await r.stop()
            await Self.chime("stop", wait: false)
            openEditor(dir: r.dir, project: project)
        }
        catch { alert("녹화를 저장하지 못했습니다", error) }
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
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "녹화 중")?
                .withSymbolConfiguration(config)
            let s = Int(ProcessInfo.processInfo.systemUptime - startedAt)
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
    func debugRecordingState(elapsed: TimeInterval) -> (NSView?, NSMenu?) {
        startedAt = ProcessInfo.processInfo.systemUptime - elapsed
        updateStatusItem()
        if let menu = statusItem.menu { menuNeedsUpdate(menu) }
        return (statusItem.button, statusItem.menu)
    }

    func debugReopen() { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }
    #endif

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

    func showPermissions(needsMic: Bool) {
        permissionWindow?.close()
        let w = LoupecastWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Loupecast 권한"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PermissionView(needsMic: needsMic) { [weak w] in w?.close() })
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
        app.submenu?.addItem(withTitle: "Loupecast 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
                Label("녹화 시작", systemImage: "record.circle").frame(minWidth: 128)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text(HotKey.failure == nil ? "메뉴 막대 아이콘이나 \(HotKey.label)로도 시작합니다." : "메뉴 막대 아이콘에서도 시작합니다.")
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
    let close: () -> Void
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("녹화하려면 권한이 필요합니다").font(.title3.weight(.semibold))
                    Text("아래 항목을 시스템 설정에서 켜 주세요.").foregroundStyle(.secondary)
                }
            }
            PermissionRow(granted: screen, title: "화면 및 시스템 오디오 녹음",
                          detail: "시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음에서 Loupecast를 켭니다.",
                          pane: "Privacy_ScreenCapture")
            if needsMic {
                PermissionRow(granted: mic, title: "마이크",
                              detail: "시스템 설정 › 개인정보 보호 및 보안 › 마이크에서 Loupecast를 켭니다.",
                              pane: "Privacy_Microphone")
            }
            Text("화면 녹화 권한은 켠 다음 Loupecast를 종료했다가 다시 열어야 적용됩니다. 켜져 있는데도 이 창이 계속 뜨면, 목록에서 Loupecast를 선택해 −로 지운 뒤 녹화를 다시 시작하세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(refresh) { _ in
            screen = CGPreflightScreenCaptureAccess()
            mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }
}

struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let pane: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityLabel(granted ? "허용됨" : "필요함")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("설정 열기") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Recordings on disk, newest first. Only the top `n` project files are decoded.
enum Library {
    static func recent(_ n: Int) -> [(URL, Project)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: Recorder.recordingsDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let dated = dirs.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.lazy
            .compactMap { d, _ in (try? Project.load(from: d.appendingPathComponent(Project.fileName))).map { (d, $0) } }
            .filter { d, p in FileManager.default.fileExists(atPath: d.appendingPathComponent(p.videoFile).path) }
            .prefix(n).map { $0 }
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
            failure = status == OSStatus(eventHotKeyExistsErr) ? "다른 앱이 이미 사용 중입니다." : "등록하지 못했습니다 (OSStatus \(status))."
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
