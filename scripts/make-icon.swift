// Draws the app icon and writes Resources/AppIcon.icns.
// The artwork is full-bleed: macOS 26 masks it to the system tile itself, and an icon that brings its own
// tile shape (transparent margins, own shadow) gets boxed onto a grey plate instead.
// Run: swift scripts/make-icon.swift   (needs sips and iconutil, both ship with macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {   // (color, alpha, location)
    CGGradient(colorsSpace: cs, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
func fill(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func fillRadial(_ path: CGPath, _ g: CGGradient, _ c0: CGPoint, _ r0: CGFloat, _ c1: CGPoint, _ r1: CGFloat) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawRadialGradient(g, startCenter: c0, startRadius: r0, endCenter: c1, endRadius: r1, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

// full-bleed background; the artwork below keeps to the central ~80 % so the system mask never clips it
let tileRect = CGRect(x: 0, y: 0, width: size, height: size)
let tile = CGPath(rect: tileRect, transform: nil)
fill(tile, gradient([(0x3a3a43, 1, 0), (0x1c1c22, 1, 0.55), (0x0d0d10, 1, 1)]), from: CGPoint(x: 512, y: 1024), to: CGPoint(x: 512, y: 0))

let lens = CGPoint(x: 466, y: 566)
// warm light from the record dot spilling onto the tile
fillRadial(tile, gradient([(0xff5a2a, 0.30, 0), (0xff5a2a, 0.08, 0.5), (0xff5a2a, 0, 1)]), lens, 0, lens, 470)

let metal = gradient([(0xffffff, 1, 0), (0xe4e4ea, 1, 0.45), (0xa9aab3, 1, 1)])
// handle, drawn first so the ring sits on top of its end
let dir = CGPoint(x: cos(-CGFloat.pi / 4), y: sin(-CGFloat.pi / 4))
let handle = CGMutablePath()
handle.move(to: CGPoint(x: lens.x + dir.x * 240, y: lens.y + dir.y * 240))
handle.addLine(to: CGPoint(x: lens.x + dir.x * 420, y: lens.y + dir.y * 420))
let handleShape = handle.copy(strokingWithWidth: 84, lineCap: .round, lineJoin: .round, miterLimit: 1)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.55))
ctx.addPath(handleShape); ctx.setFillColor(rgb(0xb8b9c1)); ctx.fillPath()
ctx.restoreGState()
fill(handleShape, metal, from: CGPoint(x: lens.x + 200, y: lens.y - 140), to: CGPoint(x: lens.x + 330, y: lens.y - 330))
ctx.addPath(handleShape); ctx.setLineWidth(3); ctx.setStrokeColor(rgb(0x000000, 0.3)); ctx.strokePath()

// ring
let ringOuter = 262.0, ringInner = 204.0
let ring = CGMutablePath(); ring.addPath(circle(lens, ringOuter)); ring.addPath(circle(lens, ringInner))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.5))
ctx.addPath(ring); ctx.setFillColor(rgb(0xd0d0d6)); ctx.fillPath(using: .evenOdd)
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(ring); ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(metal, start: CGPoint(x: lens.x - 200, y: lens.y + 220), end: CGPoint(x: lens.x + 200, y: lens.y - 220), options: [])
ctx.restoreGState()
// machined edges: a dark hairline on both rims, and a bright bevel along the top of the outer rim
for (r, a) in [(ringOuter - 1.5, 0.35), (ringInner + 1.5, 0.55)] {
    ctx.addPath(circle(lens, r)); ctx.setLineWidth(3); ctx.setStrokeColor(rgb(0x000000, a)); ctx.strokePath()
}
ctx.saveGState()
ctx.addPath(circle(lens, ringOuter - 9)); ctx.setLineWidth(6); ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([(0xffffff, 0.9, 0), (0xffffff, 0, 0.5)]), start: CGPoint(x: lens.x - 160, y: lens.y + 200),
                       end: CGPoint(x: lens.x + 60, y: lens.y - 40), options: [])
ctx.restoreGState()

// glass: dark, lit from the dot, with a soft top-left reflection
let glass = circle(lens, ringInner)
fillRadial(glass, gradient([(0x2a1712, 1, 0), (0x121117, 1, 0.65), (0x09090c, 1, 1)]), lens, 0, lens, ringInner)
let sheen = CGPoint(x: lens.x - 70, y: lens.y + 110)
fillRadial(glass, gradient([(0xffffff, 0.16, 0), (0xffffff, 0.05, 0.5), (0xffffff, 0, 1)]), sheen, 0, sheen, 170)
// inner shadow along the rim edge
ctx.saveGState(); ctx.addPath(glass); ctx.clip()
ctx.addPath(circle(lens, ringInner + 40)); ctx.setLineWidth(80)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 26, color: rgb(0x000000, 0.9))
ctx.setStrokeColor(rgb(0x000000)); ctx.strokePath()
ctx.restoreGState()

// record dot with glow and a specular highlight
let dotR = 96.0
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xff5a2a, 0.9))
ctx.addPath(circle(lens, dotR)); ctx.setFillColor(rgb(0xff5a2a)); ctx.fillPath()
ctx.restoreGState()
fillRadial(circle(lens, dotR), gradient([(0xff9b6e, 1, 0), (0xff5a2a, 1, 0.55), (0xd8380e, 1, 1)]),
           CGPoint(x: lens.x - 30, y: lens.y + 34), 0, lens, dotR)
fillRadial(circle(CGPoint(x: lens.x - 30, y: lens.y + 38), 40), gradient([(0xffffff, 0.55, 0), (0xffffff, 0, 1)]),
           CGPoint(x: lens.x - 30, y: lens.y + 38), 0, CGPoint(x: lens.x - 30, y: lens.y + 38), 40)

// write 1024 PNG, then the iconset and .icns
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let master = work.appendingPathComponent("icon_512x512@2x.png")
let dest = CGImageDestinationCreateWithURL(master as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("png write failed") }
func sh(_ args: String...) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; try! p.run(); p.waitUntilExit()
    precondition(p.terminationStatus == 0, args.joined(separator: " "))
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512)] {
    sh("sips", "-z", "\(px)", "\(px)", master.path, "--out", work.appendingPathComponent("icon_\(name).png").path)
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
sh("iconutil", "-c", "icns", work.path, "-o", out.path)
try? FileManager.default.removeItem(at: root.appendingPathComponent("Resources/AppIcon-1024.png"))
try FileManager.default.copyItem(at: master, to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
print("wrote \(out.path)")
