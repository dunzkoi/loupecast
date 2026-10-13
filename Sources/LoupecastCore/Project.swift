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
    /// Always empty: key presses are not recorded. Written only because apps up to 0.7 fail to open a file without it;
    /// the values in older files are never read.
    private let keys: [Int] = []
    /// Kept material in recording time: sorted, non-overlapping, never empty.
    public var clips: [ClipRange]
    public var zooms: [ZoomSegment]
    /// Output frame; files without it (older versions) are 16:9.
    public var aspect = AspectRatio.landscape
    /// Background around the recording; files without it get the pastel gradient every version had.
    public var style = StylePreset.pastel
    /// 9:16 and 1:1: crop the recording to fill the frame, following the cursor. Off in older files.
    public var fill = false
    /// 16:9 never fills (the switch is hidden there), so a fill set in 9:16 stays put when switching back.
    public var fillsFrame: Bool { fill && aspect != .landscape }
    /// Gain of the computer-audio and microphone tracks (0 mutes, 2 doubles); 1 in older files.
    public var systemVolume = 1.0
    public var micVolume = 1.0
    public static let volumes = 0.0...2.0
    /// The webcam recorded next to the screen; nil without one (and in older files).
    public var camera: CameraOverlay?

    /// `paused`: recording-time ranges the recording was paused for. They start out cut, and the clicks and cursor
    /// samples in them are dropped, so the editor opens with the pauses already gone.
    public init(name: String, videoFile: String = "recording.mov", duration: Double,
                pixelWidth: Int, pixelHeight: Int, pointPixelScale: Double,
                cursor: [CursorSample], clicks: [ClickEvent], paused: [ClipRange] = []) {
        version = Self.currentVersion
        self.name = name; self.videoFile = videoFile; self.duration = duration
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.pointPixelScale = pointPixelScale
        let live = { (t: Double) in !paused.contains { $0.start <= t && t < $0.end } }
        self.cursor = cursor.filter { live($0.t) }; self.clicks = clicks.filter { live($0.t) }
        clips = [ClipRange].excluding(paused, from: 0, to: max(0, duration - Self.stopTrim))
        zooms = AutoZoom.segments(clicks: self.clicks, duration: duration)
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, videoFile, duration, pixelWidth, pixelHeight, pointPixelScale, cursor, clicks, keys, clips, zooms, aspect, style, fill, systemVolume, micVolume, camera
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
        zooms = try c.decode([ZoomSegment].self, forKey: .zooms)
        aspect = try c.decodeIfPresent(AspectRatio.self, forKey: .aspect) ?? .landscape
        style = try c.decodeIfPresent(StylePreset.self, forKey: .style) ?? .pastel
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? false
        systemVolume = Self.volumes.clamp(try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1)
        micVolume = Self.volumes.clamp(try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1)
        camera = try c.decodeIfPresent(CameraOverlay.self, forKey: .camera)
        if let clips = try c.decodeIfPresent([ClipRange].self, forKey: .clips) {
            self.clips = clips
        } else {                                // version 1: one trim range
            let v1 = try decoder.container(keyedBy: V1Keys.self)
            clips = [ClipRange(start: try v1.decode(Double.self, forKey: .trimIn), end: try v1.decode(Double.self, forKey: .trimOut))]
        }
    }

    public static func load(from url: URL) throws -> Project {
        var p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
        guard p.version <= currentVersion else { throw LoupecastError("Unsupported project version: \(p.version)") }
        p.version = currentVersion
        p.clips = p.clips.sanitized(duration: p.duration)
        return p
    }

    /// Compact: an hour of 60 Hz cursor samples is ~20 MB, and indentation made it larger and slower to write.
    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
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
        let right = ClipRange(start: t, end: clips[i].end, speed: clips[i].speed)
        clips[i].end = t
        clips.insert(right, at: i + 1)
        return right.id
    }

    /// The speeds the editor offers.
    public static let clipSpeeds = [1.0, 2, 4]

    /// Plays the clip 2 or 4 times as fast (1 is normal speed).
    public mutating func setClipSpeed(id: UUID, _ speed: Double) {
        if let i = clips.firstIndex(where: { $0.id == id }) { clips[i].speed = ClipRange.speeds.clamp(speed) }
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

    public mutating func addZoom(at t: Double, length: Double = 2, scale: Double = AutoZoom.defaultScale) -> ZoomSegment {
        let start = min(max(0, t), max(0, duration - length))
        let focus = cursorAt(cursor.sorted { $0.t < $1.t }, t) ?? .center
        let seg = ZoomSegment(start: start, end: min(duration, start + length), scale: Self.zoomScales.clamp(scale), focus: focus)
        zooms.append(seg)
        zooms.sort { $0.start < $1.start }
        return seg
    }

    public mutating func removeZoom(id: UUID) { zooms.removeAll { $0.id == id } }

    public mutating func setZoomEnabled(id: UUID, _ on: Bool) {
        if let i = zooms.firstIndex(where: { $0.id == id }) { zooms[i].isEnabled = on }
    }

    public static let minZoomLength = 0.2
    /// How far a zoom may magnify: below 1.25 it barely shows, past 4 the recording turns to mush.
    public static let zoomScales = 1.25...4.0

    /// A focus picked on the preview: the zoom stops following the cursor and holds there.
    public mutating func setZoomFocus(id: UUID, _ p: Point) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].focus = Point(x: clamp01(p.x), y: clamp01(p.y))
        zooms[i].followsCursor = false
    }

    public mutating func setZoomFollowsCursor(id: UUID, _ on: Bool) {
        if let i = zooms.firstIndex(where: { $0.id == id }) { zooms[i].followsCursor = on }
    }

    public mutating func setZoomScale(id: UUID, _ scale: Double) {
        if let i = zooms.firstIndex(where: { $0.id == id }) { zooms[i].scale = Self.zoomScales.clamp(scale) }
    }

    public mutating func setZoomStart(id: UUID, _ t: Double) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].start = min(max(0, t), zooms[i].end - Self.minZoomLength)
    }

    public mutating func setZoomEnd(id: UUID, _ t: Double) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].end = max(min(duration, t), zooms[i].start + Self.minZoomLength)
    }
}

