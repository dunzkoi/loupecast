import Foundation

/// project.json next to the recording. Times are recording-relative seconds; no wall-clock or host time.
public struct Project: Codable, Sendable, Equatable {
    /// 2: ordered cut list `clips` replaces the single `trimIn`/`trimOut` range of version 1.
    public static let currentVersion = 2
    public static let fileName = "project.json"
    public static let stopTrim = 0.3          // drop the stop click from the tail
    public static let frameDuration = 1.0 / 60
    public static let cutFade = 0.010         // audio fade out/in at each cut

    public var version: Int
    public var name: String
    public var videoFile: String
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointPixelScale: Double
    public var cursor: [CursorSample]
    public var clicks: [ClickEvent]
    public var keys: [KeyEvent]
    /// Kept material in recording time: sorted, non-overlapping, never empty.
    public var clips: [ClipRange]
    public var zooms: [ZoomSegment]

    public init(name: String, videoFile: String = "recording.mov", duration: Double,
                pixelWidth: Int, pixelHeight: Int, pointPixelScale: Double,
                cursor: [CursorSample], clicks: [ClickEvent], keys: [KeyEvent]) {
        version = Self.currentVersion
        self.name = name; self.videoFile = videoFile; self.duration = duration
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.pointPixelScale = pointPixelScale
        self.cursor = cursor; self.clicks = clicks; self.keys = keys
        clips = [ClipRange(start: 0, end: max(0, duration - Self.stopTrim))]
        zooms = AutoZoom.segments(clicks: clicks, duration: duration)
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, videoFile, duration, pixelWidth, pixelHeight, pointPixelScale, cursor, clicks, keys, clips, zooms
    }
    private enum V1Keys: String, CodingKey { case trimIn, trimOut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        videoFile = try c.decode(String.self, forKey: .videoFile)
        duration = try c.decode(Double.self, forKey: .duration)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        pointPixelScale = try c.decode(Double.self, forKey: .pointPixelScale)
        cursor = try c.decode([CursorSample].self, forKey: .cursor)
        clicks = try c.decode([ClickEvent].self, forKey: .clicks)
        keys = try c.decode([KeyEvent].self, forKey: .keys)
        zooms = try c.decode([ZoomSegment].self, forKey: .zooms)
        if let clips = try c.decodeIfPresent([ClipRange].self, forKey: .clips) {
            self.clips = clips
        } else {                                // version 1: one trim range
            let v1 = try decoder.container(keyedBy: V1Keys.self)
            clips = [ClipRange(start: try v1.decode(Double.self, forKey: .trimIn), end: try v1.decode(Double.self, forKey: .trimOut))]
        }
    }

    public static func load(from url: URL) throws -> Project {
        var p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
        guard p.version <= currentVersion else { throw LoupecastError("지원하지 않는 프로젝트 버전입니다: \(p.version)") }
        p.version = currentVersion
        p.clips = p.clips.sanitized(duration: p.duration)
        return p
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Edit operations (pure, used by the editor UI)

    public var minTrimLength: Double { Self.frameDuration * 6 }
    /// Start of the kept material / end of it (single-range view of the cut list).
    public var trimIn: Double { clips.first?.start ?? 0 }
    public var trimOut: Double { clips.last?.end ?? duration }

    public mutating func setTrimIn(_ t: Double) { if let c = clips.first { setClipStart(id: c.id, t) } }
    public mutating func setTrimOut(_ t: Double) { if let c = clips.last { setClipEnd(id: c.id, t) } }

    /// Clip edges are trim handles, clamped to the neighbouring clips and a minimum length.
    public mutating func setClipStart(id: UUID, _ t: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].start = min(max(i > 0 ? clips[i - 1].end : 0, t), clips[i].end - minTrimLength)
    }

