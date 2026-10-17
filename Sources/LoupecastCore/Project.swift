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
    /// The user typed the name (Rename): exports are named after it. Off in older files and new recordings.
    public var renamed = false
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
    /// A picture in the recording folder shown instead of the preset's colors (blurred a little, filling the canvas);
    /// never with `.plain`. Nil in older files.
    public var backgroundImage: String?
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
    /// A ring spreads from every click for 0.4 s (on in older files too).
    public var showClicks = true
    /// Zooms and pans blur in the direction they move. Off in older files (their export stays the same); the recorder
    /// turns it on for new recordings.
    public var motionBlur = false
    /// The cursor the compositor draws (new recordings leave it out of the video); nil: it is in the video, as in older files.
    public var cursorOverlay: CursorOverlay?
    /// Key combinations pressed with ⌘, ⌃ or ⌥ (only when 단축키 표시 was on while recording), shown as a badge.
    public var shortcuts: [Shortcut] = []
    public var showShortcuts = true
    /// Stretches of typing (when 타이핑 구간 확대 was on): only where each started and ended, never a key or its time.
    public var typing: [TypingSpan] = []
    /// The microphone transcribed on this Mac (자막 만들기), in recording time.
    public var captions: [Caption] = []
    /// The caption lines are drawn at the bottom of the video (preview and export); on in older files, which have none.
    public var showCaptions = true

    /// `paused`: recording-time ranges the recording was paused for. They start out cut, and the clicks and cursor
    /// samples in them are dropped, so the editor opens with the pauses already gone.
    public init(name: String, videoFile: String = "recording.mov", duration: Double,
                pixelWidth: Int, pixelHeight: Int, pointPixelScale: Double,
                cursor: [CursorSample], clicks: [ClickEvent], shortcuts: [Shortcut] = [], typing: [TypingSpan] = [],
                paused: [ClipRange] = []) {
        version = Self.currentVersion
        self.name = name; self.videoFile = videoFile; self.duration = duration
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.pointPixelScale = pointPixelScale
        let live = { (t: Double) in !paused.contains { $0.start <= t && t < $0.end } }
        self.cursor = cursor.filter { live($0.t) }; self.clicks = clicks.filter { live($0.t) }
        self.shortcuts = shortcuts.filter { live($0.t) }
        self.typing = typing.filter { live($0.start) }
        clips = [ClipRange].excluding(paused, from: 0, to: max(0, duration - Self.stopTrim))
        zooms = AutoZoom.segments(clicks: self.clicks, typing: self.typing, duration: duration)
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, renamed, videoFile, duration, pixelWidth, pixelHeight, pointPixelScale, cursor, clicks, keys, clips, zooms, aspect, style, backgroundImage, fill, systemVolume, micVolume, camera, showClicks, motionBlur, cursorOverlay, shortcuts, showShortcuts, typing, captions, showCaptions
    }
    private enum V1Keys: String, CodingKey { case trimIn, trimOut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        renamed = try c.decodeIfPresent(Bool.self, forKey: .renamed) ?? false
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
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? false
        systemVolume = Self.volumes.clamp(try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1)
        micVolume = Self.volumes.clamp(try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1)
        camera = try c.decodeIfPresent(CameraOverlay.self, forKey: .camera)
        showClicks = try c.decodeIfPresent(Bool.self, forKey: .showClicks) ?? true
        motionBlur = try c.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? false
        cursorOverlay = try c.decodeIfPresent(CursorOverlay.self, forKey: .cursorOverlay)
        shortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
        showShortcuts = try c.decodeIfPresent(Bool.self, forKey: .showShortcuts) ?? true
        typing = try c.decodeIfPresent([TypingSpan].self, forKey: .typing) ?? []
        captions = try c.decodeIfPresent([Caption].self, forKey: .captions) ?? []
        showCaptions = try c.decodeIfPresent(Bool.self, forKey: .showCaptions) ?? true
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
        // a shared recording must not make the app read (and export) a file from elsewhere on the disk
        let folder = url.deletingLastPathComponent()
        guard isLocal(p.videoFile, in: folder) else { throw LoupecastError("The project names a file outside its folder.") }
        if let b = p.backgroundImage, !isLocal(b, in: folder) { p.backgroundImage = nil }
        if let c = p.camera, !isLocal(c.file, in: folder) { p.camera = nil }
        if let o = p.cursorOverlay, !o.images.allSatisfy({ isLocal($0.file, in: folder) }) { p.cursorOverlay = nil }
        p.version = currentVersion
        p.clips = p.clips.sanitized(duration: p.duration)
        return p
    }

    /// A file name from project.json that stays inside the recording folder: relative, no `..`, and no symbolic link on
    /// the way (the app never makes one there).
    static func isLocal(_ name: String, in folder: URL) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), !name.split(separator: "/").contains("..") else { return false }
        var url = folder
        for part in name.split(separator: "/") {
            url.appendPathComponent(String(part))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return false }
        }
        return true
    }

    /// Compact: an hour of 60 Hz cursor samples is ~20 MB, and indentation made it larger and slower to write.
    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Edit operations (pure, used by the editor UI)

    /// A blank name keeps the current one.
    public mutating func rename(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != name else { return }
        name = t
        renamed = true
    }

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

    /// 빈 구간 빠르게: recording-time stretches with no cursor movement (0.002 or more), click, shortcut, typing or `speech`
    /// for 3 s or more, each 0.3 s short of the activity around it; the recording's start and end bound them.
    public func idleStretches(speech: [ClipRange]) -> [ClipRange] {
        let gap = 3.0, margin = 0.3
        var busy = clicks.map { ($0.t, $0.t) } + shortcuts.map { ($0.t, $0.t) } + typing.map { ($0.start, $0.end) } + speech.map { ($0.start, $0.end) }
        var anchor: CursorSample?                     // where the cursor was when it last moved
        for s in cursor.sorted(by: { $0.t < $1.t }) {
            if let a = anchor, hypot(s.x - a.x, s.y - a.y) < CursorOverlay.still { continue }
            if anchor != nil { busy.append((s.t, s.t)) }
            anchor = s
        }
        var out: [ClipRange] = [], free = 0.0
        for (start, end) in busy.sorted(by: { $0.0 < $1.0 }) + [(duration, duration)] {
            if start - free >= gap { out.append(ClipRange(start: free + margin, end: start - margin)) }
            free = Swift.max(free, end)
        }
        return out
    }

    /// Plays the kept material inside `stretches` (recording time) at 4×, split off at their edges as `split` would.
    /// Returns how many stretches changed.
    public mutating func speedUp(_ stretches: [ClipRange]) -> Int {
        let slack = 2 * Self.frameDuration + 1e-9                  // split leaves a clip edge this close alone
        var changed = 0
        for s in stretches {
            split(at: s.start); split(at: s.end)
            let inside = clips.filter { $0.start >= s.start - slack && $0.end <= s.end + slack && $0.speed != 4 }
            inside.forEach { setClipSpeed(id: $0.id, 4) }
            if !inside.isEmpty { changed += 1 }
        }
        return changed
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

/// The look picked last in an editor: new recordings start with it, opened ones keep their own.
public struct LookDefaults: Codable, Equatable, Sendable {
    public var aspect: AspectRatio
    public var style: StylePreset
    public var fill: Bool
    /// From the last project with a webcam; applied only to recordings with one.
    public var cameraCorner: CameraOverlay.Corner?
    public var cameraSize: Double?
    /// Optional: looks saved before these switches existed decode without them.
    public var showClicks: Bool?
    public var motionBlur: Bool?
    /// From the last project with a drawn cursor; applied only to recordings with one.
    public var cursorScale: Double?
    public var cursorSmooth: Bool?
    public var cursorHidesIdle: Bool?
    public var cursorPresses: Bool?

    /// `p`'s look; the camera's from `previous` when `p` has no webcam.
    public init(_ p: Project, previous: LookDefaults? = nil) {
        aspect = p.aspect; style = p.style; fill = p.fill; showClicks = p.showClicks; motionBlur = p.motionBlur
        cursorScale = p.cursorOverlay?.scale ?? previous?.cursorScale
        cursorSmooth = p.cursorOverlay?.smooth ?? previous?.cursorSmooth
        cursorHidesIdle = p.cursorOverlay?.hideIdle ?? previous?.cursorHidesIdle
        cursorPresses = p.cursorOverlay?.clickPress ?? previous?.cursorPresses
        cameraCorner = p.camera?.corner ?? previous?.cameraCorner
        cameraSize = p.camera?.size ?? previous?.cameraSize
    }

    public func apply(to p: inout Project) {
        p.aspect = aspect; p.style = style; p.fill = fill
        if let showClicks { p.showClicks = showClicks }
        if let motionBlur { p.motionBlur = motionBlur }
        if let cursorScale { p.cursorOverlay?.scale = cursorScale }
        if let cursorSmooth { p.cursorOverlay?.smooth = cursorSmooth }
        if let cursorHidesIdle { p.cursorOverlay?.hideIdle = cursorHidesIdle }
        if let cursorPresses { p.cursorOverlay?.clickPress = cursorPresses }
        if let cameraCorner { p.camera?.corner = cameraCorner }
        if let cameraSize { p.camera?.size = cameraSize }
    }
}

/// The cursor as the recorder saw it: its shapes as PNGs in the recording folder, and when each one was showing.
/// The compositor draws it at the cursor samples' position, larger and spring-smoothed if asked.
public struct CursorOverlay: Codable, Equatable, Sendable {
    public struct Image: Codable, Equatable, Sendable {
        /// Relative to the recording folder, e.g. "cursors/0.png".
        public var file: String
        /// Size and hot spot in points; the hot spot is measured from the top-left corner.
        public var width, height, hotX, hotY: Double
        public init(file: String, width: Double, height: Double, hotX: Double, hotY: Double) {
            self.file = file; self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY
        }
    }
    /// From recording time `t` on, `images[image]` is showing.
    public struct Shape: Codable, Equatable, Sendable {
        public var t: Double
        public var image: Int
        public init(t: Double, image: Int) { self.t = t; self.image = image }
    }
    public var images: [Image]
    /// Sorted by time.
    public var shapes: [Shape]
    /// Drawn this many times its size (the zoom enlarges it on top of that).
    public var scale = 1.0
    public static let scales = [1.0, 1.5, 2.0]
    /// Spring-smoothed position (the zoom's spring) instead of the raw samples.
    public var smooth = true
    /// Fades out while the cursor rests (`idleAlpha`); shrinks a little at each click (`pressScale`). Off in older files, on
    /// for new recordings.
    public var hideIdle = false
    public var clickPress = false

    public init(images: [Image], shapes: [Shape]) { self.images = images; self.shapes = shapes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        images = try c.decode([Image].self, forKey: .images)
        shapes = try c.decode([Shape].self, forKey: .shapes)
        scale = try c.decode(Double.self, forKey: .scale)
        smooth = try c.decode(Bool.self, forKey: .smooth)
        hideIdle = try c.decodeIfPresent(Bool.self, forKey: .hideIdle) ?? false
        clickPress = try c.decodeIfPresent(Bool.self, forKey: .clickPress) ?? false
    }

    /// Still: within 0.002 of where it is now (normalized). Hidden 1.5 s into a rest, after a 0.3 s fade; back over 0.15 s.
    static let still = 0.002, rest = 1.5, fadeOut = 0.3, fadeIn = 0.15

    /// How opaque Hide Idle Cursor draws the cursor at recording time `t`: 1 while it moves, fading to 0 once it has rested
    /// 1.5 s, and back to 1 over 0.15 s after it moves again or a click. A pure function of `t` (the samples and click times,
    /// both sorted), like the fade-out cut short by a move rising from where it got to. The recording's start counts as a
    /// move.
    public static func idleAlpha(_ cursor: [CursorSample], clicks: [Double], at t: Double) -> Double {
        // the fade-out alone jumps back to 1 on a move; rising at most 1/0.15 per second, the alpha is the lowest of these
        var alpha = shown(cursor, clicks, at: t)
        let moments = cursor[cursor.firstIndex(after: t - fadeIn)..<cursor.firstIndex(after: t)].map(\.t) + clicks.filter { t - fadeIn < $0 && $0 <= t }
        for s in moments { alpha = min(alpha, shown(cursor, clicks, at: s) + (t - s) / fadeIn) }
        return alpha
    }

    /// The fade-out: 1 until the cursor has rested `rest` seconds (no click before `t` in that time), 0 after `fadeOut` more.
    static func shown(_ cursor: [CursorSample], _ clicks: [Double], at t: Double) -> Double {
        var since = Swift.max(0, t - rest - fadeOut, clicks.last { $0 < t } ?? 0)
        if let here = cursorAt(cursor, t) {
            var i = cursor.firstIndex(after: t) - 1
            while i >= 0, cursor[i].t > since {
                if hypot(cursor[i].x - here.x, cursor[i].y - here.y) >= still { since = cursor[i].t; break }
                i -= 1
            }
        }
        return 1 - clamp01((t - since - rest) / fadeOut + 1e-9)            // the nudge makes a full rest exactly 0
    }

    static let pressLength = 0.2

    /// Press Cursor on Click: the cursor's size at recording time `t`, 0.8 at a click, eased down over the 0.2 s before it
    /// and springing back (a slight overshoot) over the 0.2 s after.
    public static func pressScale(clicks: [Double], at t: Double) -> Double {
        let press = clicks.filter { abs(t - $0) < pressLength }.reduce(0.0) { sum, c in
            let u = (t - c) / pressLength
            return sum + (u < 0 ? smootherstep(1 + u) : (1 - u) * (1 - u) * cos(1.5 * .pi * u))
        }
        return (0.8...1.05).clamp(1 - 0.2 * press)
    }

    /// The shape at recording time `t` (the first one before any change).
    public func image(at t: Double) -> Image? {
        let i = shapes.last { $0.t <= t }?.image ?? shapes.first?.image ?? 0
        return images.indices.contains(i) ? images[i] : nil
    }
}

/// A line of transcribed speech, in recording time.
public struct Caption: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }

    /// Recognized words (recording time) as subtitle lines: a line ends after a sentence's last word, before a pause of
    /// 0.6 s or more, or once it reaches 42 characters or 6 s.
    public static func lines(_ words: [(start: Double, end: Double, text: String)]) -> [Caption] {
        var out: [Caption] = [], line: Caption?
        for (i, w) in words.enumerated() {
            let text = line.map { $0.text + (w.text.first.map { ",.?!，。？！".contains($0) } == true ? "" : " ") + w.text } ?? w.text
            line = Caption(start: line?.start ?? w.start, end: w.end, text: text)
            let next = i + 1 < words.count ? words[i + 1] : nil
            let sentence = w.text.last.map { ".?!。？！".contains($0) } ?? false
            if next == nil || sentence || next!.start - w.end >= 0.6 || text.count >= 42 || w.end - line!.start >= 6 {
                out.append(line!)
                line = nil
            }
        }
        return out
    }
}

