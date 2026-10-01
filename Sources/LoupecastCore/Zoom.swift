// Pure zoom logic: no AppKit / AVFoundation. All times are recording-relative seconds,
// all positions are normalized to the captured display (0–1, top-left origin).

import Foundation

public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let center = Point(x: 0.5, y: 0.5)
}

public struct CursorSample: Codable, Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}

public struct ClickEvent: Codable, Hashable, Sendable {
    public enum Button: String, Codable, Sendable { case left, right }
    public var t: Double
    public var x: Double
    public var y: Double
    public var button: Button
    public init(t: Double, x: Double, y: Double, button: Button = .left) {
        self.t = t; self.x = x; self.y = y; self.button = button
    }
}

public struct KeyEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var keyCode: UInt16
    public init(t: Double, keyCode: UInt16) { self.t = t; self.keyCode = keyCode }
}

public struct ZoomSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    public var focus: Point
    public var isEnabled: Bool
    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double = AutoZoom.defaultScale,
                focus: Point, isEnabled: Bool = true) {
        self.id = id; self.start = start; self.end = end; self.scale = scale
        self.focus = focus; self.isEnabled = isEnabled
    }
}

/// Camera in recording-normalized space: the visible window is `center ± 0.5/scale` on both axes.
public struct Camera: Equatable, Sendable {
    public var scale: Double
    public var center: Point
    public static let identity = Camera(scale: 1, center: .center)
}

public enum AutoZoom {
    public static let clusterGap = 1.5
    public static let clusterDistance = 0.25
    public static let leadIn = 0.4
    public static let tail = 1.5
    public static let mergeGap = 1.0
    public static let defaultScale = 2.0
    public static let transition = 0.6

    /// Clicks → ordered, merged zoom segments.
    public static func segments(clicks: [ClickEvent], duration: Double) -> [ZoomSegment] {
        // merge windows whose gap is shorter than mergeGap (also overlapping ones)
        var merged: [(start: Double, end: Double, clicks: [ClickEvent])] = []
        for cl in clusters(clicks) {
            let s = max(0, cl.first!.t - leadIn), e = min(duration, cl.last!.t + tail)
            if let last = merged.last, s - last.end < mergeGap {
                merged[merged.count - 1].end = max(last.end, e)
                merged[merged.count - 1].clicks += cl
            } else {
                merged.append((s, e, cl))
            }
        }
        return merged.filter { $0.end > $0.start }.map {
            let f = centroid($0.clicks)
            return ZoomSegment(start: $0.start, end: $0.end, focus: Point(x: clamp01(f.x), y: clamp01(f.y)))
        }
    }

    /// Clicks closer than `clusterGap` to the previous click and within `clusterDistance` of the
    /// running centroid belong to one cluster.
    static func clusters(_ clicks: [ClickEvent]) -> [[ClickEvent]] {
        var out: [[ClickEvent]] = []
        for c in clicks.sorted(by: { $0.t < $1.t }) {
            if let last = out.last, let prev = last.last, c.t - prev.t < clusterGap,
               hypot(centroid(last).x - c.x, centroid(last).y - c.y) <= clusterDistance {
                out[out.count - 1].append(c)
            } else {
                out.append([c])
            }
        }
        return out
    }

    static func centroid(_ cs: [ClickEvent]) -> Point {
        Point(x: cs.map(\.x).reduce(0, +) / Double(cs.count), y: cs.map(\.y).reduce(0, +) / Double(cs.count))
    }
}

public extension Array where Element == ZoomSegment {
    /// Drops segments outside [lo, hi] and clips the ones straddling an edge.
    func clipped(to lo: Double, _ hi: Double) -> [ZoomSegment] {
        compactMap { seg in
            var s = seg
            s.start = Swift.max(seg.start, lo)
            s.end = Swift.min(seg.end, hi)
            return s.end > s.start ? s : nil
        }
    }
}

/// Smooth cubic easing with zero first and second derivative at both ends.
@inline(__always) public func smootherstep(_ x: Double) -> Double {
    let t = Swift.min(1, Swift.max(0, x))
    return t * t * t * (t * (t * 6 - 15) + 10)
}

/// Precomputed, deterministic camera path. Preview and export both build it from the same
/// project data and call `camera(at:)`, so they render identical framing for a given time.
///
/// Segments are in recording time; the path lays them out on the composition (the kept clips back to
/// back), so the 0.6 s ramps measure kept material. A segment straddling a cut ends at the cut; it is
/// carried across only when both sides of the cut lie inside the same segment.
public struct CameraPath: Sendable {
    public static let springOmega = 5.0     // critically damped, ~0.2 s time constant
    static let step = 1.0 / 240.0

    struct Track: Sendable {
        let start: Double, end: Double      // composition time
        let scale: Double
        let points: [Point]                 // spring-smoothed focus, sampled every `step` from start
    }
    let tracks: [Track]
    let clips: [ClipRange]

