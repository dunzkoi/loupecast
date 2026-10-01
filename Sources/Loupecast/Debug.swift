#if DEBUG
// Verification handles, compiled into debug builds only (build.sh ships -c release).
//   LOUPECAST_OPEN=<recording dir>    open that recording's editor at launch
//   LOUPECAST_APPEARANCE=dark|light   force appearance
//   LOUPECAST_SNAPSHOT=<png>          save the editor window (with the live preview frame) and quit
//   LOUPECAST_SEEK=<seconds>          playhead time for the snapshot
//   LOUPECAST_EXPORT=1|fake           run the editor's own export first (fake: just the done state)
//   LOUPECAST_PERMISSIONS=<png>       save the permission window and quit
//   LOUPECAST_STATUS=<png>            save the menu-bar button in its recording state, print the menu
//   LOUPECAST_SELFTEST=<cycles>       record per cycle (mic off, menu bar hidden on odd cycles) with two
//                                 CGEvent clicks; prints size/audio/click/strip checks, deletes them, quits
//   LOUPECAST_WINDOW_TEST=<dir>       stop-path openEditor, minimize, wait for a reopen, close, launcher
//   LOUPECAST_HOTKEY_PROBE=1          post a hot-key event to the main Carbon queue; logs the handler
//   LOUPECAST_SELECT=clip|zoom|none   selection for the snapshot (default zoom); LOUPECAST_SPLITS="3,6" splits,
//                                 LOUPECAST_DELETE=<clip index> removes one, before the snapshot
//   LOUPECAST_EXPORT_TO=<mp4>         export the snapshot's edit to that path first
//   LOUPECAST_EDITOR_TEST=<dir>       trim drag + button click + Space/D/Delete/⌘Z through the window's key
//                                 handler, off screen and without activating; logs each state change
import AVFoundation
import AVKit
import AppKit
import Carbon.HIToolbox
import LoupecastCore
import LoupecastRender
import SwiftUI

