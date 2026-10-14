#if DEBUG
// Verification handles, compiled into debug builds only (build.sh ships -c release).
//   LOUPECAST_RECORDINGS_DIR=<dir>    recordings folder instead of ~/Library/Application Support/Loupecast/Recordings;
//                                 trashing moves to "<dir>-trash". Set it for every hook: launch-time recovery runs too
//   LOUPECAST_OPEN=<recording dir>    open that recording's editor at launch
//   LOUPECAST_APPEARANCE=dark|light   force appearance
//   LOUPECAST_SNAPSHOT=<png>          save the editor window (with the live preview frame) and quit
//   LOUPECAST_SEEK=<seconds>          playhead time for the snapshot
//   LOUPECAST_EXPORT=1|4k|gif|fake    run the editor's own export first (4k: the MP4 4K export, gif: the GIF export) (fake: just the done state, then the 복사
//                                 button's copy: prints what NSPasteboard.general holds, then restores the clipboard)
//                    cancel|twice     cancel it at 20 %, or export from two editors of the recording at once
//   LOUPECAST_EXPORT_DIR=<dir>        where the editor exports (default ~/Movies)
//   LOUPECAST_SIZE_LIMIT_BYTES=<n>    the editor's MP4 exports aim at n bytes instead of the menu's size limit
//   LOUPECAST_EXPORT_COUNT=<n>        with fake: finish it as the n-th export ever (3 shows the GitHub star line once);
//                                 LOUPECAST_STAR_DISMISS=1 closes the line and finishes the n-th export again
//   LOUPECAST_PERMISSIONS=<png>       save the permission window and quit
//   LOUPECAST_UPDATE_CHECK=1          fetch the latest GitHub release once, print current/available, quit
//   LOUPECAST_STATUS=<png>            save the menu-bar button in its recording state, print the menu;
//                                 LOUPECAST_STATUS_PAUSED=1 shows the paused state instead
//   LOUPECAST_USAGE_TEST=1            print the recordings' size in the menu, trash the newest recording, print it again
//   LOUPECAST_SELFTEST=<cycles>       record per cycle (mic off, menu bar hidden on odd cycles) with two
//                                 CGEvent clicks; prints size/audio/click/strip checks, deletes them, quits
//   LOUPECAST_WINDOW_TEST=<dir>       stop-path openEditor, minimize, wait for a reopen, close, launcher
//   LOUPECAST_HOTKEY_PROBE=1          post a hot-key event to the main Carbon queue; logs the handler
//   LOUPECAST_SELECT=clip|zoom|none   selection for the snapshot (default zoom); LOUPECAST_SPLITS="3,6" splits,
//                                 LOUPECAST_DELETE=<clip index> removes one, before the snapshot
//   LOUPECAST_EXPORT_TO=<mp4>         export the snapshot's edit to that path first
//   LOUPECAST_ASPECT=9:16|1:1|16:9    pick that output aspect through the editor (one undo step) before the snapshot;
//                                 LOUPECAST_ASPECT_UNDO=1 undoes it again
//   LOUPECAST_MIC_VOLUME=<0…2>       move the microphone slider there (three steps, one undo step), print the preview's
//                                 audio mix; LOUPECAST_VOLUME_POPOVER=<png> clicks the speaker button (prints whether the
//                                 popover opened) and saves its controls drawn in a plain window
//   LOUPECAST_SPEED=2|4               play the first clip that fast through the editor (one undo step), print the preview's
//                                 length; LOUPECAST_SPEED_UNDO=1 undoes it again
//   LOUPECAST_CAMERA_CORNER=<corner>  move the webcam circle (topLeft, topRight, bottomLeft, bottomRight) through the
//                                 editor (one undo step) before the snapshot; LOUPECAST_CAMERA_HIDE=1 hides it
//   LOUPECAST_FILL=1                  turn on 화면 채우기 through the editor (one undo step) before the snapshot
//   LOUPECAST_STYLE=<preset>          pick that background (pastel, dark, light, graphite, blue, plain) through the editor
//                                 (one undo step) before the snapshot
//   LOUPECAST_ZOOM_SCALE=<scale>      set the first zoom's level through the editor (one undo step) before the snapshot;
//                                 LOUPECAST_ZOOM_SCALE_UNDO=1 undoes it again
//   LOUPECAST_RENAME=<name>           click the name button, type <name> into its field and press Return, before the
//                                 snapshot (and before LOUPECAST_EXPORT); LOUPECAST_RENAME_UNDO=1 undoes it again
//   LOUPECAST_SHORTCUTS=<png>         press ? through the window's key handler (prints whether the shortcuts popover
//                                 opened) and save the list drawn in a plain window
//   LOUPECAST_LOOK=<dir>              after the edits above, print the saved look defaults, a new project with them
//                                 applied, and the project in <dir> as it opens (its own look)
//   LOUPECAST_MENUS=1                 print the toolbar's pop-up menus (title, check mark, enabled) before the snapshot
//   LOUPECAST_SHOW_CLICKS=0|1         switch 클릭 표시 through the editor (one undo step) before the snapshot
//   LOUPECAST_BACKGROUND_IMAGE=<file> use that picture as the background through the editor (what Image… does after
//                                 the panel) before the snapshot; LOUPECAST_BACKGROUND_UNDO=1 undoes it, then closes the
//                                 editor and lists the background files left in the recording folder
//   LOUPECAST_MOTION_BLUR=0|1         switch 모션 블러 through the editor (one undo step) before the snapshot
//   LOUPECAST_QUIT_TEST=<dir>         export from that recording's editor, close the editor, then quit;
//                                 LOUPECAST_QUIT_ANSWER=cancel|quit answers the export alert,
//                                 LOUPECAST_QUIT_EDIT=<dir> splits a second recording right before quitting
//   LOUPECAST_PERF=<dir>              open that recording off screen, make three edits and print the longest main-thread
//                                 stall after each (debounced autosave included), the close time and two menu builds
//   LOUPECAST_OPEN_TEST=<dir>         open that recording the way 녹화 열기… does after the panel, twice (with and
//                                 without a trailing slash: one editor), print the menu and the editors, quit
//   LOUPECAST_AREA_PICKER=<png>       draw the area picker off screen (1512 × 982 pt, a 1280 × 720 area picked, the mouse
//                                 over a 700 × 500 window), save it, then drag a new area and press Enter / Esc on it,
//                                 then click the window and press Enter; prints what each returns
//   LOUPECAST_CURSOR_PROBE=<dir>      note three cursor shapes (arrow, I-beam, arrow again) into <dir>/cursors the way a
//                                 recording does, then the system's current one; print the overlay, quit
//   LOUPECAST_COUNTDOWN=<png>         run the start countdown off screen: save it at 2, press Esc (prints false), then let
//                                 it run out (prints true and how long it took); quit
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
        if let dir = env["LOUPECAST_EXPORT_DIR"] { EditorModel.exportDir = URL(fileURLWithPath: dir) }
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
        if let path = env["LOUPECAST_CURSOR_PROBE"] {
            let shapes = CursorShapes(dir: URL(fileURLWithPath: path))
            for c in [NSCursor.arrow, .iBeam, .arrow] { shapes.note(c) }
            shapes.note()
            let o = shapes.overlay(sessionStartHost: ProcessInfo.processInfo.systemUptime - 1)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: path + "/cursors")) ?? []).sorted()
            print("LOUPECAST: cursor probe images \(o.images.map { "\($0.file) \($0.width)x\($0.height) hot \($0.hotX),\($0.hotY)" }), "
                  + "shapes \(o.shapes.map(\.image)), files \(files)")
            exit(0)
        }
        if let out = env["LOUPECAST_COUNTDOWN"] {
            Task {
                let c = Countdown(), off = NSPoint(x: -20_000, y: -20_000)
                async let cancelled = c.run(at: off)
                try? await Task.sleep(for: .seconds(1.3))
                save(c.view, to: URL(fileURLWithPath: out))
                c.view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape))!)
                print("LOUPECAST: countdown after Esc ran out: \(await cancelled)")
                let start = ProcessInfo.processInfo.systemUptime
                let ranOut = await Countdown().run(at: off)
                print("LOUPECAST: countdown left alone ran out: \(ranOut) after \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - start)) s")
                exit(0)
            }
        }
        if let out = env["LOUPECAST_AREA_PICKER"] { Task { await areaPickerTest(to: URL(fileURLWithPath: out)) } }
        if let path = env["LOUPECAST_OPEN_TEST"] {
            Task {
                try? await Task.sleep(for: .seconds(1))
                print("LOUPECAST: menu \(app.debugMenuTitles())")
                app.openRecording(URL(fileURLWithPath: path, isDirectory: false))
                app.openRecording(URL(fileURLWithPath: path, isDirectory: true))
                print("LOUPECAST: editors \(app.openEditors.map { "\($0.model.project.name) @ \($0.model.dir.lastPathComponent)" })")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        }
        if let out = env["LOUPECAST_PERMISSIONS"] {
            app.showPermissions(needsMic: UserDefaults.standard.bool(forKey: AppDelegate.micKey),
                                needsCamera: UserDefaults.standard.bool(forKey: AppDelegate.cameraKey))
            let w = NSApp.windows.first { $0.title == String(localized: "Loupecast Permissions") }
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
        if env["LOUPECAST_UPDATE_CHECK"] != nil {          // one fetch against GitHub; prints what it found, quits
            Task {
                do { try await Updater.fetchLatest(); print("LOUPECAST: update current=\(Updater.current) available=\(Updater.available ?? "none")") }
                catch { print("LOUPECAST: update check failed \(error)") }
                exit(0)
            }
        }
        if let out = env["LOUPECAST_STATUS"] {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if let reason = env["LOUPECAST_HOTKEY_FAIL"] { HotKey.debugFail(reason) }
                let idle = app.debugMenuTitles()
                let (button, menu) = app.debugRecordingState(elapsed: 83, paused: env["LOUPECAST_STATUS_PAUSED"] != nil)
                try? await Task.sleep(for: .seconds(0.5))
                if let button { save(button, to: URL(fileURLWithPath: out)) }
                print("LOUPECAST: idle menu \(idle)")
                print("LOUPECAST: recording menu \(app.debugMenuTitles()) items=\(menu?.items.count ?? 0) button=\(button.flatMap { ($0 as? NSButton)?.title } ?? "")")
                NSApp.terminate(nil)
            }
        }
        if env["LOUPECAST_USAGE_TEST"] != nil {
            let line = { app.debugMenuTitles().first { $0.contains(String(localized: "Open Recordings Folder")) } ?? "none" }
            print("LOUPECAST: usage \(line())")
            print("LOUPECAST: usage again (cached) \(line())")
            if let newest = Library.recent(1).first { try? Library.trash(newest.dir); print("LOUPECAST: trashed \(newest.name)") }
            print("LOUPECAST: usage after trash \(line())")
            exit(0)
        }
        if let n = env["LOUPECAST_SELFTEST"].flatMap(Int.init) { Task { await selfTest(app, cycles: n) } }
        if let path = env["LOUPECAST_PERF"] { Task { await perfTest(app, dir: URL(fileURLWithPath: path)) } }
        if let path = env["LOUPECAST_QUIT_TEST"] { Task { await quitTest(app, dir: URL(fileURLWithPath: path)) } }
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
        if let a = env["LOUPECAST_ASPECT"].flatMap(AspectRatio.init(rawValue:)) {
            m.edit("Aspect Ratio") { $0.aspect = a }
            print("LOUPECAST: aspect \(m.project.aspect.rawValue), undo \(m.undo.undoActionName)")
            if env["LOUPECAST_ASPECT_UNDO"] != nil { m.undoEdit(); print("LOUPECAST: aspect after undo \(m.project.aspect.rawValue)") }
        }
        if let v = env["LOUPECAST_MIC_VOLUME"].flatMap(Double.init) {
            for step in [0.3, 0.6, 1.0] { m.changeVolume(\.micVolume, to: 1 + (v - 1) * step) }
            m.endVolumeChange()
            try? await Task.sleep(for: .seconds(0.3))
            let volumes = (m.player.currentItem?.audioMix?.inputParameters ?? []).map { p -> String in
                var a: Float = -1, b: Float = -1, r = CMTimeRange.zero
                _ = p.getVolumeRamp(for: CMTime(seconds: 1, preferredTimescale: 600), startVolume: &a, endVolume: &b, timeRange: &r)
                return "track \(p.trackID)\(m.edit?.micTracks.contains(p.trackID) == true ? " (mic)" : ""): \(a)"
            }
            print("LOUPECAST: mic volume \(m.project.micVolume), undo \(m.undo.undoActionName), preview mix \(volumes)")
            m.undoEdit()
            print("LOUPECAST: mic volume after one undo \(m.project.micVolume)")
        }
        if let out = env["LOUPECAST_VOLUME_POPOVER"] {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            // SwiftUI keeps the label off the NSView: the speaker button is the last button left of the background menu
            let all = views(editor.window.contentView!), x = { (v: NSView) in v.convert(v.bounds, to: nil).minX }
            let menuX = all.filter { String(describing: type(of: $0)).contains("PopupButton") }.map(x).min() ?? 0
            let button = all.compactMap { $0 as? NSButton }.filter { !String(describing: type(of: $0)).contains("Popup") && x($0) < menuX }.max { x($0) < x($1) }
            button?.performClick(nil)
            try? await Task.sleep(for: .seconds(1))
            print("LOUPECAST: volume popover open \(NSApp.windows.contains { String(describing: type(of: $0)).contains("Popover") && $0.isVisible })")
            // cacheDisplay drops the popover's vibrant text, so the same controls are drawn in a plain window
            let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: VolumeControls(model: m).background(Color(nsColor: .windowBackgroundColor)))
            w.setContentSize(w.contentView!.fittingSize)
            w.orderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            save(w.contentView!, to: URL(fileURLWithPath: out))
            w.close()
        }
        if let speed = env["LOUPECAST_SPEED"].flatMap(Double.init), let clip = m.project.clips.first {
            m.edit("Speed") { $0.setClipSpeed(id: clip.id, speed) }
            try? await Task.sleep(for: .seconds(0.5))
            print("LOUPECAST: speed \(m.project.clips[0].speed), total \(timecode(m.total)), preview item \(timecode(m.player.currentItem?.duration.seconds ?? -1)), undo \(m.undo.undoActionName)")
            if env["LOUPECAST_SPEED_UNDO"] != nil {
                m.undoEdit()
                try? await Task.sleep(for: .seconds(0.5))
                print("LOUPECAST: speed after undo \(m.project.clips[0].speed), preview item \(timecode(m.player.currentItem?.duration.seconds ?? -1))")
            }
        }
        if let corner = env["LOUPECAST_CAMERA_CORNER"].flatMap(CameraOverlay.Corner.init(rawValue:)) {
            m.edit("Camera Position") { $0.camera?.corner = corner }
            print("LOUPECAST: camera \(m.project.camera.map { "\($0.corner) visible \($0.isVisible)" } ?? "none"), undo \(m.undo.undoActionName)")
        }
        if env["LOUPECAST_CAMERA_HIDE"] != nil { m.edit("Hide Camera") { $0.camera?.isVisible = false } }
        if env["LOUPECAST_FILL"] != nil {
            m.edit("Fill Frame") { $0.fill = true }
            print("LOUPECAST: fill \(m.project.fill) (fills frame \(m.project.fillsFrame)), undo \(m.undo.undoActionName)")
        }
        if let on = env["LOUPECAST_SHOW_CLICKS"].map({ $0 == "1" }) {
            m.edit(on ? "Show Clicks" : "Hide Clicks") { $0.showClicks = on }
            print("LOUPECAST: show clicks \(m.project.showClicks), undo \(m.undo.undoActionName)")
        }
        if let path = env["LOUPECAST_BACKGROUND_IMAGE"] {
            m.useBackgroundImage(URL(fileURLWithPath: path))
            let files = { ((try? FileManager.default.contentsOfDirectory(atPath: m.dir.path)) ?? []).filter { $0.hasPrefix("background-") } }
            print("LOUPECAST: background image \(m.project.backgroundImage ?? "none") (style \(m.project.style.rawValue)), undo \(m.undo.undoActionName), files \(files())")
            if env["LOUPECAST_BACKGROUND_UNDO"] != nil {
                m.undoEdit()
                print("LOUPECAST: after undo \(m.project.backgroundImage ?? "none"), files \(files())")
                editor.window.close()
                print("LOUPECAST: after closing \(files())")
                NSApp.terminate(nil)
            }
        }
        if let on = env["LOUPECAST_MOTION_BLUR"].map({ $0 == "1" }) {
            m.edit(on ? "Turn Motion Blur On" : "Turn Motion Blur Off") { $0.motionBlur = on }
            print("LOUPECAST: motion blur \(m.project.motionBlur), undo \(m.undo.undoActionName)")
        }
        if let s = env["LOUPECAST_STYLE"].flatMap(StylePreset.init(rawValue:)) {
            m.edit("Background") { $0.style = s }
            print("LOUPECAST: style \(m.project.style.rawValue), undo \(m.undo.undoActionName)")
        }
        if let s = env["LOUPECAST_ZOOM_SCALE"].flatMap(Double.init), let z = m.project.zooms.first {
            m.setZoomScale(z.id, s)
            print("LOUPECAST: zoom scale \(m.project.zooms[0].scale), undo \(m.undo.undoActionName)")
            if env["LOUPECAST_ZOOM_SCALE_UNDO"] != nil { m.undoEdit(); print("LOUPECAST: zoom scale after undo \(m.project.zooms[0].scale)") }
        }
        if let name = env["LOUPECAST_RENAME"] {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            let x = { (v: NSView) in v.convert(v.bounds, to: nil).minX }
            let button = views(editor.window.contentView!).compactMap { $0 as? NSButton }.min { x($0) < x($1) }   // leftmost: the name
            button?.performClick(nil)
            try? await Task.sleep(for: .seconds(1))
            let pop = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
            if let pop, let field = views(pop.contentView!).compactMap({ $0 as? NSTextField }).first {
                // what typing does, without focus (the harness never activates Loupecast): change the text, press Return
                field.stringValue = name
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
                field.sendAction(field.action, to: field.target)
                try? await Task.sleep(for: .seconds(0.5))
            }
            print("LOUPECAST: rename popover \(pop != nil), name \(m.project.name) (renamed \(m.project.renamed)), window \(editor.window.title), "
                  + "undo \(m.undo.undoActionName), popover still open \(pop?.isVisible ?? false)")
            if env["LOUPECAST_RENAME_UNDO"] != nil { m.undoEdit(); print("LOUPECAST: name after undo \(m.project.name), window \(editor.window.title)") }
        }
        if let out = env["LOUPECAST_SHORTCUTS"] {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: editor.window.windowNumber,
                                     context: nil, characters: "?", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: UInt16(kVK_ANSI_Slash))!
            let consumed = editor.handle(e)
            try? await Task.sleep(for: .seconds(1))
            print("LOUPECAST: ? consumed \(consumed), shortcuts shown \(m.showsShortcuts), popover open \(NSApp.windows.contains { String(describing: type(of: $0)).contains("Popover") && $0.isVisible })")
            let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ShortcutList().background(Color(nsColor: .windowBackgroundColor)))
            w.setContentSize(w.contentView!.fittingSize)
            w.orderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            save(w.contentView!, to: URL(fileURLWithPath: out))
            w.close()
            m.showsShortcuts = false
        }
        if let path = env["LOUPECAST_LOOK"] {
            var fresh = Project(name: "new", duration: 5, pixelWidth: 1600, pixelHeight: 1000, pointPixelScale: 2, cursor: [], clicks: [])
            LookDefaults.saved?.apply(to: &fresh)                   // what Recorder.stop does
            let other = try? Project.load(from: URL(fileURLWithPath: path).appendingPathComponent(Project.fileName))
            print("LOUPECAST: look defaults \(LookDefaults.saved.map { "\($0.aspect.rawValue) \($0.style.rawValue) fill \($0.fill)" } ?? "none"), "
                  + "new project \(fresh.aspect.rawValue) \(fresh.style.rawValue) fill \(fresh.fill), "
                  + "reopened \(other.map { "\($0.aspect.rawValue) \($0.style.rawValue) fill \($0.fill)" } ?? "none")")
        }
        if env["LOUPECAST_MENUS"] != nil {
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            func lines(_ m: NSMenu, _ indent: String) -> [String] {
                m.delegate?.menuNeedsUpdate?(m)   // SwiftUI fills its menus only when they open
                m.update()
                return m.items.flatMap { i -> [String] in
                    [indent + (i.isSeparatorItem ? "────" : (i.state == .on ? "✓ " : "") + i.title + (i.isEnabled ? "" : " (disabled)"))]
                        + (i.submenu.map { lines($0, indent + "  ") } ?? [])
                }
            }
            for c in views(editor.window.contentView!).compactMap({ $0 as? NSSegmentedControl }) {   // the Export split button
                for i in 0..<c.segmentCount { if let menu = c.menu(forSegment: i) { print("LOUPECAST: menu export \(lines(menu, ""))") } }
            }
            for b in views(editor.window.contentView!).compactMap({ $0 as? NSPopUpButton ?? ($0 as? NSButton).flatMap { $0.menu == nil ? nil : $0 } }) {
                guard let menu = (b as? NSPopUpButton)?.menu ?? b.menu else { continue }
                if menu.items.isEmpty {   // SwiftUI fills a Menu only while it is open: open it, read it, close it
                    nonisolated(unsafe) let menu = menu, read = { lines(menu, "") }
                    nonisolated(unsafe) var seen: [String] = []
                    let t = Timer(timeInterval: 0.2, repeats: false) { _ in MainActor.assumeIsolated { seen = read(); menu.cancelTracking() } }
                    RunLoop.main.add(t, forMode: .common)
                    b.performClick(nil)
                    print("LOUPECAST: menu \(type(of: b)) \(seen)")
                } else {
                    print("LOUPECAST: menu \(type(of: b)) \(lines(menu, ""))")
                }
            }
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
        if env["LOUPECAST_EXPORT"] == "fake" {
            let url = URL(fileURLWithPath: "/tmp/Loupecast.mp4")
            if let n = env["LOUPECAST_EXPORT_COUNT"].flatMap(Int.init) {
                UserDefaults.standard.set(n - 1, forKey: EditorModel.exportCountKey)
                UserDefaults.standard.removeObject(forKey: EditorModel.starAskedKey)
                m.exportFinished(url)
                print("LOUPECAST: export #\(UserDefaults.standard.integer(forKey: EditorModel.exportCountKey)) asks for a star \(m.asksForStar)")
                if env["LOUPECAST_STAR_DISMISS"] != nil {   // closed once: even another third export doesn't ask again
                    m.dismissStar()
                    UserDefaults.standard.set(n - 1, forKey: EditorModel.exportCountKey)
                    m.exportFinished(url)
                    print("LOUPECAST: after closing it, export #\(n) again asks \(m.asksForStar)")
                }
            } else {
                m.exportState = .done(url)
            }
            let pb = NSPasteboard.general
            let saved = (pb.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
                return copy
            }
            ExportStatus.copy(url)
            let read = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            print("LOUPECAST: pasteboard after copy \(read.map(\.path)), same file \(read == [url])")
            pb.clearContents()
            pb.writeObjects(saved)
        }
        if let format = ["1": EditorModel.ExportFormat.mp4, "4k": .uhd, "gif": .gif][env["LOUPECAST_EXPORT"] ?? ""] {
            m.export(format)
            while m.exportState.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            print("LOUPECAST: export state \(m.exportState), size warning \(m.sizeWarning ?? "none")")
        }
        if env["LOUPECAST_EXPORT"] == "cancel" {
            m.export()
            while case .running(let p) = m.exportState, p < 0.2 { try? await Task.sleep(for: .milliseconds(20)) }
            print("LOUPECAST: cancelling at \(m.exportState), files \(exported())")
            m.cancelExport()
            while m.exportState.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            print("LOUPECAST: after cancel \(m.exportState), files \(exported())")
        }
        if env["LOUPECAST_EXPORT"] == "twice" {
            let other = offscreenEditor(m.dir, m.project)
            while other.model.edit == nil { try? await Task.sleep(for: .milliseconds(100)) }
            m.export(); other.model.export()
            while m.exportState.isRunning || other.model.exportState.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            print("LOUPECAST: two exports \(m.exportState) | \(other.model.exportState), files \(exported())")
            other.window.close()
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
            print("LOUPECAST: preview frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) at \(time.seconds), camera \(Composer.cameraPath(m.project).camera(at: m.playhead))")
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

    static func quitTest(_ app: AppDelegate, dir: URL) async {
        guard let p = try? Project.load(from: dir.appendingPathComponent(Project.fileName)) else { exit(2) }
        app.openEditor(dir: dir, project: p)
        let e = app.openEditors[0], m = e.model
        while m.edit == nil { try? await Task.sleep(for: .milliseconds(100)) }
        m.export()
        while case .running(let f) = m.exportState, f < 0.2 { try? await Task.sleep(for: .milliseconds(20)) }
        e.window.close()
        print("LOUPECAST: editor closed while exporting: idle=\(app.debugIsIdle) exports=\(EditorModel.exports.count) files \(exported())")
        if let path = env["LOUPECAST_QUIT_EDIT"], let q = try? Project.load(from: URL(fileURLWithPath: path).appendingPathComponent(Project.fileName)) {
            app.openEditor(dir: URL(fileURLWithPath: path), project: q)
            let m2 = app.openEditors.first { $0.model.dir.path == path }!.model
            while m2.edit == nil { try? await Task.sleep(for: .milliseconds(100)) }
            m2.seek(m2.project.trimIn + 1); m2.split()
            print("LOUPECAST: split right before quitting: \(m2.project.clips.count) clips")
        }
        fflush(stdout)
        Updater.quit()
        try? await Task.sleep(for: .seconds(5))   // a quit ends the process before this
        print("LOUPECAST: quit cancelled, still running: export \(m.exportState)")
        while m.exportState.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        print("LOUPECAST: export ended \(m.exportState) idle=\(app.debugIsIdle) files \(exported())")
        fflush(stdout)
        exit(0)
    }

    /// Longest gap between 1 ms main-thread timer fires: how long the main thread was blocked.
    @MainActor final class Stalls {
        var last = ProcessInfo.processInfo.systemUptime, worst = 0.0
        func tick() { let now = ProcessInfo.processInfo.systemUptime; worst = max(worst, now - last); last = now }
        func reset() { last = ProcessInfo.processInfo.systemUptime; worst = 0 }
    }

    static func perfTest(_ app: AppDelegate, dir: URL) async {
        func ms(_ s: Double) -> String { String(format: "%.1f ms", s * 1000) }
        let up = { ProcessInfo.processInfo.systemUptime }
        var t0 = up()
        guard let p = try? Project.load(from: dir.appendingPathComponent(Project.fileName)) else { exit(2) }
        print("LOUPECAST: perf load \(p.cursor.count) cursor samples, \(p.zooms.count) zooms in \(ms(up() - t0))")
        let editor = offscreenEditor(dir, p), m = editor.model
        while m.edit == nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1))
        let stalls = Stalls()
        let timer = Timer(timeInterval: 0.001, repeats: true) { _ in MainActor.assumeIsolated { stalls.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        let edits: [(String, () -> Void)] = [
            ("no edit (noise floor)", {}),
            ("split at 100 s", { m.seek(100); m.split() }),
            ("zoom off", { let z = m.project.zooms[5]; m.edit("Turn Zoom Off") { $0.setZoomEnabled(id: z.id, false) } }),
            ("add zoom", { m.seek(1000); m.addZoom() }),
        ]
        for (name, edit) in edits {
            stalls.reset()
            t0 = up()
            edit()
            let sync = up() - t0
            try? await Task.sleep(for: .seconds(1.5))   // past the 0.5 s autosave debounce
            print("LOUPECAST: perf \(name): edit \(ms(sync)), longest main-thread stall \(ms(stalls.worst))")
        }
        timer.invalidate()
        t0 = up()
        editor.window.close()
        print("LOUPECAST: perf close (waits for the last save) \(ms(up() - t0))")
        for i in 1...2 {
            t0 = up()
            let titles = app.debugMenuTitles()
            print("LOUPECAST: perf menu build #\(i) \(ms(up() - t0)), \(titles.filter { $0 == "  └ 1시간 합성" }.count) recent items")
        }
        fflush(stdout)
        exit(0)
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
        // without Accessibility, keys posted to the pid never arrive: queue the same key-down in NSApp's event queue instead
        // (still one event per key, so undo groups one action per key as it does for real typing)
        let trusted = AXIsProcessTrusted()
        print("LOUPECAST: Accessibility \(trusted ? "on: keys go through the window server" : "off: keys go through NSApp's event queue")")
        func key(_ code: Int, _ flags: CGEventFlags = []) async {
            if trusted {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
                    e?.flags = flags
                    e?.postToPid(getpid())
                }
            } else {
                var mods: NSEvent.ModifierFlags = []
                if flags.contains(.maskCommand) { mods.insert(.command) }
                if flags.contains(.maskShift) { mods.insert(.shift) }
                NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                 isARepeat: false, keyCode: UInt16(code))!, atStart: false)
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

        // 1b. a zoom capsule: a click selects it, dragging its right edge 60 pt lengthens it as one undo step
        if let z = m.project.zooms.first {
            let laneY = pad + TimelineView.laneHeight / 2
            mouse(.leftMouseDown, NSPoint(x: xFor((z.start + z.end) / 2), y: laneY)); mouse(.leftMouseUp, NSPoint(x: xFor((z.start + z.end) / 2), y: laneY))
            try? await Task.sleep(for: .seconds(0.3))
            check(m.selection == .zoom(z.id), "clicking a zoom capsule selected it")
            let ex = xFor(z.end) - 4
            mouse(.leftMouseDown, NSPoint(x: ex, y: laneY))
            for i in 1...6 { mouse(.leftMouseDragged, NSPoint(x: ex + Double(i) * 10, y: laneY)) }
            mouse(.leftMouseUp, NSPoint(x: ex + 60, y: laneY))
            try? await Task.sleep(for: .seconds(0.5))
            let end = m.project.zooms.first { $0.id == z.id }?.end ?? z.end
            check(end > z.end + 0.3, "dragging the zoom's right edge lengthened it (\(timecode(z.end)) → \(timecode(end)))")
            m.undoEdit()
            check(m.project.zooms.first { $0.id == z.id }?.end == z.end, "one undo restored the zoom length")

            // 1c. with the zoom selected, a click on the preview pins its focus there (one undo step)
            if let pv = find(AVPlayerView.self, in: content) {
                let r = pv.convert(pv.bounds, to: nil), f = CGPoint(x: 0.3, y: 0.4)
                let canvas = Composer.renderSize(m.project.aspect)
                let want = Composer.recordingPoint(canvas: CGPoint(x: f.x * canvas.width, y: f.y * canvas.height), project: m.project, at: m.playhead)
                let p = NSPoint(x: r.minX + f.x * r.width, y: r.maxY - f.y * r.height)
                mouse(.leftMouseDown, p); mouse(.leftMouseUp, p)
                try? await Task.sleep(for: .seconds(0.5))
                let seg = m.project.zooms.first { $0.id == z.id }
                check(seg?.followsCursor == false && want.map { abs($0.x - seg!.focus.x) < 1e-3 && abs($0.y - seg!.focus.y) < 1e-3 } == true,
                      "a preview click pinned the zoom's focus (\(z.focus) → \(seg?.focus ?? z.focus), expected \(want.map { "\($0)" } ?? "nil"))")
                m.undoEdit()
                check(m.project.zooms.first { $0.id == z.id } == z, "one undo restored the focus and the following")
            }
        }

        // 2. a button click: 줌 추가, the rightmost bordered SwiftUI button (내보내기 is a split menu, the keyboard button borderless)
        let zooms0 = m.project.zooms.count, ids0 = Set(m.project.zooms.map(\.id))
        UserDefaults.standard.set(2.5, forKey: EditorModel.zoomScaleKey)   // as if 250 % was the last level picked
        let buttons = views(content).filter { String(describing: type(of: $0)) == "SwiftUIAppKitButton" && ($0 as? NSButton)?.isBordered == true }
        if let add = buttons.max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) {
            let r = add.convert(add.bounds, to: nil)
            click(NSPoint(x: r.midX, y: r.midY))
            try? await Task.sleep(for: .seconds(1.2))
        }
        state("after clicking Add Zoom")
        check(m.project.zooms.count == zooms0 + 1, "button click landed (zoom added)")
        check(m.project.zooms.first { !ids0.contains($0.id) }?.scale == 2.5, "the added zoom uses the last zoom level picked (250 %)")
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

    static func areaPickerTest(to url: URL) async {
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1512, height: 982), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .darkGray                       // stands in for the desktop under the dimming
        let v = AreaPickerView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
        w.contentView = v
        w.orderFront(nil)
        v.selection = v.viewRect(Rect(x: 116, y: 131, width: 1280, height: 720))
        // a window under the mouse (top-left 200, 150, 700 × 500 pt): outlined in the snapshot
        v.display = DisplayBounds(x: 0, y: 0, width: 1512, height: 982)
        v.windows = [.init(bounds: Rect(x: 0, y: 0, width: 1512, height: 982), layer: 0, owner: v.owner),   // our overlay
                     .init(bounds: Rect(x: 200, y: 150, width: 700, height: 500), layer: 0, owner: 1)]
        v.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 400, y: 982 - 300), modifierFlags: [], timestamp: 0,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        print("LOUPECAST: hovered window \(v.hover.map { "\($0)" } ?? "none")")
        try? await Task.sleep(for: .seconds(0.3))
        save(v, to: url)
        var results: [String] = []
        v.done = { results.append($0.map { "\($0)" } ?? "cancelled") }
        func key(_ code: Int) {
            v.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!)
        }
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        key(kVK_Return)                                     // the preselected (last) area
        v.done = { results.append($0.map { "\($0)" } ?? "cancelled") }
        v.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 100, y: 900)))
        v.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 740.4, y: 540.2)))   // 640 × 360 pt, top-left (100, 82)
        key(kVK_Return)
        v.done = { results.append($0.map { "\($0)" } ?? "cancelled") }
        v.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 10, y: 10)))
        v.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 40, y: 40)))          // too small: Enter only beeps
        key(kVK_Return)
        key(kVK_Escape)
        v.done = { results.append($0.map { "\($0)" } ?? "cancelled") }   // a click on the window, no drag: its bounds
        v.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 400, y: 982 - 300)))
        v.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 400, y: 982 - 300)))
        key(kVK_Return)
        print("LOUPECAST: area picker results \(results)")
        let area = RecordingArea(displayID: 7, rect: Rect(x: 1, y: 2, width: 3, height: 4)), before = RecordingArea.last
        RecordingArea.last = area
        print("LOUPECAST: remembered area round trip \(RecordingArea.last == area)")
        RecordingArea.last = before
        w.close()
        NSApp.terminate(nil)
    }

    static func exported() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: EditorModel.exportDir.path)) ?? []).filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".gif") }.sorted()
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