public extension Array where Element == Caption {
    /// Each line at its composition time (cuts and speed applied), as the video and the SRT show it. A line cut in part
    /// keeps what is left, one in removed material is dropped.
    func timed(clips: [ClipRange]) -> [(start: Double, end: Double, text: String)] {
        compactMap { c in
            let a = clips.compositionTime(c.start), b = clips.compositionTime(c.end)
            return b - a > Project.frameDuration ? (a, b, c.text) : nil
        }
    }

    /// SubRip text for the edit.
    func srt(clips: [ClipRange]) -> String {
        func time(_ s: Double) -> String {
            let ms = Int((s * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return timed(clips: clips).enumerated().map { "\($0.offset + 1)\n\(time($0.element.start)) --> \(time($0.element.end))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }
}

/// Keys typed less than 0.8 s apart, from the first to the last (recording time), and where the text went (the caret or
/// the focused field, else the last click; normalized like clicks).
public struct TypingSpan: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var focus: Point
    public init(start: Double, end: Double, focus: Point) { self.start = start; self.end = end; self.focus = focus }
    public static let gap = 0.8
}

/// A key combination as the video shows it ("⌘ ⇧ S"), at recording time `t`.
public struct Shortcut: Codable, Equatable, Sendable {
    public var t: Double
    public var label: String
    public init(t: Double, label: String) { self.t = t; self.label = label }

    /// ⌃ ⌥ ⇧ ⌘ in the order macOS menus write them, then the key.
    public static func label(_ m: KeyModifiers, _ key: String) -> String {
        ([(KeyModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { m.contains($0.0) }.map(\.1) + [key])
            .joined(separator: " ")
    }
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1), option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4), command = KeyModifiers(rawValue: 8)
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

    /// What is cut out before the first clip and between clips (not after the last).
    var gaps: [ClipRange] {
        zip([0] + map(\.end), map(\.start)).filter { $1 > $0 }.map { ClipRange(start: $0, end: $1) }
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

    /// A window on screen as CGWindowListCopyWindowInfo lists it: global bounds in points, layer, owning process.
    public struct Window: Sendable, Equatable {
        public var bounds: Rect
        public var layer: Int
        public var owner: Int32
        public init(bounds: Rect, layer: Int, owner: Int32) { self.bounds = bounds; self.layer = layer; self.owner = owner }
    }

    /// The area to record for a click at global point (gx, gy): the frontmost normal window (layer 0, not `excluding`'s)
    /// there, cut to this display, in display-local points (top-left origin). `windows` is front to back.
    public func windowArea(at gx: Double, _ gy: Double, windows: [Window], excluding owner: Int32) -> Rect? {
        guard let w = windows.first(where: { w in
            w.layer == 0 && w.owner != owner && (w.bounds.x...(w.bounds.x + w.bounds.width)).contains(gx) && (w.bounds.y...(w.bounds.y + w.bounds.height)).contains(gy)
        }) else { return nil }
        let x0 = max(0, w.bounds.x - x), y0 = max(0, w.bounds.y - y)
        let x1 = min(width, w.bounds.x + w.bounds.width - x), y1 = min(height, w.bounds.y + w.bounds.height - y)
        return x1 > x0 && y1 > y0 ? Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : nil
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
        public enum Kind: Sendable { case move, click(ClickEvent.Button), shortcut(String), typing(untilHost: Double) }
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

    /// A key press: kept only with ⌘ or ⌃ held, or ⌥ on a key that types nothing (an arrow, Return…). Everything that
    /// types text, ⇧ and ⌥ letters (é, @ on many layouts) included, is dropped here and never stored.
    public mutating func appendKey(host: Double, modifiers: KeyModifiers, key: String, typesText: Bool) {
        guard !modifiers.isDisjoint(with: [.command, .control]) || (modifiers.contains(.option) && !typesText) else { return }
        events.append(.init(host: host, gx: 0, gy: 0, kind: .shortcut(Shortcut.label(modifiers, key))))
    }

    /// Keeps only events inside [0, duration] of the session. Clicks off the display (or outside a recorded area) are
    /// dropped; clicks in its excluded menu-bar strip are clamped to the top edge of the recording.
    public func relativized(sessionStartHost: Double, duration: Double, display: DisplayBounds)
        -> (cursor: [CursorSample], clicks: [ClickEvent], shortcuts: [Shortcut], typing: [TypingSpan]) {
        var cursor: [CursorSample] = [], clicks: [ClickEvent] = [], shortcuts: [Shortcut] = [], typing: [TypingSpan] = []
        for e in events.sorted(by: { $0.host < $1.host }) {
            let t = e.host - sessionStartHost
            guard t >= 0, t <= duration else { continue }
            let p = display.normalize(e.gx, e.gy)
            switch e.kind {
            case .move:
                cursor.append(CursorSample(t: t, x: clamp01(p.x), y: clamp01(p.y)))
            case .click(let b):
                if display.contains(e.gx, e.gy) { clicks.append(ClickEvent(t: t, x: clamp01(p.x), y: clamp01(p.y), button: b)) }
            case .shortcut(let label):
                shortcuts.append(Shortcut(t: t, label: label))
            case .typing(let until):
                typing.append(TypingSpan(start: t, end: min(duration, until - sessionStartHost), focus: Point(x: clamp01(p.x), y: clamp01(p.y))))
            }
        }
        return (cursor, clicks, shortcuts, typing)
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
