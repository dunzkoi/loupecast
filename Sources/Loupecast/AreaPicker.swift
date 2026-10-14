import AppKit
import Carbon.HIToolbox
import LoupecastCore

/// A rect picked on one display, in its local points (top-left origin); the last one is the next pick's default.
struct RecordingArea: Codable, Equatable {
    var displayID: CGDirectDisplayID
    var rect: Rect

    static var last: RecordingArea? {
        get { UserDefaults.standard.data(forKey: "recordingArea").flatMap { try? JSONDecoder().decode(RecordingArea.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "recordingArea") }
    }
}

/// Dims the display under the mouse: drag a rectangle, Enter (or a double-click in it) records it, Esc (or a
/// right-click) cancels. The last area on that display is preselected, so Enter alone repeats it.
@MainActor
enum AreaPicker {
    static func pick() async -> RecordingArea? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
        let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)
        let view = AreaPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        if let last = RecordingArea.last, last.displayID == id { view.selection = view.viewRect(last.rect) }
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        let rect = await withCheckedContinuation { cont in view.done = { cont.resume(returning: $0) } }
        window.orderOut(nil)
        return rect.map { RecordingArea(displayID: id, rect: $0) }
    }
}

/// Borderless windows can't become key on their own; the picker needs Enter and Esc.
final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AreaPickerView: NSView {
    static let minSide: CGFloat = 64
    /// View coordinates (bottom-left origin).
    var selection: NSRect? { didSet { needsDisplay = true } }
    var done: ((Rect?) -> Void)?
    private var anchor: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    func viewRect(_ r: Rect) -> NSRect { NSRect(x: r.x, y: bounds.height - r.y - r.height, width: r.width, height: r.height) }

    /// The selection in display-local whole points, top-left origin; nil while smaller than 64 × 64.
    var picked: Rect? {
        guard let s = selection?.integral, s.width >= Self.minSide, s.height >= Self.minSide else { return nil }
        return Rect(x: s.minX, y: bounds.height - s.maxY, width: s.width, height: s.height)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2, selection?.contains(p) == true, let r = picked { return finish(r) }
        anchor = p
    }

    override func mouseDragged(with e: NSEvent) {
        guard let a = anchor else { return }
        let p = convert(e.locationInWindow, from: nil)
        selection = NSRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y)).intersection(bounds)
    }

    override func rightMouseDown(with e: NSEvent) { finish(nil) }

    override func keyDown(with e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Escape: finish(nil)
        case kVK_Return, kVK_ANSI_KeypadEnter: if let r = picked { finish(r) } else { NSSound.beep() }
        default: super.keyDown(with: e)
        }
    }

    private func finish(_ r: Rect?) {
        let d = done
        done = nil
        d?(r)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        if let s = selection {
            NSColor.clear.setFill()
            s.fill(using: .copy)
            NSColor.white.setStroke()
            NSBezierPath(rect: s.insetBy(dx: -0.5, dy: -0.5)).stroke()
            badge("\(Int(s.width.rounded())) × \(Int(s.height.rounded()))", centeredAt: NSPoint(x: s.midX, y: s.minY > 40 ? s.minY - 20 : s.maxY + 20))
        }
        badge(String(localized: "Drag to choose the area to record. Enter or a double-click records, Esc or a right-click cancels."),
              centeredAt: NSPoint(x: bounds.midX, y: bounds.maxY - 60))
    }

    private func badge(_ text: String, centeredAt c: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = NSRect(x: c.x - size.width / 2 - 10, y: c.y - size.height / 2 - 5, width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 10, y: box.minY + 5), withAttributes: attrs)
    }
}

/// 3, 2, 1 in a dark rounded square before a recording starts. A non-activating panel: it takes Esc without pulling the
/// app being recorded out of the front, and it is gone before the first frame is captured.
@MainActor
final class Countdown {
    static let seconds = 3
    let view = CountdownView(frame: NSRect(x: 0, y: 0, width: 280, height: 300))
    private var panel: NSPanel?
    private var done: CheckedContinuation<Bool, Never>?
    private var ticking: Task<Void, Never>?

    /// Centered on `center` (screen coordinates); true when it ran out, false when cancelled.
    func run(at center: NSPoint) async -> Bool {
        let p = KeyPanel(contentRect: NSRect(x: center.x - 140, y: center.y - 150, width: 280, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = view
        view.onEscape = { [weak self] in self?.cancel() }
        panel = p
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(view)
        return await withCheckedContinuation { c in
            done = c
            ticking = Task { [weak self] in
                for n in stride(from: Self.seconds, to: 0, by: -1) {
                    self?.view.number = n
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                self?.finish(true)
            }
        }
    }

    func cancel() { finish(false) }

    private func finish(_ ranOut: Bool) {
        ticking?.cancel()
        panel?.orderOut(nil)
        panel = nil
        done?.resume(returning: ranOut)
        done = nil
    }
}

/// Borderless panels can't become key on their own; the countdown needs Esc.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CountdownView: NSView {
    var number = Countdown.seconds { didSet { needsDisplay = true } }
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with e: NSEvent) {
        if Int(e.keyCode) == kVK_Escape { onEscape?() } else { super.keyDown(with: e) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 20, y: 40, width: 240, height: 240)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 44, yRadius: 44).fill()
        let digit: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 150, weight: .bold).monospacedDigitFont(),
                                                    .foregroundColor: NSColor.white]
        let text = "\(number)" as NSString, size = text.size(withAttributes: digit)
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: digit)
        let hint = String(localized: "Esc to cancel") as NSString
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let hs = hint.size(withAttributes: small), pill = NSRect(x: bounds.midX - hs.width / 2 - 10, y: 4, width: hs.width + 20, height: hs.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        hint.draw(at: NSPoint(x: pill.minX + 10, y: pill.minY + 4), withAttributes: small)
    }
}

private extension NSFont {
    func monospacedDigitFont() -> NSFont { NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .bold) }
}
