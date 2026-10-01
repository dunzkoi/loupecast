import XCTest
@testable import LoupecastCore

final class ZoomTests: XCTestCase {
    func click(_ t: Double, _ x: Double = 0.5, _ y: Double = 0.5) -> ClickEvent { ClickEvent(t: t, x: x, y: y) }

    // MARK: clustering

    func testClusterWindowAndBounds() {
        let segs = AutoZoom.segments(clicks: [click(1.0), click(2.0), click(10.0)], duration: 20)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].start, 0.6, accuracy: 1e-9)   // 0.4 s before first click
        XCTAssertEqual(segs[0].end, 3.5, accuracy: 1e-9)     // 1.5 s after last click
        XCTAssertEqual(segs[1].start, 9.6, accuracy: 1e-9)
        XCTAssertEqual(segs[1].end, 11.5, accuracy: 1e-9)
        XCTAssertEqual(segs[0].scale, 2.0)
    }

    func testClusterSplitsOnTimeAndDistance() {
        // < 1.5 s and close → one cluster
        XCTAssertEqual(AutoZoom.clusters([click(1), click(2.4, 0.6, 0.6)]).count, 1)
        // 1.5 s apart → two clusters (gap must be strictly shorter)
        XCTAssertEqual(AutoZoom.clusters([click(1), click(2.5)]).count, 2)
        // close in time but farther than 0.25 → two clusters
        XCTAssertEqual(AutoZoom.clusters([click(1, 0.1, 0.1), click(1.2, 0.4, 0.4)]).count, 2)
        XCTAssertEqual(AutoZoom.clusters([click(1, 0.1, 0.1), click(1.2, 0.25, 0.25)]).count, 1)
    }

    func testClampsToRecording() {
        let segs = AutoZoom.segments(clicks: [click(0.1), click(9.5)], duration: 10)
        XCTAssertEqual(segs.first?.start, 0)
        XCTAssertEqual(segs.last?.end, 10)
    }

    // MARK: merging

    func testMergeShortGapButKeepLongGap() {
        // windows [0.6, 2.5] and [3.4, 5.3]: gap 0.9 < 1.0 → merged
        let merged = AutoZoom.segments(clicks: [click(1.0), click(3.8, 0.9, 0.9)], duration: 20)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0.6, accuracy: 1e-9)
        XCTAssertEqual(merged[0].end, 5.3, accuracy: 1e-9)
        // windows [0.6, 2.5] and [3.6, 5.5]: gap 1.1 → two segments
        XCTAssertEqual(AutoZoom.segments(clicks: [click(1.0), click(4.0)], duration: 20).count, 2)
    }

    // MARK: trim clipping

    func testTrimClipping() {
        let segs = [ZoomSegment(start: 1, end: 3, focus: .center),
                    ZoomSegment(start: 4, end: 6, focus: .center),
                    ZoomSegment(start: 8, end: 9, focus: .center)]
        let a = segs.clipped(to: 2, 8.5)
        XCTAssertEqual(a.map(\.start), [2, 4, 8])
        XCTAssertEqual(a.map(\.end), [3, 6, 8.5])
        XCTAssertEqual(segs.clipped(to: 3.5, 7).map(\.start), [4])
        XCTAssertTrue(segs.clipped(to: 0, 0.5).isEmpty)
        // the camera honours the clip: zoomed right after trim-in, identity after trim-out
        let path = CameraPath(segments: [ZoomSegment(start: 1, end: 5, focus: .center)], cursor: [], trimIn: 3, trimOut: 10)
        XCTAssertEqual(path.camera(at: 2).scale, 1)
        XCTAssertEqual(path.camera(at: 3.7).scale, 2, accuracy: 1e-9)
        XCTAssertEqual(path.camera(at: 5.5).scale, 1)
    }

    // MARK: camera(t)

    /// A messy timeline: unmerged neighbours exactly 1.0 s apart, a user-made overlap, a disabled
    /// segment, a clipped segment at trim-in, and a cursor that teleports across the screen.
    func messyPath() -> CameraPath {
        var cursor: [CursorSample] = []
        var rng = SystemRandomNumberGenerator()
        var x = 0.5, y = 0.5
        for i in 0..<(30 * 60) {
            let t = Double(i) / 60
            if i % 300 == 0 { x = Double.random(in: 0...1, using: &rng); y = Double.random(in: 0...1, using: &rng) }
            else { x = min(1, max(0, x + Double.random(in: -0.01...0.01, using: &rng))); y = min(1, max(0, y + Double.random(in: -0.01...0.01, using: &rng))) }
            cursor.append(CursorSample(t: t, x: x, y: y))
        }
        var segs = AutoZoom.segments(clicks: [click(2, 0.9, 0.1), click(2.5, 0.95, 0.05),
                                              click(5.5, 0.1, 0.9)], duration: 30)
        segs.append(ZoomSegment(start: 10, end: 14, scale: 2.5, focus: Point(x: 0, y: 0)))
        segs.append(ZoomSegment(start: 12, end: 16, scale: 1.6, focus: Point(x: 1, y: 1)))
        segs.append(ZoomSegment(start: 18, end: 18.5, focus: .center))           // short: partial zoom
        segs.append(ZoomSegment(start: 20, end: 24, focus: .center, isEnabled: false))
        segs.append(ZoomSegment(start: 0, end: 2, focus: Point(x: 0.2, y: 0.8)))  // straddles trim-in
        return CameraPath(segments: segs, cursor: cursor, trimIn: 1, trimOut: 29.7)
    }

    func testCameraContinuityAt60fps() {
        let path = messyPath()
        var prev = path.camera(at: 1)
        var maxDS = 0.0, maxDC = 0.0
        for i in 61...(Int(29.7 * 60)) {
            let c = path.camera(at: Double(i) / 60)
            maxDS = max(maxDS, abs(c.scale - prev.scale))
            maxDC = max(maxDC, hypot(c.center.x - prev.center.x, c.center.y - prev.center.y))
            prev = c
        }
        print("camera sweep 60 fps: max Δscale/frame = \(maxDS), max Δcenter/frame = \(maxDC)")
        // smootherstep peak slope 1.875/0.6 s × 1.5 scale range / 60 fps ≈ 0.078
        XCTAssertLessThan(maxDS, 0.08, "scale jumps between frames")
        // a full-screen cursor teleport peaks at ω·Δ/e ≈ 0.043/frame; a snap would be ≥ 0.25
        XCTAssertLessThan(maxDC, 0.05, "center jumps between frames")
        XCTAssertGreaterThan(maxDS, 0.01, "sweep should actually cover zoom transitions")
    }

    func testDisabledSegmentDoesNotZoom() {
        XCTAssertEqual(messyPath().camera(at: 22).scale, 1)
    }

    func testClampedInsideRecording() {
        let path = messyPath()
        for i in 0..<(30 * 60) {
            let c = path.camera(at: Double(i) / 60)
            let h = 0.5 / c.scale
            XCTAssertGreaterThanOrEqual(c.scale, 1)
            XCTAssertGreaterThanOrEqual(c.center.x - h, -1e-9); XCTAssertLessThanOrEqual(c.center.x + h, 1 + 1e-9)
            XCTAssertGreaterThanOrEqual(c.center.y - h, -1e-9); XCTAssertLessThanOrEqual(c.center.y + h, 1 + 1e-9)
        }
        // focus in the corner → window pinned to the corner, not beyond it
        let corner = CameraPath(segments: [ZoomSegment(start: 0, end: 4, focus: Point(x: 0, y: 1))], cursor: [], trimIn: 0, trimOut: 4)
        XCTAssertEqual(corner.camera(at: 2), Camera(scale: 2, center: Point(x: 0.25, y: 0.75)))
    }

    func testSpringFollowsCursorWithoutOvershoot() {
        // cursor steps from 0.3 to 0.7 at t = 2; focus must approach 0.7 monotonically and never pass it
        let cursor = (0..<600).map { i -> CursorSample in
            let t = Double(i) / 60
            return CursorSample(t: t, x: t < 2 ? 0.3 : 0.7, y: 0.5)
        }
        let path = CameraPath(segments: [ZoomSegment(start: 0, end: 10, focus: Point(x: 0.3, y: 0.5))],
                              cursor: cursor, trimIn: 0, trimOut: 10)
        var last = 0.0
        for i in 120...540 {
            let x = path.camera(at: Double(i) / 60).center.x
            XCTAssertGreaterThanOrEqual(x, last - 1e-12)
            XCTAssertLessThanOrEqual(x, 0.7 + 1e-9)
            last = x
        }
        XCTAssertEqual(last, 0.7, accuracy: 0.01)          // settled within the hold
        XCTAssertEqual(path.camera(at: 2.1).center.x, 0.3, accuracy: 0.05) // eased, not snapped
    }

    func testEasingShape() {
        XCTAssertEqual(smootherstep(0), 0); XCTAssertEqual(smootherstep(1), 1)
        XCTAssertEqual(smootherstep(0.5), 0.5, accuracy: 1e-12)
        let path = CameraPath(segments: [ZoomSegment(start: 1, end: 5, focus: .center)], cursor: [], trimIn: 0, trimOut: 10)
        XCTAssertEqual(path.camera(at: 1.0).scale, 1)
        XCTAssertEqual(path.camera(at: 1.3).scale, 1.5, accuracy: 1e-9)   // halfway through the 0.6 s ease-in
        XCTAssertEqual(path.camera(at: 1.6).scale, 2)
        XCTAssertEqual(path.camera(at: 4.4).scale, 2)
        XCTAssertEqual(path.camera(at: 4.7).scale, 1.5, accuracy: 1e-9)
    }

    // MARK: project + edit ops

    func testProjectDefaultsAndRoundTrip() throws {
        let p = Project(name: "t", duration: 10, pixelWidth: 100, pixelHeight: 50, pointPixelScale: 2,
                        cursor: [], clicks: [click(3)], keys: [])
        XCTAssertEqual(p.trimOut, 9.7, accuracy: 1e-9)
        XCTAssertEqual(p.zooms.count, 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try p.save(to: url)
        XCTAssertEqual(try Project.load(from: url), p)
        var future = p; future.version = 99
        try future.save(to: url)
        XCTAssertThrowsError(try Project.load(from: url))
    }

    func testEditOps() {
        var p = Project(name: "t", duration: 10, pixelWidth: 100, pixelHeight: 50, pointPixelScale: 2,
                        cursor: [CursorSample(t: 0, x: 0.1, y: 0.2), CursorSample(t: 10, x: 0.9, y: 0.8)],
                        clicks: [], keys: [])
        p.setTrimIn(2); p.setTrimOut(7.5)
        XCTAssertEqual(p.playStart(from: 7.5), 2)      // at trim-out → wraps to trim-in
        XCTAssertEqual(p.playStart(from: 9), 2)        // in the cut tail → trim-in
        XCTAssertEqual(p.playStart(from: 1), 2)
        XCTAssertEqual(p.playStart(from: 4), 4)
        p.setTrimIn(8)                                  // cannot cross trim-out
        XCTAssertLessThan(p.trimIn, p.trimOut)
        let z = p.addZoom(at: 5)
        XCTAssertEqual(z.end - z.start, 2, accuracy: 1e-9)
        XCTAssertEqual(z.focus.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(z.focus.y, 0.5, accuracy: 1e-9)
        p.setZoomEnd(id: z.id, 4)                       // cannot invert
        XCTAssertGreaterThan(p.zooms[0].end, p.zooms[0].start)
        p.setZoomEnabled(id: z.id, false)
        XCTAssertFalse(p.zooms[0].isEnabled)
        p.removeZoom(id: z.id)
        XCTAssertTrue(p.zooms.isEmpty)
    }

    func testNormalizationAcrossDisplays() {
        // secondary display left of and above the main one (negative global origin)
        let d = DisplayBounds(x: -1728, y: -400, width: 1728, height: 1117)
        let p = d.normalize(-864, -400 + 1117 / 2)
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9); XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
        var log = InputLog()
        log.append(.init(host: 100.5, gx: -1728, gy: -400, kind: .click(.left)))     // top-left corner
        log.append(.init(host: 101, gx: 200, gy: 300, kind: .click(.left)))          // on another display → dropped
        log.append(.init(host: 99, gx: -100, gy: 0, kind: .click(.left)))            // before session → dropped
        let r = log.relativized(sessionStartHost: 100, duration: 5, display: d)
        XCTAssertEqual(r.clicks.count, 1)
        XCTAssertEqual(r.clicks[0].t, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.clicks[0].x, 0); XCTAssertEqual(r.clicks[0].y, 0)
    }

    // MARK: menu-bar crop

    func testMenuBarInset() {
        // external display (AppKit bottom-left space): 30 pt menu bar, no notch
        XCTAssertEqual(DisplayBounds.menuBarInset(frameMaxY: 1692, visibleMaxY: 1662, safeAreaTop: 0), 30)
        // notch taller than the reported menu bar wins
        XCTAssertEqual(DisplayBounds.menuBarInset(frameMaxY: 0, visibleMaxY: -24, safeAreaTop: 32), 32)
        // auto-hidden menu bar: only the notch is excluded, or nothing
        XCTAssertEqual(DisplayBounds.menuBarInset(frameMaxY: 1117, visibleMaxY: 1117, safeAreaTop: 32), 32)
        XCTAssertEqual(DisplayBounds.menuBarInset(frameMaxY: 1117, visibleMaxY: 1117, safeAreaTop: 0), 0)
    }

    func testCropRectAndOutputSize() {
        let d = DisplayBounds(x: 0, y: 0, width: 3008, height: 1692, topInset: 30)
        let r = d.captureRect
        XCTAssertEqual([r.x, r.y, r.width, r.height], [0, 30, 3008, 1662])
        let px = d.pixelSize(scale: 2)
        XCTAssertEqual(px.width, 6016); XCTAssertEqual(px.height, 3324)          // proportional to the rect
        let odd = DisplayBounds(x: 0, y: 0, width: 1728, height: 1117, topInset: 32.5).pixelSize(scale: 2)
        XCTAssertEqual(odd.height, 2168)                                          // 2169 → even
        XCTAssertEqual(Double(odd.width) / Double(odd.height), 1728 / 1084.5, accuracy: 0.001)
        XCTAssertEqual(DisplayBounds(x: 0, y: 0, width: 1728, height: 1117).pixelSize(scale: 2).height, 2234)
    }

    func testNormalizationAgainstCroppedRect() {
        // built-in display below-right of the main one, 32 pt strip excluded
        let d = DisplayBounds(x: 629, y: -1117, width: 1728, height: 1117, topInset: 32)
        let mid = d.normalize(629 + 864, -1117 + 32 + 1085.0 / 2)
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-12); XCTAssertEqual(mid.y, 0.5, accuracy: 1e-12)

        let known = (x: 629 + 1728 * 0.25, y: -1117 + 32 + 1085 * 0.25)        // a known screen point
        var log = InputLog()
        for i in 0...600 { log.append(.init(host: 100 + Double(i) / 60, gx: known.x, gy: known.y, kind: .move)) }
        log.append(.init(host: 103, gx: known.x, gy: known.y, kind: .click(.left)))
        log.append(.init(host: 106, gx: 629 + 172.8, gy: -1117 + 10, kind: .click(.left)))   // inside the strip
        log.append(.init(host: 107, gx: 100, gy: 100, kind: .click(.left)))                 // main display → dropped
        log.append(.init(host: 108.005, gx: 900, gy: -1117 + 5, kind: .move))               // cursor in the strip
        let r = log.relativized(sessionStartHost: 100, duration: 10, display: d)

        XCTAssertEqual(r.clicks.count, 2)
        XCTAssertEqual(r.clicks[0].x, 0.25, accuracy: 1e-12); XCTAssertEqual(r.clicks[0].y, 0.25, accuracy: 1e-12)
        XCTAssertEqual(r.clicks[1].x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(r.clicks[1].y, 0, "strip click is clamped to the top edge, not dropped")
        XCTAssertEqual(r.cursor.first { abs($0.t - 8.005) < 1e-6 }?.y, 0)
        // measured against the full display the same point would land 32 pt off: the crop matters
        XCTAssertGreaterThan(abs(DisplayBounds(x: 629, y: -1117, width: 1728, height: 1117).normalize(known.x, known.y).y - 0.25), 0.02)

        // the zoom built from the click is centered on it, and the click is inside the zoom rect
        let seg = AutoZoom.segments(clicks: [r.clicks[0]], duration: 10)[0]
        XCTAssertEqual(seg.focus, Point(x: 0.25, y: 0.25))
        let cam = CameraPath(segments: [seg], cursor: r.cursor, trimIn: 0, trimOut: 10).camera(at: 3.3)
        XCTAssertEqual(cam.scale, 2, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(abs(cam.center.x - 0.25), 0.5 / cam.scale)
        XCTAssertLessThanOrEqual(abs(cam.center.y - 0.25), 0.5 / cam.scale)
    }
}