    public init(segments: [ZoomSegment], cursor: [CursorSample], clips: [ClipRange]) {
        let cursor = cursor.sorted { $0.t < $1.t }
        self.clips = clips
        let starts = clips.compositionStarts
        tracks = segments.filter { $0.isEnabled && $0.scale > 1 }.flatMap { seg -> [Track] in
            // the segment's pieces inside each clip, in composition time; contiguous pieces stay one
            var pieces: [(start: Double, end: Double)] = []
            for (clip, c0) in zip(clips, starts) {
                let a = Swift.max(seg.start, clip.start), b = Swift.min(seg.end, clip.end)
                guard b > a else { continue }
                let piece = (start: c0 + a - clip.start, end: c0 + b - clip.start)
                if let last = pieces.last, abs(last.end - piece.start) < 1e-9 { pieces[pieces.count - 1].end = piece.end }
                else { pieces.append(piece) }
            }
            return pieces.map { piece in
                let n = Int(((piece.end - piece.start) / Self.step).rounded(.up)) + 1
                var pts: [Point] = []
                pts.reserveCapacity(n)
                var p = seg.focus, v = Point(x: 0, y: 0)
                let w = Self.springOmega, k = exp(-w * Self.step)
                for i in 0..<n {
                    pts.append(p)
                    let g = cursorAt(cursor, clips.recordingTime(piece.start + Double(i) * Self.step)) ?? seg.focus
                    // exact critically damped step toward g (no overshoot from rest)
                    let dx = p.x - g.x, dy = p.y - g.y
                    let tx = (v.x + w * dx) * Self.step, ty = (v.y + w * dy) * Self.step
                    p = Point(x: g.x + (dx + tx) * k, y: g.y + (dy + ty) * k)
                    v = Point(x: (v.x - w * tx) * k, y: (v.y - w * ty) * k)
                }
                return Track(start: piece.start, end: piece.end, scale: seg.scale, points: pts)
            }
        }
    }

    public init(segments: [ZoomSegment], cursor: [CursorSample], trimIn: Double, trimOut: Double) {
        self.init(segments: segments, cursor: cursor, clips: [ClipRange(start: trimIn, end: trimOut)])
    }

    public init(project: Project) {
        self.init(segments: project.zooms, cursor: project.cursor, clips: project.clips)
    }

    /// Camera at recording time `t`; identity in removed material.
    public func camera(at t: Double) -> Camera {
        guard clips.index(containing: t) != nil else { return .identity }
        return camera(composition: clips.compositionTime(t))
    }

    public func camera(composition t: Double) -> Camera {
        var wSum = 0.0, zoom = 0.0, sx = 0.0, sy = 0.0, ss = 0.0
        for tr in tracks {
            guard t > tr.start, t < tr.end else { continue }
            // fixed 0.6 s ramps: a segment shorter than 1.2 s zooms in partway instead of faster
            let r = AutoZoom.transition
            let w = Swift.min(smootherstep((t - tr.start) / r), smootherstep((tr.end - t) / r))
            guard w > 0 else { continue }
            let p = clampCenter(tr.sample(t), scale: tr.scale)
            wSum += w; zoom = Swift.max(zoom, w)
            sx += w * p.x; sy += w * p.y; ss += w * tr.scale
        }
        guard wSum > 0 else { return .identity }
        let target = ss / wSum
        let focus = clampCenter(Point(x: sx / wSum, y: sy / wSum), scale: target)
        let scale = 1 + (target - 1) * zoom
        let c = Point(x: 0.5 + (focus.x - 0.5) * zoom, y: 0.5 + (focus.y - 0.5) * zoom)
        return Camera(scale: scale, center: clampCenter(c, scale: scale))
    }
}

extension CameraPath.Track {
    func sample(_ t: Double) -> Point {
        let f = (t - start) / CameraPath.step
        let i = Swift.max(0, Swift.min(points.count - 1, Int(f)))
        let j = Swift.min(points.count - 1, i + 1)
        let a = f - Double(i)
        return Point(x: points[i].x + (points[j].x - points[i].x) * a,
                     y: points[i].y + (points[j].y - points[i].y) * a)
    }
}

/// Keeps the visible window (center ± 0.5/scale) inside the recording.
public func clampCenter(_ p: Point, scale: Double) -> Point {
    let h = 0.5 / Swift.max(1, scale)
    return Point(x: Swift.min(1 - h, Swift.max(h, p.x)), y: Swift.min(1 - h, Swift.max(h, p.y)))
}

/// Linear interpolation of cursor samples (sorted by t). Nil when there are no samples.
public func cursorAt(_ samples: [CursorSample], _ t: Double) -> Point? {
    guard let first = samples.first, let last = samples.last else { return nil }
    if t <= first.t { return Point(x: first.x, y: first.y) }
    if t >= last.t { return Point(x: last.x, y: last.y) }
    var lo = 0, hi = samples.count - 1
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if samples[mid].t <= t { lo = mid } else { hi = mid }
    }
    let a = samples[lo], b = samples[hi]
    let u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
    return Point(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
}

func clamp01(_ v: Double) -> Double { Swift.min(1, Swift.max(0, v)) }
