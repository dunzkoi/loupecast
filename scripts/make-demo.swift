// Draws the screen for the landing-page demo: a to-do app on a 1280 × 800 pt (2×) desktop, with a cursor that ticks a
// task, adds one, waits (the part the demo cuts) and opens another list. Writes <dir>/recording.mov and a project.json
// with those clicks, the zooms on them and the cut, the way a recording and a few edits leave them; Loupecast itself
// renders the result. Run through scripts/make-demo.sh, which also exports and encodes the site and README files.
// Run: swift scripts/make-demo.swift <dir>
import AppKit
import AVFoundation

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "demo", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let W = 1280.0, H = 800.0, scale = 2.0, fps = 60.0, duration = 19.5

// MARK: script (seconds, points from the screen's top-left)

let win = CGRect(x: 170, y: 90, width: 940, height: 600)
let sidebarW = 230.0, rowH = 48.0
let listX = win.minX + sidebarW + 32, rowsY = win.minY + 140
let newTaskButton = CGRect(x: win.maxX - 130, y: win.minY + 14, width: 110, height: 30)
let shareButton = CGRect(x: newTaskButton.minX - 92, y: newTaskButton.minY, width: 80, height: 30)
func sidebarItem(_ i: Int) -> CGRect { CGRect(x: win.minX + 12, y: win.minY + 72 + Double(i) * 32, width: sidebarW - 24, height: 30) }

let clicks: [(t: Double, p: CGPoint)] = [
    (2.2, CGPoint(x: listX + 11, y: rowsY + rowH / 2)),                       // tick the first task
    (4.6, CGPoint(x: newTaskButton.midX, y: newTaskButton.midY)),             // New Task
    (5.3, CGPoint(x: listX + 190, y: rowsY + rowH / 2)),                      // into its title
    (12.7, CGPoint(x: sidebarItem(1).midX - 40, y: sidebarItem(1).midY)),     // Upcoming
    (14.9, CGPoint(x: shareButton.midX, y: shareButton.midY)),                // Share
]
/// Cursor keyframes: it eases between them and rests on each click a moment.
let keys: [(t: Double, p: CGPoint)] = [
    (0, CGPoint(x: 760, y: 560)), (1.75, clicks[0].p), (2.45, clicks[0].p),
    (4.3, clicks[1].p), (4.75, clicks[1].p), (5.15, clicks[2].p), (5.45, clicks[2].p), (5.9, CGPoint(x: listX + 400, y: rowsY + 64)),
    (8.4, CGPoint(x: listX + 412, y: rowsY + 70)), (10.5, CGPoint(x: 820, y: 520)), (11.7, CGPoint(x: 800, y: 500)),
    (12.45, clicks[3].p), (12.9, clicks[3].p), (14.6, clicks[4].p), (15.05, clicks[4].p), (15.7, CGPoint(x: shareButton.midX + 6, y: shareButton.maxY + 74)),
    (duration, CGPoint(x: shareButton.midX + 8, y: shareButton.maxY + 78)),
]
let typed = "Record a demo with Loupecast", typeStart = 5.6, typeEnd = 7.9

func ease(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
func cursor(at t: Double) -> CGPoint {
    guard let i = keys.lastIndex(where: { $0.t <= t }), i + 1 < keys.count else { return keys.last!.p }
    let a = keys[i], b = keys[i + 1], u = ease((t - a.t) / (b.t - a.t))
    return CGPoint(x: a.p.x + (b.p.x - a.p.x) * u, y: a.p.y + (b.p.y - a.p.y) * u)
}

// MARK: drawing

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, _ c: NSColor = color(0x1d1d1f), strike: Bool = false) -> CGFloat {
    var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c]
    if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.strikethroughColor] = c }
    let str = NSAttributedString(string: s, attributes: attrs)
    str.draw(at: CGPoint(x: p.x, y: p.y - str.size().height / 2))
    return str.size().width
}
func round(_ r: CGRect, _ radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    if let fill { fill.setFill(); path.fill() }
    if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
}
func symbol(_ name: String, in r: CGRect, _ c: NSColor, _ secondary: NSColor? = nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: .semibold).applying(.init(paletteColors: [c] + (secondary.map { [$0] } ?? [])))
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)?
        .draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