    public mutating func setClipEnd(id: UUID, _ t: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].end = max(min(i + 1 < clips.count ? clips[i + 1].start : duration, t), clips[i].start + minTrimLength)
    }

    /// Splits the clip under recording time `t`; ignored within 2 frames of a clip edge.
    /// The left part keeps the id; returns the right part's id.
    @discardableResult
    public mutating func split(at t: Double) -> UUID? {
        guard let i = clips.firstIndex(where: { t - $0.start > 2 * Self.frameDuration - 1e-9 && $0.end - t > 2 * Self.frameDuration - 1e-9 })
        else { return nil }
        let right = ClipRange(start: t, end: clips[i].end)
        clips[i].end = t
        clips.insert(right, at: i + 1)
        return right.id
    }

    /// The last clip stays: an empty cut list has nothing to export.
    public mutating func removeClip(id: UUID) {
        guard clips.count > 1 else { return }
        clips.removeAll { $0.id == id }
    }

    /// Where playback should start when the user presses play at recording time `current`.
    public func playStart(from current: Double) -> Double {
        clips.recordingTime(clips.playStart(from: clips.compositionTime(current)))
    }

    public mutating func addZoom(at t: Double, length: Double = 2) -> ZoomSegment {
        let start = min(max(0, t), max(0, duration - length))
        let focus = cursorAt(cursor.sorted { $0.t < $1.t }, t) ?? .center
        let seg = ZoomSegment(start: start, end: min(duration, start + length), focus: focus)
        zooms.append(seg)
        zooms.sort { $0.start < $1.start }
        return seg
    }

    public mutating func removeZoom(id: UUID) { zooms.removeAll { $0.id == id } }

    public mutating func setZoomEnabled(id: UUID, _ on: Bool) {
        if let i = zooms.firstIndex(where: { $0.id == id }) { zooms[i].isEnabled = on }
    }

    public static let minZoomLength = 0.2

    public mutating func setZoomStart(id: UUID, _ t: Double) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].start = min(max(0, t), zooms[i].end - Self.minZoomLength)
    }

    public mutating func setZoomEnd(id: UUID, _ t: Double) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].end = max(min(duration, t), zooms[i].start + Self.minZoomLength)
    }
}

// MARK: - Cut list: composition time ↔ recording time

/// Kept material in recording time. The composition plays the clips back to back.
public struct ClipRange: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public init(id: UUID = UUID(), start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
    public var length: Double { end - start }
}

/// The one mapping used by preview, timeline and export. Clips are half-open [start, end), so a cut
/// point in composition time shows the next clip's first frame.
public extension Array where Element == ClipRange {
    var totalLength: Double { reduce(0) { $0 + $1.length } }

    /// Composition time at which each clip begins.
    var compositionStarts: [Double] {
        var t = 0.0
        return map { c in defer { t += c.length }; return t }
    }

    /// Recording time shown at composition time `c` (clamped to the kept material).
    func recordingTime(_ c: Double) -> Double {
        guard let last else { return c }
        for (clip, s) in zip(self, compositionStarts) where c < s + clip.length { return clip.start + Swift.max(0, c - s) }
        return last.end
    }

    /// Composition time of recording time `r`; inside a removed range, where the next kept clip begins.
    func compositionTime(_ r: Double) -> Double {
        for (clip, s) in zip(self, compositionStarts) where r < clip.end { return s + Swift.max(0, r - clip.start) }
        return totalLength
    }

    /// Clip containing recording time `r` (half-open), nil inside a removed range.
    func index(containing r: Double) -> Int? { firstIndex { $0.start <= r && r < $0.end } }

    /// Play from `c`, or from the start once the playhead is on the last frame or past it (the half
    /// frame of slack absorbs CMTime rounding of a playhead parked there).
    func playStart(from c: Double) -> Double {
        totalLength - c < 1.5 * Project.frameDuration ? 0 : Swift.max(0, c)
    }

    /// Composition times where the recording jumps (cuts between non-adjacent clips).
    var cutTimes: [Double] {
        zip(zip(self, dropFirst()), compositionStarts.dropFirst()).compactMap { pair, s in pair.0.end < pair.1.start - 1e-9 ? s : nil }
    }

    /// Material actually kept: split points (adjacent clips) joined.
    var keptRanges: [ClipRange] {
        reduce(into: []) { out, c in
            if let l = out.last, abs(l.end - c.start) < 1e-9 { out[out.count - 1].end = c.end } else { out.append(c) }
        }
    }

    /// Sorted, inside [0, duration], no overlaps or empty clips; the full recording if nothing is left.
    func sanitized(duration: Double) -> [ClipRange] {
        var out: [ClipRange] = []
        for var c in sorted(by: { $0.start < $1.start }) {
            c.start = Swift.max(c.start, out.last?.end ?? 0, 0)
            c.end = Swift.min(c.end, duration)
            if c.end > c.start { out.append(c) }
        }
        return out.isEmpty ? [ClipRange(start: 0, end: duration)] : out
    }
}

/// Gain of the linear fade out/in around every cut at composition time `c` (1 away from cuts).
public func cutGain(at c: Double, cuts: [Double], fade: Double = Project.cutFade) -> Double {
    cuts.reduce(1) { min($0, min(1, abs(c - $1) / fade)) }
}