/// Export and preview frame. Pixel sizes keep the long side at 1920 and the short one at 1080.
public enum AspectRatio: String, Codable, CaseIterable, Sendable {
    case landscape = "16:9", portrait = "9:16", square = "1:1"
    public var pixels: (width: Int, height: Int) {
        switch self {
        case .landscape: (1920, 1080)
        case .portrait: (1080, 1920)
        case .square: (1080, 1080)
        }
    }
}

/// The webcam as a circle in a corner of the frame, fixed whatever the zoom does.
public struct CameraOverlay: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public var file = "camera.mov"
    /// Recording time (s) at which the camera movie's first frame was taken: both clocks are the host clock.
    public var offset: Double
    public var isVisible = true
    public var corner = Corner.bottomRight
    /// Circle diameter as a share of the canvas's short side.
    public var size = 0.28
    public static let sizes = [0.2, 0.28, 0.38]
    public init(offset: Double) { self.offset = offset }
}

/// Named looks for the frame around the recording (colors and sizes live in LoupecastRender's FrameStyle).
public enum StylePreset: String, Codable, CaseIterable, Sendable {
    case pastel, dark, light, graphite, blue
    /// Recording edge to edge: no padding, square corners, no shadow, black where the aspects differ.
    case plain
}

// MARK: - Cut list: composition time ↔ recording time

/// Kept material in recording time. The composition plays the clips back to back, each at its speed.
public struct ClipRange: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    /// 1, 2 or 4: how many seconds of recording one second of the composition plays. 1 in older files.
    public var speed: Double
    public static let speeds = 1.0...4.0
    public init(id: UUID = UUID(), start: Double, end: Double, speed: Double = 1) {
        self.id = id; self.start = start; self.end = end; self.speed = speed
    }
    /// Recording time the clip covers.
    public var length: Double { end - start }
    /// Composition time it plays for.
    public var playLength: Double { length / speed }

    private enum CodingKeys: String, CodingKey { case id, start, end, speed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), start: try c.decode(Double.self, forKey: .start),
                  end: try c.decode(Double.self, forKey: .end), speed: Self.speeds.clamp(try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1))
    }
}

/// The one mapping used by preview, timeline and export. Clips are half-open [start, end), so a cut
/// point in composition time shows the next clip's first frame.
public extension Array where Element == ClipRange {
    var totalLength: Double { reduce(0) { $0 + $1.playLength } }

    /// Composition time at which each clip begins.
    var compositionStarts: [Double] {
        var t = 0.0
        return map { c in defer { t += c.playLength }; return t }
    }

    /// Recording time shown at composition time `c` (clamped to the kept material). Called per camera-path
    /// step, so the clip starts are summed on the way instead of allocated (same sums as `compositionStarts`).
    func recordingTime(_ c: Double) -> Double {
        guard let last else { return c }
        var s = 0.0
        for clip in self {
            if c < s + clip.playLength { return clip.start + Swift.max(0, c - s) * clip.speed }
            s += clip.playLength
        }
        return last.end
    }