let accent = color(0x2f6feb)
struct Task { let title: String; let tag: String?; let due: String }
let today = [Task(title: "Write release notes for 0.8", tag: "Loupecast", due: "Today"),
             Task(title: "Review the landing page copy", tag: "Website", due: "Today"),
             Task(title: "Reply to the sponsor email", tag: nil, due: "Today"),
             Task(title: "Fix the export progress bar", tag: "Loupecast", due: "Tomorrow"),
             Task(title: "Plan the next sprint", tag: nil, due: "Fri")]
let upcoming: [(String, [Task])] = [
    ("Tomorrow", [Task(title: "Fix the export progress bar", tag: "Loupecast", due: "10:00"),
                  Task(title: "Call the print shop", tag: nil, due: "14:30")]),
    ("Friday", [Task(title: "Plan the next sprint", tag: nil, due: "All day"),
                Task(title: "Ship 0.8 to Homebrew", tag: "Loupecast", due: "17:00")]),
]

func row(_ y: Double, _ task: Task, done: Bool = false, editing: String? = nil, caret: Bool = false) {
    let box = CGRect(x: listX, y: y + rowH / 2 - 10, width: 20, height: 20)
    if done {
        accent.setFill(); NSBezierPath(ovalIn: box).fill()
        symbol("checkmark", in: box.insetBy(dx: 5, dy: 5), .white)
    } else {
        color(0xb8b8be).setStroke(); let o = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75)); o.lineWidth = 1.5; o.stroke()
    }
    let tx = listX + 36
    if let editing {
        let w = text(editing, CGPoint(x: tx, y: y + rowH / 2), size: 15, weight: .medium)
        if caret { accent.setFill(); CGRect(x: tx + w + 1, y: y + rowH / 2 - 10, width: 2, height: 20).fill() }
        if editing.isEmpty { _ = text("New task", CGPoint(x: tx + 6, y: y + rowH / 2), size: 15, color(0xb0b0b6)) }
    } else {
        let w = text(task.title, CGPoint(x: tx, y: y + rowH / 2), size: 15, weight: .medium, done ? color(0x9a9aa0) : color(0x1d1d1f), strike: done)
        if let tag = task.tag {
            let tw = (tag as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
            round(CGRect(x: tx + w + 12, y: y + rowH / 2 - 10, width: tw + 16, height: 20), 10, fill: accent.withAlphaComponent(0.12))
            _ = text(tag, CGPoint(x: tx + w + 20, y: y + rowH / 2), size: 11, weight: .semibold, accent)
        }
    }
    if editing == nil {
        let dw = (task.due as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        _ = text(task.due, CGPoint(x: win.maxX - 32 - dw, y: y + rowH / 2), size: 13, color(0x8e8e93))
    }
    color(0xececf0).setFill(); CGRect(x: listX, y: y + rowH - 0.5, width: win.maxX - 32 - listX, height: 1).fill()
}

func drawFrame(at t: Double) {
    // desktop
    NSGradient(colors: [color(0x2b3a67), color(0x5b4a8c), color(0xb06a8f)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: 35)
    // window with its shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    round(win, 12, fill: .white)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: win, xRadius: 12, yRadius: 12).addClip()
    color(0xf4f3f8).setFill(); CGRect(x: win.minX, y: win.minY, width: sidebarW, height: win.height).fill()
    color(0xe2e1e6).setFill(); CGRect(x: win.minX + sidebarW, y: win.minY, width: 1, height: win.height).fill()
    for (i, c) in [0xff5f57, 0xfebc2e, 0x28c840].enumerated() {
        color(UInt32(c)).setFill(); NSBezierPath(ovalIn: CGRect(x: win.minX + 16 + Double(i) * 20, y: win.minY + 16, width: 12, height: 12)).fill()
    }
    // sidebar
    let onUpcoming = t >= clicks[3].t
    let items: [(String, String, UInt32, String)] = [("Today", "star.fill", 0xf5b400, t >= clicks[0].t && t < clicks[1].t + 0.3 ? "4" : "5"),
                                                    ("Upcoming", "calendar", 0xe0443e, "4"), ("Anytime", "square.stack.fill", 0x14a3a8, ""),
                                                    ("Someday", "archivebox.fill", 0xc2a46b, "")]
    for (i, item) in items.enumerated() {
        let r = sidebarItem(i), selected = i == (onUpcoming ? 1 : 0)
        if selected { round(r, 7, fill: accent) }
        symbol(item.1, in: CGRect(x: r.minX + 10, y: r.midY - 8, width: 16, height: 16), selected ? .white : color(item.2))
        _ = text(item.0, CGPoint(x: r.minX + 36, y: r.midY), size: 14, weight: .medium, selected ? .white : color(0x1d1d1f))
        if !item.3.isEmpty { _ = text(item.3, CGPoint(x: r.maxX - 22, y: r.midY), size: 13, selected ? .white.withAlphaComponent(0.85) : color(0x8e8e93)) }
    }
    _ = text("PROJECTS", CGPoint(x: win.minX + 22, y: win.minY + 226), size: 11, weight: .semibold, color(0x8e8e93))
    for (i, (name, hex)) in [("Website launch", UInt32(0x5e5ce6)), ("Loupecast 1.0", 0xff6b2c)].enumerated() {
        let y = win.minY + 250 + Double(i) * 32
        color(hex).setFill(); NSBezierPath(ovalIn: CGRect(x: win.minX + 26, y: y - 5, width: 10, height: 10)).fill()
        _ = text(name, CGPoint(x: win.minX + 48, y: y), size: 14, color(0x1d1d1f))
    }
    // toolbar
    let pressed = { (c: Int) in t >= clicks[c].t && t < clicks[c].t + 0.15 }
    round(shareButton, 7, fill: pressed(4) ? color(0xe4e4e9) : .white, stroke: color(0xd2d2d7))
    symbol("square.and.arrow.up", in: CGRect(x: shareButton.minX + 12, y: shareButton.midY - 8, width: 14, height: 15), color(0x3a3a3c))
    _ = text("Share", CGPoint(x: shareButton.minX + 32, y: shareButton.midY), size: 13, weight: .medium, color(0x3a3a3c))
    round(newTaskButton, 7, fill: pressed(1) ? color(0x2457bf) : accent)
    symbol("plus", in: CGRect(x: newTaskButton.minX + 12, y: newTaskButton.midY - 7, width: 14, height: 14), .white)
    _ = text("New Task", CGPoint(x: newTaskButton.minX + 32, y: newTaskButton.midY), size: 13, weight: .semibold, .white)
    // list
    if onUpcoming {
        _ = text("Upcoming", CGPoint(x: listX, y: win.minY + 92), size: 26, weight: .bold)
        var y = rowsY
        for (day, tasks) in upcoming {
            _ = text(day, CGPoint(x: listX, y: y + 18), size: 13, weight: .semibold, color(0x8e8e93))
            y += 34
            for task in tasks { row(y, task); y += rowH }
            y += 10
        }
    } else {
        _ = text("Today", CGPoint(x: listX, y: win.minY + 92), size: 26, weight: .bold)
        let added = t >= clicks[1].t
        let shift = added ? ease((t - clicks[1].t) / 0.25) * rowH : 0     // the rows slide down for the new one
        if added {
            let n = Int((Double(typed.count) * (t - typeStart) / (typeEnd - typeStart)).rounded(.down))
            let shown = String(typed.prefix(max(0, min(typed.count, n))))
            let editing = t < typeEnd + 0.4
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: listX, y: rowsY, width: win.width, height: shift)).addClip()
            if editing { round(CGRect(x: listX - 10, y: rowsY + 3, width: win.maxX - 22 - listX, height: rowH - 6), 8, fill: accent.withAlphaComponent(0.07)) }
            row(rowsY, Task(title: shown, tag: editing ? nil : "Loupecast", due: "Today"), editing: editing ? shown : nil,
                caret: editing && Int(t * 2.4) % 2 == 0 && t >= clicks[2].t)
            NSGraphicsContext.restoreGraphicsState()
        }
        for (i, task) in today.enumerated() { row(rowsY + shift + Double(i) * rowH, task, done: i == 0 && t >= clicks[0].t) }
    }
    if t >= clicks[4].t {                                              // Share: link copied
        let a = ease((t - clicks[4].t) / 0.2)
        let pop = CGRect(x: shareButton.midX - 110, y: shareButton.maxY + 10 + (1 - a) * 6, width: 220, height: 46)
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(0.22 * a); s.shadowBlurRadius = 18; s.shadowOffset = NSSize(width: 0, height: -6); s.set()
        round(pop, 10, fill: NSColor.white.withAlphaComponent(a))
        NSGraphicsContext.restoreGraphicsState()
        symbol("checkmark.circle.fill", in: CGRect(x: pop.minX + 14, y: pop.midY - 9, width: 18, height: 18), .white.withAlphaComponent(a),
               color(0x28a745).withAlphaComponent(a))
        _ = text("Link copied to clipboard", CGPoint(x: pop.minX + 40, y: pop.midY), size: 13, weight: .medium, color(0x1d1d1f, a))
    }
    NSGraphicsContext.restoreGraphicsState()
    // cursor (hot spot at the tip), as the screen recording shows it
    let c = cursor(at: t)
    let arrow = NSBezierPath()
    for (i, p) in [(0.0, 0.0), (0, 17), (4.2, 13), (7, 19.6), (9.6, 18.5), (6.9, 12.2), (12.2, 12.2)].enumerated() {
        let q = CGPoint(x: c.x + p.0, y: c.y + p.1)
        if i == 0 { arrow.move(to: q) } else { arrow.line(to: q) }
    }
    arrow.close()
    NSGraphicsContext.saveGraphicsState()
    let cs = NSShadow(); cs.shadowColor = .black.withAlphaComponent(0.3); cs.shadowBlurRadius = 3; cs.shadowOffset = NSSize(width: 0, height: -1.5); cs.set()
    NSColor.black.setFill(); arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke(); arrow.lineWidth = 1.3; arrow.lineJoinStyle = .round; arrow.stroke()
}

