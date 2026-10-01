import XCTest
@testable import LoupecastCore

/// Cut list (REVISION 3): split, delete, composition ↔ recording mapping, v1 migration, zooms at cuts, undo.
final class ClipTests: XCTestCase {
    func project(_ duration: Double = 10) -> Project {
        Project(name: "t", duration: duration, pixelWidth: 100, pixelHeight: 50, pointPixelScale: 2,
                cursor: [], clicks: [], keys: [])
    }

    func assertWellFormed(_ p: Project, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(p.clips.isEmpty, file: file, line: line)
        for c in p.clips { XCTAssertLessThan(c.start, c.end, file: file, line: line) }
        for (a, b) in zip(p.clips, p.clips.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-12, file: file, line: line) }
        XCTAssertEqual(Set(p.clips.map(\.id)).count, p.clips.count, file: file, line: line)
    }

    // MARK: split

    func testSplitAtArbitraryPoints() {
        var p = project()
        let total = p.clips.totalLength
        var rng = SystemRandomNumberGenerator()
        var points: [Double] = []
        for _ in 0..<40 {
            let t = Double.random(in: 0...9.7, using: &rng)
            if p.split(at: t) != nil { points.append(t) }
            assertWellFormed(p)
            XCTAssertEqual(p.clips.totalLength, total, accuracy: 1e-9, "a split keeps all material")
            XCTAssertTrue(p.clips.cutTimes.isEmpty, "split points are not cuts")
            XCTAssertEqual(p.clips.keptRanges.count, 1)
        }
        XCTAssertEqual(p.clips.count, points.count + 1)
        XCTAssertEqual(p.clips.dropFirst().map(\.start), points.sorted(), accuracy: 1e-12)

        // within 2 frames of an edge (or outside any clip) → ignored
        var q = project()
        XCTAssertNotNil(q.split(at: 5))
        let before = q.clips
        for t in [5 + 1.0 / 60, 5 - 1.5 / 60, 0.02, 9.7 - 0.01, 9.9, -1] { XCTAssertNil(q.split(at: t), "\(t)") }
        XCTAssertEqual(q.clips, before)
        XCTAssertNotNil(q.split(at: 5 + 2.0 / 60), "exactly 2 frames away splits")
        // the left part keeps its id, the right part is new
        var r = project()
        let id = r.clips[0].id
        let right = r.split(at: 4)
        XCTAssertEqual(r.clips[0].id, id)
        XCTAssertEqual(r.clips[1].id, right)
    }

    // MARK: delete

    func testDeleteMiddleClip() {
        var p = project()                                  // [0, 9.7]
        p.split(at: 3); p.split(at: 6)                    // [0,3] [3,6] [6,9.7]
        let middle = p.clips[1]
        p.removeClip(id: middle.id)
        assertWellFormed(p)
        XCTAssertEqual(p.clips.map(\.start), [0, 6]); XCTAssertEqual(p.clips.map(\.end), [3, 9.7])
        XCTAssertEqual(p.clips.totalLength, 9.7 - 3, accuracy: 1e-12)
        XCTAssertEqual(p.clips.cutTimes, [3])
        // playback skips the hole: composition 3.0 is recording 6.0, the hole maps to where the next clip begins
        XCTAssertEqual(p.clips.recordingTime(2.999), 2.999, accuracy: 1e-12)
        XCTAssertEqual(p.clips.recordingTime(3), 6)
        XCTAssertEqual(p.clips.compositionTime(4.5), 3)
        XCTAssertNil(p.clips.index(containing: 4.5))
        // the last clip cannot be deleted
        p.removeClip(id: p.clips[0].id)
        p.removeClip(id: p.clips[0].id)
        XCTAssertEqual(p.clips.count, 1)
        // trim handles are clip edges, clamped to the neighbours
        var q = project()
        q.split(at: 3); q.split(at: 6); q.removeClip(id: q.clips[1].id)
        q.setClipEnd(id: q.clips[0].id, 8)
        XCTAssertEqual(q.clips[0].end, 6, "clamped to the next clip")
        q.setClipStart(id: q.clips[1].id, 1)
        XCTAssertEqual(q.clips[1].start, 6, "clamped to the previous clip")
        q.setClipStart(id: q.clips[1].id, 9.9)
        XCTAssertEqual(q.clips[1].length, q.minTrimLength, accuracy: 1e-12)
    }

    // MARK: mapping

    func testCompositionRecordingRoundTrip() {
        let clips = [ClipRange(start: 0.5, end: 2), ClipRange(start: 2, end: 3.25), ClipRange(start: 4, end: 7.1), ClipRange(start: 9, end: 9.6)]
        XCTAssertEqual(clips.totalLength, 1.5 + 1.25 + 3.1 + 0.6, accuracy: 1e-12)
        XCTAssertEqual(clips.compositionStarts, [0, 1.5, 2.75, 5.85], accuracy: 1e-12)
        XCTAssertEqual(clips.cutTimes, [2.75, 5.85], accuracy: 1e-12)
        XCTAssertEqual(clips.keptRanges.map(\.start), [0.5, 4, 9]); XCTAssertEqual(clips.keptRanges.map(\.end), [3.25, 7.1, 9.6])
        for i in 0...Int(clips.totalLength * 600) {
            let c = Double(i) / 600
            let r = clips.recordingTime(c)
            XCTAssertNotNil(clips.index(containing: r) ?? (c >= clips.totalLength - 1e-9 ? 0 : nil), "\(c) → \(r) is kept")
            XCTAssertEqual(clips.compositionTime(r), min(c, clips.totalLength), accuracy: 1e-9, "round trip at \(c)")
        }
        for r in stride(from: 0.0, through: 10, by: 0.01) {
            let c = clips.compositionTime(r)
            if clips.index(containing: r) != nil { XCTAssertEqual(clips.recordingTime(c), r, accuracy: 1e-9) }
        }
        // removed material maps to the next kept frame; before the first and after the last clip clamp
        XCTAssertEqual(clips.compositionTime(3.6), 2.75, accuracy: 1e-12)
        XCTAssertEqual(clips.compositionTime(0.1), 0)
        XCTAssertEqual(clips.compositionTime(9.9), clips.totalLength, accuracy: 1e-12)
        XCTAssertEqual(clips.recordingTime(-1), 0.5)
        XCTAssertEqual(clips.recordingTime(99), 9.6)
        // cut points show the next clip's first frame
        XCTAssertEqual(clips.recordingTime(2.75), 4, accuracy: 1e-12)
        XCTAssertEqual(clips.recordingTime(1.5), 2, accuracy: 1e-12)
        // play restarts from the start of the kept material on the last frame or past it
        XCTAssertEqual(clips.playStart(from: clips.totalLength), 0)
        XCTAssertEqual(clips.playStart(from: clips.totalLength - 1.0 / 60), 0)
        XCTAssertEqual(clips.playStart(from: clips.totalLength - 1.0 / 60 - 1e-5), 0, "a parked playhead after CMTime rounding")
        XCTAssertEqual(clips.playStart(from: clips.totalLength - 2.0 / 60), clips.totalLength - 2.0 / 60)
        XCTAssertEqual(clips.playStart(from: 3), 3)
    }

    // MARK: migration

    func testMigrationFromV1Trim() throws {
        let v1 = """
        {"clicks":[{"button":"left","t":3,"x":0.5,"y":0.5}],"cursor":[],"duration":12.0667,"keys":[],
         "name":"녹화 10월 1일 18.42.33","pixelHeight":3324,"pixelWidth":6016,"pointPixelScale":2,
         "trimIn":1.25,"trimOut":11.7667,"version":1,"videoFile":"recording.mov",
         "zooms":[{"end":4.5,"focus":{"x":0.5,"y":0.5},"id":"824B7703-A817-44F2-B7B0-4CD84494E318","isEnabled":true,"scale":2,"start":2.6}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(v1.utf8).write(to: url)
        let p = try Project.load(from: url)
        XCTAssertEqual(p.version, Project.currentVersion)
        XCTAssertEqual(p.clips.count, 1)
        XCTAssertEqual(p.clips[0].start, 1.25); XCTAssertEqual(p.clips[0].end, 11.7667)
        XCTAssertEqual(p.trimIn, 1.25); XCTAssertEqual(p.trimOut, 11.7667)
        XCTAssertEqual(p.zooms.count, 1)
        // saved back as version 2 with a cut list and no trimIn/trimOut, and it loads again unchanged
        try p.save(to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"clips\"")); XCTAssertFalse(json.contains("trimIn"))
        XCTAssertEqual(try Project.load(from: url), p)
    }

    /// Real version-1 files (copies), when LOUPECAST_V1_DIR points at them.
    func testRealV1FilesLoad() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOUPECAST_V1_DIR"] else { throw XCTSkip("LOUPECAST_V1_DIR not set") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let p = try Project.load(from: url)
            print("v1 \(f): version \(raw["version"]!) trim \(raw["trimIn"]!)…\(raw["trimOut"]!) → clips \(p.clips.map { "\($0.start)…\($0.end)" }) zooms \(p.zooms.count)")
            XCTAssertEqual(p.clips.count, 1)
            XCTAssertEqual(p.clips[0].start, raw["trimIn"] as! Double)
            XCTAssertEqual(p.clips[0].end, raw["trimOut"] as! Double)
        }
    }

    // MARK: zooms at cuts

    func testZoomClippingAtCuts() {
        let clips = [ClipRange(start: 1, end: 5), ClipRange(start: 6, end: 10)]   // cut at composition 4
        func path(_ s: Double, _ e: Double) -> CameraPath {
            CameraPath(segments: [ZoomSegment(start: s, end: e, focus: Point(x: 0.3, y: 0.3))], cursor: [], clips: clips)
        }
        // straddles the cut, far side removed → ends at the cut (eased out), nothing after it
        let ends = path(3, 5.5)
        XCTAssertEqual(ends.camera(at: 3.6).scale, 2, accuracy: 1e-9)
        XCTAssertEqual(ends.camera(at: 4.7).scale, 1.5, accuracy: 1e-9, "0.3 s before the cut: halfway out")
        XCTAssertEqual(ends.camera(at: 4.999).scale, 1, accuracy: 0.001)
        XCTAssertEqual(ends.camera(at: 6).scale, 1, "no zoom carried across the jump")
        XCTAssertEqual(ends.camera(at: 5.5).scale, 1, "removed material")
        // both sides of the cut inside the same segment → carried, fully zoomed through the cut
        let carried = path(3, 9)
        for t in [4.5, 4.99, 6, 6.2] { XCTAssertEqual(carried.camera(at: t).scale, 2, accuracy: 1e-9, "\(t)") }
        XCTAssertEqual(carried.camera(at: 8.7).scale, 1.5, accuracy: 1e-9)
        // starts in removed material → clipped, eases in from the cut
        let starts = path(5.5, 9)
        XCTAssertEqual(starts.camera(at: 6).scale, 1)
        XCTAssertEqual(starts.camera(at: 6.3).scale, 1.5, accuracy: 1e-9)
        // continuous in composition time across every cut
        for p in [ends, carried, starts] {
            var prev = p.camera(composition: 0), maxDS = 0.0
            for i in 1...(8 * 60) {
                let c = p.camera(at: clips.recordingTime(Double(i) / 60))
                maxDS = max(maxDS, abs(c.scale - prev.scale)); prev = c
            }
            XCTAssertLessThan(maxDS, 0.06)
        }
    }

    // MARK: undo

    final class Doc { var project: Project; init(_ p: Project) { project = p } }

    @MainActor
    func testUndoRestoresExactClipLists() {
        let doc = Doc(project())
        let undo = UndoManager()
        undo.groupsByEvent = false
        var history = [doc.project.clips]
        func edit(_ name: String, _ change: (inout Project) -> Void) {
            let before = doc.project
            change(&doc.project)
            undo.beginUndoGrouping()
            undo.registerChange(doc, \.project, before: before, name: name)
            undo.endUndoGrouping()
            history.append(doc.project.clips)
        }
        edit("자르기") { $0.split(at: 2.5) }
        edit("자르기") { $0.split(at: 7.25) }
        edit("클립 삭제") { $0.removeClip(id: $0.clips[1].id) }
        edit("다듬기") { $0.setClipEnd(id: $0.clips[0].id, 2.1) }
        edit("다듬기") { $0.setTrimIn(0.4) }
        edit("줌 추가") { _ = $0.addZoom(at: 1) }
        XCTAssertEqual(undo.undoActionName, "줌 추가")
        for expected in history.reversed().dropFirst() {
            undo.undo()
            XCTAssertEqual(doc.project.clips, expected, "exact clip list, ids included")
        }
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(doc.project, project().with(clips: history[0]))
        for expected in history.dropFirst() {
            undo.redo()
            XCTAssertEqual(doc.project.clips, expected)
        }
        XCTAssertEqual(doc.project.zooms.count, 1)
        XCTAssertFalse(undo.canRedo)
    }
}

private extension Project {
    func with(clips: [ClipRange]) -> Project { var p = self; p.clips = clips; return p }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