    /// Composition time of recording time `r`; inside a removed range, where the next kept clip begins.
    func compositionTime(_ r: Double) -> Double {
        var s = 0.0
        for clip in self {
            if r < clip.end { return s + Swift.max(0, r - clip.start) / clip.speed }
            s += clip.playLength
        }
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

    /// Material actually kept: split points (adjacent clips at the same speed) joined.
    var keptRanges: [ClipRange] {
        reduce(into: []) { out, c in
            if let l = out.last, abs(l.end - c.start) < 1e-9, l.speed == c.speed { out[out.count - 1].end = c.end } else { out.append(c) }
        }
    }

    /// [start, end] without `gaps`; pieces of a frame or less are dropped, and if nothing is left, the whole range.
    static func excluding(_ gaps: [ClipRange], from start: Double, to end: Double) -> [ClipRange] {
        var out: [ClipRange] = [], t = start
        for g in gaps.sorted(by: { $0.start < $1.start }) where g.end > t {
            if g.start > t { out.append(ClipRange(start: t, end: Swift.min(g.start, end))) }
            t = Swift.max(t, g.end)
        }
        if t < end { out.append(ClipRange(start: t, end: end)) }
        out.removeAll { $0.length <= Project.frameDuration }
        return out.isEmpty ? [ClipRange(start: start, end: end)] : out
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

/// A rect in points, top-left origin.
public struct Rect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct DisplayBounds: Sendable, Equatable {
    /// Global display coordinates in points (CG space: top-left origin of the main display).
    public var x, y, width, height: Double
    /// Strip at the top of the display left out of the capture (menu bar / notch), in points.
    public var topInset: Double
    /// Area recording: the recorded rect in display-local points (top-left origin), inside the display. Clicks
    /// outside it make no zoom; `topInset` is ignored.
    public var area: Rect?
    public init(x: Double, y: Double, width: Double, height: Double, topInset: Double = 0, area: Rect? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.topInset = min(max(0, topInset), height / 2)
        self.area = area.flatMap { a in
            let x0 = max(0, a.x), y0 = max(0, a.y), x1 = min(width, a.x + a.width), y1 = min(height, a.y + a.height)
            return x1 > x0 && y1 > y0 ? Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : nil
        }
    }

    /// Menu-bar height from NSScreen (frame.maxY − visibleFrame.maxY, bottom-left space) or the
    /// notch safe area, whichever is larger.
    public static func menuBarInset(frameMaxY: Double, visibleMaxY: Double, safeAreaTop: Double) -> Double {
        max(0, frameMaxY - visibleMaxY, safeAreaTop)
    }

    /// The recorded rect in display-local points, top-left origin (SCStreamConfiguration.sourceRect).
    public var captureRect: (x: Double, y: Double, width: Double, height: Double) {
        if let area { return (area.x, area.y, area.width, area.height) }
        return (0, topInset, width, height - topInset)
    }

    /// Output size: the capture rect at `scale`, rounded to even pixels for the encoder.
    public func pixelSize(scale: Double) -> (width: Int, height: Int) {
        let r = captureRect
        return (Int((r.width * scale).rounded()) & ~1, Int((r.height * scale).rounded()) & ~1)
    }

    /// Normalized 0–1 against the captured rect, top-left origin. Points are scale-independent,
    /// so Retina needs no extra factor.
    public func normalize(_ gx: Double, _ gy: Double) -> Point {
        let r = captureRect
        return Point(x: (gx - x - r.x) / r.width, y: (gy - y - r.y) / r.height)
    }

    /// Where a click can make a zoom: the recorded area, or anywhere on the display (the excluded menu-bar strip
    /// included: those clicks are clamped to the top edge).
    public func contains(_ gx: Double, _ gy: Double) -> Bool {
        let r = area ?? Rect(x: 0, y: 0, width: width, height: height)
        return ((x + r.x)...(x + r.x + r.width)).contains(gx) && ((y + r.y)...(y + r.y + r.height)).contains(gy)
    }
}

/// Raw events as captured: host-clock seconds (same clock as the SCStream sample buffers) and
/// global CG coordinates. Converted once, at stop, into project events.
public struct InputLog: Sendable {
    public struct Raw: Sendable {
        public enum Kind: Sendable { case move, click(ClickEvent.Button) }
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

    /// Keeps only events inside [0, duration] of the session. Clicks off the display (or outside a recorded area) are
    /// dropped; clicks in its excluded menu-bar strip are clamped to the top edge of the recording.
    public func relativized(sessionStartHost: Double, duration: Double, display: DisplayBounds)
        -> (cursor: [CursorSample], clicks: [ClickEvent]) {
        var cursor: [CursorSample] = [], clicks: [ClickEvent] = []
        for e in events.sorted(by: { $0.host < $1.host }) {
            let t = e.host - sessionStartHost
            guard t >= 0, t <= duration else { continue }
            let p = display.normalize(e.gx, e.gy)
            switch e.kind {
            case .move:
                cursor.append(CursorSample(t: t, x: clamp01(p.x), y: clamp01(p.y)))
            case .click(let b):
                if display.contains(e.gx, e.gy) { clicks.append(ClickEvent(t: t, x: clamp01(p.x), y: clamp01(p.y), button: b)) }
            }
        }
        return (cursor, clicks)
    }
}

public extension ClosedRange where Bound == Double {
    func clamp(_ v: Double) -> Double { Swift.min(upperBound, Swift.max(lowerBound, v)) }
}

/// Looked up in the app bundle's Localizable.strings (English when there is no translation).
public struct LoupecastError: LocalizedError {
    public let errorDescription: String?
    public init(_ text: String.LocalizationValue) { errorDescription = String(localized: text) }
}