// MARK: movie

let pw = Int(W * scale), ph = Int(H * scale)
let movie = dir.appendingPathComponent("recording.mov")
try? FileManager.default.removeItem(at: movie)
let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: pw, AVVideoHeightKey: ph,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: pw, kCVPixelBufferHeightKey as String: ph])
writer.add(input)
guard writer.startWriting() else { fatalError("\(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
let frames = Int(duration * fps)
for i in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: pw, height: ph, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: scale, y: -scale)          // points, top-left origin
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    drawFrame(at: Double(i) / fps)
    NSGraphicsContext.current = nil
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("\(String(describing: writer.error))") }

// MARK: project.json: the clicks, the zooms on them, the waiting cut out. While typing, a zoom pinned on the new row
// (its focus picked on the preview) takes over from the one following the cursor; they overlap by more than the
// 0.6 s ramps, so the camera pans across instead of dipping out.

func norm(_ p: CGPoint) -> [String: Double] { ["x": p.x / W, "y": p.y / H] }
let cursorSamples = (0...Int(duration * 60)).map { i -> [String: Double] in
    let t = Double(i) / 60, p = cursor(at: t)
    return ["t": t, "x": p.x / W, "y": p.y / H]
}
func zoom(_ start: Double, _ end: Double, _ focus: CGPoint, follows: Bool = true) -> [String: Any] {
    ["id": UUID().uuidString, "start": start, "end": end, "scale": 2, "focus": norm(focus), "isEnabled": true, "followsCursor": follows]
}
let project: [String: Any] = [
    "version": 2, "name": "Loupecast demo", "videoFile": "recording.mov", "duration": duration,
    "pixelWidth": pw, "pixelHeight": ph, "pointPixelScale": scale, "keys": [Int](),
    "cursor": cursorSamples,
    "clicks": clicks.map { ["t": $0.t, "button": "left"].merging(norm($0.p)) { a, _ in a } },
    "clips": [["id": UUID().uuidString, "start": 0, "end": 8.6, "speed": 1], ["id": UUID().uuidString, "start": 11.6, "end": duration - 0.3, "speed": 1]],
    "zooms": [zoom(1.8, 3.7, clicks[0].p), zoom(4.2, 6.4, clicks[1].p), zoom(5.0, 8.6, CGPoint(x: listX + 250, y: rowsY + 72), follows: false),
              zoom(12.3, 17.8, clicks[3].p)],
    "aspect": "16:9", "style": "pastel",
]
try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys]).write(to: dir.appendingPathComponent("project.json"))
print("wrote \(frames) frames to \(movie.path) and project.json")