@MainActor
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment

    static func run(_ app: AppDelegate) {
        if let a = env["LOUPECAST_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        if let path = env["LOUPECAST_OPEN"] {
            let dir = URL(fileURLWithPath: path)
            guard let p = try? Project.load(from: dir.appendingPathComponent(Project.fileName)) else { print("LOUPECAST: cannot load \(path)"); exit(2) }
            if let out = env["LOUPECAST_SNAPSHOT"] {
                // off screen and never activated: the user's real clicks and keys must not land on it
                let editor = offscreenEditor(dir, p)
                Task { await snapshot(editor, to: URL(fileURLWithPath: out)); NSApp.terminate(nil) }
            } else {
                app.openEditor(dir: dir, project: p)
            }
        }
        if let path = env["LOUPECAST_EDITOR_TEST"] { Task { await editorTest(URL(fileURLWithPath: path)) } }
        if let out = env["LOUPECAST_PERMISSIONS"] {
            app.showPermissions(needsMic: UserDefaults.standard.bool(forKey: AppDelegate.micKey))
            let w = NSApp.windows.first { $0.title == "Loupecast 권한" }
            w?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                if let v = w?.contentView?.superview {
                    v.display()
                    save(v, to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
        }
        if let out = env["LOUPECAST_STATUS"] {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let reason = env["LOUPECAST_HOTKEY_FAIL"] { HotKey.debugFail(reason) }
                let idle = app.debugMenuTitles()
                let (button, menu) = app.debugRecordingState(elapsed: 83)
                try? await Task.sleep(for: .seconds(0.5))
                if let button { save(button, to: URL(fileURLWithPath: out)) }
                print("LOUPECAST: idle menu \(idle)")
                print("LOUPECAST: recording menu \(app.debugMenuTitles()) items=\(menu?.items.count ?? 0) button=\(button.flatMap { ($0 as? NSButton)?.title } ?? "")")
                NSApp.terminate(nil)
            }
        }
        if let n = env["LOUPECAST_SELFTEST"].flatMap(Int.init) { Task { await selfTest(app, cycles: n) } }
        if let path = env["LOUPECAST_WINDOW_TEST"] { Task { await windowTest(app, dir: URL(fileURLWithPath: path)) } }
        if env["LOUPECAST_HOTKEY_PROBE"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                print("LOUPECAST: posting hot-key event to the main Carbon queue: \(HotKey.debugPostPressed())")
                try? await Task.sleep(for: .seconds(1.5))
                NSApp.terminate(nil)
            }
        }
    }

    /// Editor window drawn as the key window without activating Loupecast (AppKit asks isKeyWindow).
    static func offscreenEditor(_ dir: URL, _ p: Project) -> EditorController {
        let editor = EditorController(dir: dir, project: p)
        (editor.window as? LoupecastWindow)?.debugKey = true
        editor.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        editor.window.orderFront(nil)
        return editor
    }

    static func snapshot(_ editor: EditorController, to url: URL) async {
        let m = editor.model
        while m.edit == nil || m.thumbnails.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        for t in (env["LOUPECAST_SPLITS"] ?? "").split(separator: ",").compactMap({ Double($0) }) { m.seek(t); m.split() }
        if let i = env["LOUPECAST_DELETE"].flatMap(Int.init), m.project.clips.indices.contains(i) {
            m.selection = .clip(m.project.clips[i].id); m.deleteSelected()
        }
        switch env["LOUPECAST_SELECT"] ?? "zoom" {
        case "clip": m.selection = m.project.clips.first.map { .clip($0.id) } ?? .none
        case "zoom": m.selection = m.project.zooms.first.map { .zoom($0.id) } ?? .none
        default: m.selection = .none
        }
        if let out = env["LOUPECAST_EXPORT_TO"] {          // export the edit to a scratch path (never ~/Movies)
            do { try await Exporter.export(project: m.project, videoURL: m.videoURL, to: URL(fileURLWithPath: out)); print("LOUPECAST: exported \(out)") }
            catch { print("LOUPECAST: export failed \(describe(error))") }
        }
        if env["LOUPECAST_EXPORT"] == "fake" { m.exportState = .done(URL(fileURLWithPath: "/tmp/Loupecast.mp4")) }
        if env["LOUPECAST_EXPORT"] == "1" {
            m.export()
            while m.exportState.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            print("LOUPECAST: export state \(m.exportState)")
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        m.player.currentItem?.add(output)
        m.seek(env["LOUPECAST_SEEK"].flatMap(Double.init) ?? m.project.trimIn)
        try? await Task.sleep(for: .seconds(2.5))   // the rebuilt item after splits/deletes
        var pb: CVPixelBuffer?
        let time = m.player.currentItem?.currentTime() ?? .zero
        for _ in 0..<65 where pb == nil {   // a cold 6K HEVC seek can take a few seconds
            pb = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            if pb == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        state("snapshot", editor.window)
        guard let view = editor.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let pv = find(AVPlayerView.self, in: view), let pb,
           let cg = CIContext().createCGImage(CIImage(cvPixelBuffer: pb), from: CIImage(cvPixelBuffer: pb).extent) {
            var r = pv.convert(pv.bounds, to: view)
            if view.isFlipped { r.origin.y = view.bounds.height - r.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).addClip()   // the preview's clipShape
            NSGraphicsContext.current?.cgContext.draw(cg, in: r)
            NSGraphicsContext.restoreGraphicsState()
            print("LOUPECAST: preview frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) at \(time.seconds), camera \(CameraPath(project: m.project).camera(at: m.playhead))")
        } else {
            print("LOUPECAST: no preview frame")
        }
        write(rep, to: url)
    }

    /// Run as a real bundle via `open -g` (another app frontmost): the stop path's openEditor, then
    /// minimize → the shell sends a reopen (`open` = Dock click) → close → reopen with no editor.
    static func windowTest(_ app: AppDelegate, dir: URL) async {
        try? await Task.sleep(for: .seconds(2))
        state("before", nil)
        guard let p = try? Project.load(from: dir.appendingPathComponent(Project.fileName)) else { exit(2) }
        app.openEditor(dir: dir, project: p)                 // exactly what stop() calls
        let editor = app.openEditors[0]
        try? await Task.sleep(for: .seconds(0.4))
        state("after openEditor", editor.window)
        editor.window.miniaturize(nil)
        try? await Task.sleep(for: .seconds(1.5))
        state("minimized", editor.window)
        print("LOUPECAST: READY_FOR_REOPEN"); fflush(stdout)
        for _ in 0..<100 where editor.window.isMiniaturized { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1.5))
        state("after reopen", editor.window)
        if let out = env["LOUPECAST_SNAPSHOT"] { await snapshot(editor, to: URL(fileURLWithPath: out)) }   // key window look
        editor.window.close()
        try? await Task.sleep(for: .seconds(1))
        state("editor closed", nil)
        app.debugReopen()
        try? await Task.sleep(for: .seconds(1.5))
        let launcher = NSApp.windows.first { $0.title == "Loupecast" && $0.isVisible }
        state("reopen without editor → launcher=\(launcher != nil)", launcher)
        if let launcher, let out = env["LOUPECAST_LAUNCHER_SNAPSHOT"], let v = launcher.contentView { save(v, to: URL(fileURLWithPath: out)) }
        launcher?.close()
        try? await Task.sleep(for: .seconds(0.5))
        state("launcher closed", nil)
        NSApp.terminate(nil)
    }

    // MARK: editor key-handling test

    /// Window-level key handler evidence (only while LOUPECAST_EDITOR_TEST runs).
    static func keyLog(_ e: NSEvent, _ m: EditorModel) {
        guard env["LOUPECAST_EDITOR_TEST"] != nil else { return }
        print("LOUPECAST:   key handler got keyCode \(e.keyCode) (rate \(m.player.rate), position \(timecode(m.position)) / \(timecode(m.total)))")
        fflush(stdout)
    }

    /// REVISION 3 editor test. Off screen and never activated (the window reports itself key so AppKit
    /// dispatches clicks as in a focused window); keys arrive through the window server via
    /// CGEvent.postToPid(own pid), mouse events through NSApp's queue. Nothing is posted globally.
    static func editorTest(_ dir: URL) async {
        guard let p = try? Project.load(from: dir.appendingPathComponent(Project.fileName)) else { exit(2) }
        let editor = offscreenEditor(dir, p)
        let w = editor.window, m = editor.model, content = w.contentView!
        var waited = 0
        while m.edit == nil || m.thumbnails.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
            if waited == 100 { print("LOUPECAST: not loaded after 10 s: edit=\(m.edit != nil) thumbnails=\(m.thumbnails.count) \(m.exportState)"); fflush(stdout); exit(3) }
        }
        try? await Task.sleep(for: .seconds(0.8))
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { print("LOUPECAST: \(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures.append(what) } }
        func state(_ label: String) {
            print("LOUPECAST: [\(label)] playing=\(m.isPlaying) rate=\(m.player.rate) position=\(timecode(m.position)) total=\(timecode(m.total)) "
                  + "clips=\(m.project.clips.map { String(format: "%.2f…%.2f", $0.start, $0.end) }) zooms=\(m.project.zooms.count) "
                  + "firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") active=\(NSApp.isActive)")
            fflush(stdout)
        }
        func key(_ code: Int, _ flags: CGEventFlags = []) async {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
                e?.flags = flags
                e?.postToPid(getpid())
            }
            try? await Task.sleep(for: .seconds(0.5))
        }
        // What NSWindow.sendEvent does for the key window: hit-test, hand first responder to the hit view
        // if it takes it, then deliver. (Real dispatch needs Loupecast active, which would steal the user's focus.)
        var target: NSView = content
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                       pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown:
                target = content.hitTest(content.superview!.convert(p, from: nil)) ?? content
                if target.acceptsFirstResponder { w.makeFirstResponder(target) }
                target.mouseDown(with: e)
            case .leftMouseDragged: target.mouseDragged(with: e)
            default: target.mouseUp(with: e)
            }
        }
        /// A control's mouseDown runs its own tracking loop, which reads the mouse-up from the queue.
        func click(_ p: NSPoint) {
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
            mouse(.leftMouseDown, p)
        }
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        // strip geometry in window coordinates (bottom-left origin): 16 pt padding, strip 56, gap 8, lane 28
        let b = content.bounds, pad = 16.0, stripW = b.width - 2 * pad, stripY = pad + 28 + 8 + 28
        func xFor(_ t: Double) -> Double { pad + t / m.project.duration * stripW }
        state("loaded")
        let takers = views(content).filter { $0.acceptsFirstResponder }.map { "\(type(of: $0))" }
        print("LOUPECAST: views accepting first responder: \(takers)")

        // 1. programmatic trim-handle drag: the clip's out grip 240 pt to the left
        let out0 = m.project.trimOut
        let gx = xFor(out0) - ClipHandles.grip / 2
        mouse(.leftMouseDown, NSPoint(x: gx, y: stripY))
        for i in 1...12 { mouse(.leftMouseDragged, NSPoint(x: gx - Double(i) * 20, y: stripY)) }
        mouse(.leftMouseUp, NSPoint(x: gx - 240, y: stripY))
        try? await Task.sleep(for: .seconds(1.2))
        state("after trim-handle drag")
        check(m.project.trimOut < out0 - 1, "trim-out handle drag moved the clip end (\(timecode(out0)) → \(timecode(m.project.trimOut)))")

        // 2. a button click: 줌 추가 (borderedProminent 내보내기 is the last button, 줌 추가 the one before it)
        let zooms0 = m.project.zooms.count
        let buttons = views(content).filter { String(describing: type(of: $0)).contains("Button") }.sorted { $0.frame.minX < $1.frame.minX }
        if let add = buttons.dropLast().last {
            let r = add.convert(add.bounds, to: nil)
            click(NSPoint(x: r.midX, y: r.midY))
            try? await Task.sleep(for: .seconds(1.2))
        }
        state("after clicking 줌 추가")
        check(m.project.zooms.count == zooms0 + 1, "button click landed (zoom added)")
        check(!(w.firstResponder is NSButton), "the clicked button did not keep keyboard focus")

        // 3. Space toggles playback after the drag and the click
        let before = m.player.rate
        await key(kVK_Space); try? await Task.sleep(for: .seconds(0.7))
        state("Space #1")
        check(before == 0 && m.player.rate == 1 && m.player.timeControlStatus == .playing, "Space after drag + click starts playback (rate \(before) → \(m.player.rate), status \(m.player.timeControlStatus.rawValue))")
        let p1 = m.position
        try? await Task.sleep(for: .seconds(0.6))
        check(m.position > p1 + 0.3, "playhead advances while playing (\(timecode(p1)) → \(timecode(m.position)))")
        await key(kVK_Space)
        state("Space #2")
        check(m.player.rate == 0, "Space again pauses")

        // 4. at the end of the kept material, Space restarts from its start
        m.seek(m.project.trimOut)
        try? await Task.sleep(for: .seconds(0.5))
        state("seeked to the end")
        await key(kVK_Space); try? await Task.sleep(for: .seconds(0.5))
        state("Space at the end")
        check(m.player.rate == 1 && m.position < 1.2, "Space at the end restarts from the start (position \(timecode(m.position)))")
        await key(kVK_Space)

        // 4b. the zoom switch is a control too: click it, then the keys below still reach the window
        if let toggle = views(content).first(where: { $0 is NSSwitch }) {
            let r = toggle.convert(toggle.bounds, to: nil)
            click(NSPoint(x: r.midX, y: r.midY))
            try? await Task.sleep(for: .seconds(0.5))
            check(m.selectedZoom?.isEnabled == false && !(w.firstResponder is NSControl), "zoom switch click toggled it without taking focus")
            click(NSPoint(x: r.midX, y: r.midY))
            try? await Task.sleep(for: .seconds(0.5))
        }

        // ← → one frame, I / O set the clip edges at the playhead (each undone again)
        m.seek(m.project.trimIn + 3)
        try? await Task.sleep(for: .seconds(0.4))
        let f0 = m.position
        await key(kVK_RightArrow); await key(kVK_RightArrow); await key(kVK_LeftArrow)
        check(abs(m.position - f0 - Project.frameDuration) < 0.002, "→ → ← moved one frame net (\(String(format: "%.4f", f0)) → \(String(format: "%.4f", m.position)))")
        let clip = m.project.clips[0], at = m.playhead
        await key(kVK_ANSI_I)
        check(abs(m.project.clips[0].start - at) < 1e-9, "I set the clip start at the playhead")
        await key(kVK_ANSI_Z, .maskCommand)
        check(m.project.clips[0] == clip, "⌘Z undid I")
        await key(kVK_ANSI_O)
        check(abs(m.project.clips[0].end - at) < 1e-9, "O set the clip end at the playhead")
        await key(kVK_ANSI_Z, .maskCommand)
        check(m.project.clips[0] == clip, "⌘Z undid O")

        // 5. D at 2 s and 4 s, a click selects the middle part, Delete removes it
        let total0 = m.total, clips0 = m.project.clips.count, a = m.project.trimIn + 2, bEdge = m.project.trimIn + 4
        for t in [a, bEdge] {
            m.seek(t)
            try? await Task.sleep(for: .seconds(0.4))
            await key(kVK_ANSI_D)
        }
        state("D twice")
        check(m.project.clips.count == clips0 + 2 && abs(m.total - total0) < 1e-9, "D split the clip at the playhead twice without changing the length")
        guard m.project.clips.count == clips0 + 2 else { print("LOUPECAST: editor test FAILED: \(failures)"); NSApp.terminate(nil); return }
        let middle = m.project.clips[1]
        let mx = xFor((middle.start + middle.end) / 2)
        mouse(.leftMouseDown, NSPoint(x: mx, y: stripY)); mouse(.leftMouseUp, NSPoint(x: mx, y: stripY))
        try? await Task.sleep(for: .seconds(0.3))
        state("clicked the middle clip")
        check(m.selection == .clip(middle.id), "clicking the strip selected the clip under the click")
        await key(kVK_Delete); try? await Task.sleep(for: .seconds(0.5))
        state("Delete")
        check(abs((total0 - m.total) - middle.length) < 1e-9 && m.project.clips.count == clips0 + 1,
              "Delete reduced the total by the deleted clip's length (\(timecode(total0)) − \(timecode(middle.length)) = \(timecode(m.total)))")

        // 6. ⌘Z / ⇧⌘Z
        await key(kVK_ANSI_Z, .maskCommand)
        state("⌘Z")
        check(abs(m.total - total0) < 1e-9 && m.project.clips.count == clips0 + 2, "⌘Z restored the deleted clip")
        await key(kVK_ANSI_Z, [.maskCommand, .maskShift])
        state("⇧⌘Z")
        check(abs((total0 - m.total) - middle.length) < 1e-9, "⇧⌘Z removed it again")

        // 7. playback jumps the cut: the playhead never lands in the removed range, position runs on
        m.seek(a - 1)
        try? await Task.sleep(for: .seconds(0.5))
        await key(kVK_Space)
        var samples: [(r: Double, c: Double)] = []
        for _ in 0..<40 { samples.append((m.playhead, m.position)); try? await Task.sleep(for: .milliseconds(50)) }
        state("Space across the cut")
        await key(kVK_Space)
        let inHole = samples.filter { $0.r > a + 0.02 && $0.r < bEdge - 0.02 }
        let jumps = zip(samples.dropFirst(), samples).map { $0.c - $1.c }
        check(inHole.isEmpty && (samples.last?.r ?? 0) > bEdge + 0.2,
              "playback skipped the removed range (recording \(String(format: "%.2f", samples.first?.r ?? 0)) → \(String(format: "%.2f", samples.last?.r ?? 0)), samples inside the hole: \(inHole.count))")
        check((jumps.max() ?? 1) < 0.2, "composition position kept running across the cut (largest step \(String(format: "%.3f", jumps.max() ?? -1)) s)")

        print("LOUPECAST: editor test \(failures.isEmpty ? "PASSED" : "FAILED: \(failures)")"); fflush(stdout)
        w.close()
        NSApp.terminate(nil)
    }

    static func state(_ label: String, _ w: NSWindow?) {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowLayer as String] as? Int ?? 99) <= 3 }   // normal (0) and floating (3)
            .prefix(3).compactMap { w in (w[kCGWindowOwnerName as String] as? String).map { "\($0)/L\(w[kCGWindowLayer as String] as? Int ?? -1)" } }
        let policy = ["regular", "accessory", "prohibited"][NSApp.activationPolicy().rawValue]
        print("LOUPECAST: [\(label)] frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") active=\(NSApp.isActive) "
              + "key=\(w?.isKeyWindow ?? false) minimized=\(w?.isMiniaturized ?? false) policy=\(policy) front-to-back=\(windows)")
        fflush(stdout)
    }

    static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        write(rep, to: url)
    }

    /// Converted to sRGB: the cached bitmap is in the display's (wide) space, which viewers misread.
    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        let srgb = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        try? srgb.representation(using: .png, properties: [:])?.write(to: url)
        print("LOUPECAST: snapshot \(url.path)")
    }

    static func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        if let t = v as? T { return t }
        for s in v.subviews { if let t = find(type, in: s) { return t } }
        return nil
    }

    /// Real capture path. Needs Screen Recording for this bundle (and Accessibility to post the
    /// CGEvent clicks). Mic off; odd cycles hide the menu bar, even cycles keep it. Recordings made
    /// here are deleted at the end unless LOUPECAST_KEEP is set.
    static func selfTest(_ app: AppDelegate, cycles: Int) async {
        guard CGPreflightScreenCaptureAccess() else { print("LOUPECAST: screen recording permission missing"); exit(3) }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: AppDelegate.micKey)
        let micBefore = AVCaptureDevice.authorizationStatus(for: .audio).rawValue
        let primary = NSScreen.screens[0]                       // origin of the CG global space
        let W = primary.frame.width, H = primary.frame.height, scale = primary.backingScaleFactor
        let inset = DisplayBounds.menuBarInset(frameMaxY: primary.frame.maxY, visibleMaxY: primary.visibleFrame.maxY,
                                               safeAreaTop: primary.safeAreaInsets.top)
        print("LOUPECAST: primary display \(W)x\(H) pt @\(scale)x, menu-bar inset \(inset) pt, AX trusted \(AXIsProcessTrusted())")
        var frames: [Bool: CGImage] = [:], made: [URL] = []
        for cycle in 1...cycles {
            let hide = cycle % 2 == 1
            defaults.set(hide, forKey: AppDelegate.hideMenuBarKey)
            CGWarpMouseCursorPosition(CGPoint(x: W * 0.5, y: H * 0.5))   // records the display under the mouse
            let before = footprintMB()
            app.toggleRecording()
            try? await Task.sleep(for: .seconds(1))
            var clickHost: [Double] = []
            for (delay, fx) in [(2.0, 0.45), (3.0, 0.55)] {   // empty-ish area mid-screen
                try? await Task.sleep(for: .seconds(delay))
                let p = CGPoint(x: W * fx, y: H * 0.5)
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                clickHost.append(ProcessInfo.processInfo.systemUptime)
            }
            try? await Task.sleep(for: .seconds(4))
            app.toggleRecording()
            while app.openEditors.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            let e = app.openEditors[0]
            let p = e.model.project
            made.append(e.model.dir)
            let posted = clickHost.map { $0 - Recorder.lastSessionStartHost }
            let leads = p.zooms.map { $0.start + AutoZoom.leadIn }
            let timing = p.zooms.count == posted.count && zip(leads, posted).allSatisfy { abs($0 - $1) < 0.1 }
            // the known screen point y = H/2, measured against the captured rect
            let cropped = hide ? inset : 0
            let ny = (H * 0.5 - cropped) / (H - cropped)
            let path = CameraPath(project: p)
            let inZoom = p.clicks.map { c -> Bool in
                let cam = path.camera(at: c.t + 0.3)
                return abs(c.y - ny) < 0.005 && abs(c.x - cam.center.x) <= 0.5 / cam.scale && abs(c.y - cam.center.y) <= 0.5 / cam.scale
            }
            let mov = AVURLAsset(url: e.model.videoURL)
            let movAudio = (try? await mov.loadTracks(withMediaType: .audio).count) ?? -1
            let gen = AVAssetImageGenerator(asset: mov)
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            frames[hide] = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            var exportAudio = -1
            if cycle == 1 {
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("loupecast-selftest.mp4")
                do {
                    try await Exporter.export(project: p, videoURL: e.model.videoURL, to: out)
                    exportAudio = (try? await AVURLAsset(url: out).loadTracks(withMediaType: .audio).count) ?? -1
                } catch { print("LOUPECAST: export failed: \(describe(error))") }
                try? FileManager.default.removeItem(at: out)
            }
            print("LOUPECAST: cycle \(cycle) hideMenuBar=\(hide) pixels=\(p.pixelWidth)x\(p.pixelHeight) expected=\(Int((W * scale).rounded()) & ~1)x\(Int(((H - cropped) * scale).rounded()) & ~1) "
                  + "movAudioTracks=\(movAudio) exportAudioTracks=\(exportAudio) clicks=\(p.clicks.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }) expectedY=\(String(format: "%.3f", ny)) "
                  + "clickInsideZoom=\(inZoom) zoomStart+0.4≈click=\(timing) footprintMB \(before)→\(footprintMB())")
            e.window.close()
            try? await Task.sleep(for: .seconds(1))
        }
        if let a = frames[true], let b = frames[false] {
            let px = Int((inset * scale).rounded())
            print("LOUPECAST: top 40 px, hidden vs shown: same rows \(meanDiff(a, 0, b, 0)) (menu bar vs content), shifted by inset \(meanDiff(a, 0, b, px)) (same content)")
        }
        print("LOUPECAST: microphone authorization before \(micBefore) after \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        if env["LOUPECAST_KEEP"] == nil { made.forEach { try? FileManager.default.removeItem(at: $0) } }
        NSApp.terminate(nil)
    }

    /// Mean absolute RGB difference of 40-row strips starting at rows ya / yb (top-left origin).
    static func meanDiff(_ a: CGImage, _ ya: Int, _ b: CGImage, _ yb: Int) -> Double {
        func strip(_ img: CGImage, _ y: Int) -> [UInt8] {
            let w = min(a.width, b.width)
            var buf = [UInt8](repeating: 0, count: w * 40 * 4)
            guard let c = img.cropping(to: CGRect(x: 0, y: y, width: w, height: 40)),
                  let ctx = CGContext(data: &buf, width: w, height: 40, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return buf }
            ctx.draw(c, in: CGRect(x: 0, y: 0, width: w, height: 40))
            return buf
        }
        let sa = strip(a, ya), sb = strip(b, yb)
        var sum = 0.0
        for i in stride(from: 0, to: sa.count, by: 4) { for k in 0..<3 { sum += abs(Double(sa[i + k]) - Double(sb[i + k])) } }
        return sum / Double(sa.count / 4 * 3)
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
#endif