// MARK: - Undo

public extension UndoManager {
    /// One undo step that writes `before` back into `target[keyPath:]`; undoing registers the redo.
    @MainActor
    func registerChange<T: AnyObject, V>(_ target: T, _ keyPath: ReferenceWritableKeyPath<T, V>, before: V, name: String) {
        registerUndo(withTarget: target) { t in
            let after = t[keyPath: keyPath]
            t[keyPath: keyPath] = before
            self.registerChange(t, keyPath, before: after, name: name)
        }
        setActionName(name)
    }
}

// MARK: - Input log (host clock → recording-relative, normalized)

public struct DisplayBounds: Sendable, Equatable {
    /// Global display coordinates in points (CG space: top-left origin of the main display).
    public var x, y, width, height: Double
    /// Strip at the top of the display left out of the capture (menu bar / notch), in points.
    public var topInset: Double
    public init(x: Double, y: Double, width: Double, height: Double, topInset: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.topInset = min(max(0, topInset), height / 2)
    }

    /// Menu-bar height from NSScreen (frame.maxY − visibleFrame.maxY, bottom-left space) or the
    /// notch safe area, whichever is larger.
    public static func menuBarInset(frameMaxY: Double, visibleMaxY: Double, safeAreaTop: Double) -> Double {
        max(0, frameMaxY - visibleMaxY, safeAreaTop)
    }

    /// The recorded rect in display-local points, top-left origin (SCStreamConfiguration.sourceRect).
    public var captureRect: (x: Double, y: Double, width: Double, height: Double) {
        (0, topInset, width, height - topInset)
    }

    /// Output size: the capture rect at `scale`, rounded to even pixels for the encoder.
    public func pixelSize(scale: Double) -> (width: Int, height: Int) {
        (Int((width * scale).rounded()) & ~1, Int(((height - topInset) * scale).rounded()) & ~1)
    }

    /// Normalized 0–1 against the captured rect, top-left origin. Points are scale-independent,
    /// so Retina needs no extra factor.
    public func normalize(_ gx: Double, _ gy: Double) -> Point {
        Point(x: (gx - x) / width, y: (gy - y - topInset) / (height - topInset))
    }

    /// On this display at all, the excluded strip included.
    public func contains(_ gx: Double, _ gy: Double) -> Bool {
        (x...(x + width)).contains(gx) && (y...(y + height)).contains(gy)
    }
}

/// Raw events as captured: host-clock seconds (same clock as the SCStream sample buffers) and
/// global CG coordinates. Converted once, at stop, into project events.
public struct InputLog: Sendable {
    public struct Raw: Sendable {
        public enum Kind: Sendable { case move, click(ClickEvent.Button), key(UInt16) }
        public var host: Double
        public var gx: Double
        public var gy: Double
        public var kind: Kind
        public init(host: Double, gx: Double, gy: Double, kind: Kind) {
            self.host = host; self.gx = gx; self.gy = gy; self.kind = kind
        }
    }
    public var events: [Raw] = []
    public init() {}

    public mutating func append(_ e: Raw) { events.append(e) }

    /// Keeps only events inside [0, duration] of the session. Clicks off the display are dropped;
    /// clicks in its excluded menu-bar strip are clamped to the top edge of the recording.
    public func relativized(sessionStartHost: Double, duration: Double, display: DisplayBounds)
        -> (cursor: [CursorSample], clicks: [ClickEvent], keys: [KeyEvent]) {
        var cursor: [CursorSample] = [], clicks: [ClickEvent] = [], keys: [KeyEvent] = []
        for e in events.sorted(by: { $0.host < $1.host }) {
            let t = e.host - sessionStartHost
            guard t >= 0, t <= duration else { continue }
            let p = display.normalize(e.gx, e.gy)
            switch e.kind {
            case .move:
                cursor.append(CursorSample(t: t, x: clamp01(p.x), y: clamp01(p.y)))
            case .click(let b):
                if display.contains(e.gx, e.gy) { clicks.append(ClickEvent(t: t, x: clamp01(p.x), y: clamp01(p.y), button: b)) }
            case .key(let code):
                keys.append(KeyEvent(t: t, keyCode: code))
            }
        }
        return (cursor, clicks, keys)
    }
}

public struct LoupecastError: LocalizedError {
    public let errorDescription: String?
    public init(_ text: String) { errorDescription = text }
}
