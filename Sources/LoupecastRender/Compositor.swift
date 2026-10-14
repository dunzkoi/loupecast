import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import LoupecastCore

/// Look of the exported frame. Values are for a canvas whose short side is 1080 pixels and scale with it.
public struct FrameStyle: Sendable, Equatable {
    public var topLeft = CIColor(red: 0.62, green: 0.69, blue: 0.97)
    public var bottomRight = CIColor(red: 0.97, green: 0.76, blue: 0.82)
    public var padding = 0.06
    public var cornerRadius = 12.0
    public var shadowRadius = 26.0
    public var shadowOffset = 10.0
    public var shadowOpacity = 0.32
    /// A picture filling the canvas instead of the gradient (the padding, corners and shadow stay).
    public var image: URL?
    public static let standard = FrameStyle()

    /// One color top-left to bottom-right is a solid background.
    public init(_ preset: StylePreset = .pastel) {
        func solid(_ r: Double, _ g: Double, _ b: Double) { topLeft = CIColor(red: r, green: g, blue: b); bottomRight = topLeft }
        switch preset {
        case .pastel: break
        case .dark:
            topLeft = CIColor(red: 0.10, green: 0.12, blue: 0.22)
            bottomRight = CIColor(red: 0.30, green: 0.17, blue: 0.36)
        case .light: solid(0.93, 0.93, 0.95)
        case .graphite: solid(0.13, 0.13, 0.14)
        case .blue: solid(0.18, 0.40, 0.86)
        case .plain:
            solid(0, 0, 0)
            padding = 0; cornerRadius = 0; shadowOpacity = 0
        }
    }
}

/// Carries everything one render needs. Same type for preview and export.
final class LoupecastInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true                 // render every frame → static screens are duplicated at 60 fps
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let path: CameraPath
    let style: FrameStyle
    let fill: Bool
    /// The webcam track and how to show it; nil when hidden (then it isn't decoded at all).
    let camera: (trackID: CMPersistentTrackID, overlay: CameraOverlay)?
    /// Clicks on kept material at their composition time, oldest first; empty when 클릭 표시 is off.
    let clicks: [(time: Double, at: Point, right: Bool)]
    let motionBlur: Bool

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, path: CameraPath, style: FrameStyle, fill: Bool,
         camera: (trackID: CMPersistentTrackID, overlay: CameraOverlay)?, project: Project) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.requiredSourceTrackIDs = ([trackID] + (camera.map { [$0.trackID] } ?? [])).map { NSNumber(value: $0) }
        self.path = path
        self.style = style
        self.fill = fill
        self.camera = camera
        motionBlur = project.motionBlur
        let clips = project.clips
        clicks = !project.showClicks ? [] : project.clicks.filter { clips.index(containing: $0.t) != nil }.sorted { $0.t < $1.t }
            .map { (clips.compositionTime($0.t), Point(x: $0.x, y: $0.y), $0.button == .right) }
    }
}

/// Where the recording sits on the canvas for one frame: the fixed frame rect and the camera's crop inside it.
struct Placement {
    let frame: CGRect        // canvas, CI space (bottom-left origin)
    let camera: Camera
    let window: Window
    let source: CGSize       // recording pixels

    /// The canvas point (CI space) that shows recording point `p` (normalized, top-left origin).
    func point(_ p: Point) -> CGPoint {
        let hx = window.width / 2 / camera.scale, hy = window.height / 2 / camera.scale
        return CGPoint(x: frame.minX + (p.x - camera.center.x + hx) / (2 * hx) * frame.width,
                       y: frame.maxY - (p.y - camera.center.y + hy) / (2 * hy) * frame.height)
    }
}

public final class LoupecastCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false])
    static let outputSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private static let bgra: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    private let queue = DispatchQueue(label: "loupecast.compositor", qos: .userInitiated)
    private var background: (frame: CGRect, canvas: CGSize, style: FrameStyle, image: CIImage)?   // touched only on `queue`
    private var lastSource: CIImage?                                            // touched only on `queue`

    public var sourcePixelBufferAttributes: [String: any Sendable]? { Self.bgra }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.bgra }
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    public func cancelAllPendingVideoCompositionRequests() {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            // no source frame (the instant at a track's very end): hold the previous one, because a
            // failed request makes the player tear down and rebuild its pipeline
            guard let ins = request.videoCompositionInstruction as? LoupecastInstruction,
                  let src = request.sourceFrame(byTrackID: ins.trackID).map({ CIImage(cvPixelBuffer: $0) }) ?? lastSource,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: LoupecastError("No source frame to compose."))
                return
            }
            lastSource = src
            let size = request.renderContext.size
            // no webcam frame where the camera started late or stopped early: no circle there
            let face = ins.camera.flatMap { request.sourceFrame(byTrackID: $0.trackID) }.map { CIImage(cvPixelBuffer: $0) }
            let image = compose(src, face: face, at: request.compositionTime.seconds, frame: request.renderContext.videoComposition.frameDuration.seconds,
                                canvas: size, ins)
            Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.outputSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    /// One output frame at composition time `t`, from its source frames (`face`: the webcam's, if any); `frame` is the
    /// frame duration (s), how far back motion blur looks.
    func compose(_ src: CIImage, face: CIImage?, at t: Double, frame: Double = 1.0 / 60, canvas: CGSize, _ ins: LoupecastInstruction) -> CIImage {
        let camera = ins.path.camera(composition: t)
        let before = ins.motionBlur ? ins.path.camera(composition: max(0, t - frame)) : camera
        let image = render(src, camera: camera, canvas: canvas, style: ins.style, fill: ins.fill, window: ins.path.window) { content, place in
            Self.ripples(ins.clicks, at: t, place, canvas: canvas).reduce(Self.motionBlur(content, place, from: before, canvas: canvas)) { $1.composited(over: $0) }
        }
        guard let cam = ins.camera, let face else { return image }
        return Self.overlay(face, on: image, canvas: canvas, cam.overlay)
    }

    /// Blurs the recording along its on-screen motion since the previous frame's camera `before`: a zoom blur from the frame's
    /// center for a scale change, a motion blur along the pan. Half of the frame's movement (a 180° shutter; CIZoomBlur's
    /// amount reads stronger, so a third of that), at most 2 % of the canvas's short side; a camera that holds still costs nothing.
    static func motionBlur(_ content: CIImage, _ place: Placement, from before: Camera, canvas: CGSize) -> CIImage {
        guard before != place.camera else { return content }
        let cap = 0.02 * min(canvas.width, canvas.height), mid = CGPoint(x: place.frame.midX, y: place.frame.midY)
        // where the point now at the frame's center was a frame ago, and how much the frame's half width grew
        let was = Placement(frame: place.frame, camera: before, window: place.window, source: place.source).point(place.camera.center)
        let pan = hypot(mid.x - was.x, mid.y - was.y) / 2, zoom = abs(1 - before.scale / place.camera.scale) * place.frame.width / 12
        var image = content.clampedToExtent()
        if zoom > 0.5 {
            let z = CIFilter.zoomBlur()
            z.inputImage = image; z.center = mid; z.amount = Float(min(cap, zoom))
            image = z.outputImage!
        }
        if pan > 0.5 {
            let m = CIFilter.motionBlur()
            m.inputImage = image; m.radius = Float(min(cap, pan)); m.angle = Float(atan2(mid.y - was.y, mid.x - was.x))
            image = m.outputImage!
        }
        return image.cropped(to: content.extent)
    }

    static let rippleLength = 0.4

    /// A translucent disc with a dark rim that grows from 1.2 % to 4.2 % of the canvas's short side and fades out over
    /// 0.4 s after each click: white for the left button, orange for the right. The rim shows on light screens, the fill on
    /// dark ones. Inside the frame, so it moves with the zoom like the click itself.
    static func ripples(_ clicks: [(time: Double, at: Point, right: Bool)], at t: Double, _ place: Placement, canvas: CGSize) -> [CIImage] {
        let short = min(canvas.width, canvas.height), k = short / 1080
        func disc(_ c: CGPoint, _ r: Double, _ color: CIColor) -> CIImage {
            let g = CIFilter.radialGradient()
            g.center = c
            g.radius0 = Float(max(0, r - max(1, 1.5 * k)))     // a pixel or two of soft edge
            g.radius1 = Float(r)
            g.color0 = color
            g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            return g.outputImage!.cropped(to: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        return clicks.filter { $0.time <= t && t < $0.time + rippleLength }.map { c in
            let f = (t - c.time) / rippleLength, r = short * (0.012 + 0.03 * f), a = 1 - f, rim = max(1.5, 3 * k)
            let p = place.point(c.at)
            let fill = disc(p, r - rim, c.right ? CIColor(red: 1, green: 0.6, blue: 0.15, alpha: 0.55 * a) : CIColor(red: 1, green: 1, blue: 1, alpha: 0.5 * a))
            let edge = disc(p, r, CIColor(red: 0, green: 0, blue: 0, alpha: 0.35 * a))
                .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: disc(p, r - rim, .white)])
            return fill.composited(over: edge)
        }
    }

    /// Gradient + framed recording. `camera` crops the recording inside the fixed rounded frame; `window` is the crop
    /// at scale 1 (the whole recording, or the frame's aspect when filling). `decorate` draws on the recording inside the
    /// frame (what it draws is clipped to the rounded frame).
    func render(_ source: CIImage, camera: Camera, canvas: CGSize, style: FrameStyle, fill: Bool = false, window: Window = .full,
                decorate: (CIImage, Placement) -> CIImage = { image, _ in image }) -> CIImage {
        let src = source.extent
        let frame = Self.frameRect(source: src.size, canvas: canvas, style: style, fill: fill)
        // camera window in source pixels (CI is bottom-left origin, camera is top-left)
        let cw = src.width * window.width / camera.scale, ch = src.height * window.height / camera.scale
        let crop = CGRect(x: src.minX + camera.center.x * src.width - cw / 2,
                          y: src.minY + (1 - camera.center.y) * src.height - ch / 2, width: cw, height: ch)
        let sx = frame.width / crop.width, sy = frame.height / crop.height
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = source.clampedToExtent().cropped(to: crop.insetBy(dx: -4, dy: -4))
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        lanczos.scale = Float(sy)
        lanczos.aspectRatio = Float(sx / sy)
        let content = decorate(lanczos.outputImage!.transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY)).cropped(to: frame),
                               Placement(frame: frame, camera: camera, window: window, source: src.size)).cropped(to: frame)
        let bg = backgroundImage(frame: frame, canvas: canvas, style: style)
        return content.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: Self.roundedRect(frame, canvas: canvas, style: style, color: .white),
        ]).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// Where the webcam circle sits on `canvas` (CI space, bottom-left origin): `size` of the short side, in a corner.
    public static func cameraCircle(canvas: CGSize, _ overlay: CameraOverlay) -> CGRect {
        let short = min(canvas.width, canvas.height), d = (overlay.size * short).rounded(), margin = (0.045 * short).rounded()
        let left = overlay.corner == .topLeft || overlay.corner == .bottomLeft, bottom = overlay.corner == .bottomLeft || overlay.corner == .bottomRight
        return CGRect(x: left ? margin : canvas.width - margin - d, y: bottom ? margin : canvas.height - margin - d, width: d, height: d)
    }

    /// The webcam's centered square in a white-ringed circle over the finished frame (zoom doesn't move it).
    static func overlay(_ face: CIImage, on base: CIImage, canvas: CGSize, _ overlay: CameraOverlay) -> CIImage {
        let circle = cameraCircle(canvas: canvas, overlay), ring = max(2, (0.006 * min(canvas.width, canvas.height)).rounded())
        let e = face.extent, side = min(e.width, e.height), k = circle.width / side
        let square = face.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
        let placed = square.transformed(by: CGAffineTransform(translationX: -square.extent.minX, y: -square.extent.minY)
            .concatenating(CGAffineTransform(scaleX: k, y: k)).concatenating(CGAffineTransform(translationX: circle.minX, y: circle.minY)))
        func disc(_ r: CGRect) -> CIImage {
            let g = CIFilter.roundedRectangleGenerator()
            g.extent = r
            g.radius = Float(r.width / 2)
            g.color = .white
            return g.outputImage!
        }
        return placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: disc(circle.insetBy(dx: -ring, dy: -ring)).composited(over: base),
            kCIInputMaskImageKey: disc(circle),
        ]).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// The picture scaled to cover the canvas (centered, cropped) and blurred by 1 % of the short side, so the recording
    /// stands out. Nil when it can't be read.
    static func picture(_ url: URL, canvas: CGSize) -> CIImage? {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]), image.extent.width > 0, image.extent.height > 0
        else { return nil }
        let e = image.extent, s = max(canvas.width / e.width, canvas.height / e.height)
        let placed = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: (canvas.width - e.width * s) / 2, y: (canvas.height - e.height * s) / 2)))
        return placed.clampedToExtent().applyingGaussianBlur(sigma: 0.01 * min(canvas.width, canvas.height))
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private static func roundedRect(_ frame: CGRect, canvas: CGSize, style: FrameStyle, color: CIColor) -> CIImage {
        let shape = CIFilter.roundedRectangleGenerator()
        shape.extent = frame
        shape.radius = Float(style.cornerRadius * min(canvas.width, canvas.height) / 1080)
        shape.color = color
        return shape.outputImage!
    }

    /// The recording's aspect fitted inside the padding, or (fill) everything inside the padding.
    public static func frameRect(source: CGSize, canvas: CGSize, style: FrameStyle, fill: Bool = false) -> CGRect {
        let avail = CGRect(origin: .zero, size: canvas)
            .insetBy(dx: canvas.width * style.padding, dy: canvas.height * style.padding)
        if fill { return avail.integral }
        let s = min(avail.width / source.width, avail.height / source.height)
        let w = (source.width * s).rounded(), h = (source.height * s).rounded()
        return CGRect(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h)
    }

    /// Gradient (or picture) and drop shadow never change within a render, so they are rendered once and cached; the
    /// picture's URL is part of `style`.
    private func backgroundImage(frame: CGRect, canvas: CGSize, style: FrameStyle) -> CIImage {
        if let bg = background, bg.frame == frame, bg.canvas == canvas, bg.style == style { return bg.image }
        let k = min(canvas.width, canvas.height) / 1080
        let full = CGRect(origin: .zero, size: canvas)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: canvas.height)            // top-left
        gradient.point1 = CGPoint(x: canvas.width, y: 0)             // bottom-right
        gradient.color0 = style.topLeft
        gradient.color1 = style.bottomRight
        let backdrop = style.image.flatMap { Self.picture($0, canvas: canvas) } ?? gradient.outputImage!
        let shadow = Self.roundedRect(frame, canvas: canvas, style: style,
                                      color: CIColor(red: 0, green: 0, blue: 0, alpha: style.shadowOpacity))
            .applyingGaussianBlur(sigma: style.shadowRadius * k / 2)
            .transformed(by: CGAffineTransform(translationX: 0, y: -style.shadowOffset * k))
        let composed = shadow.composited(over: backdrop).cropped(to: full)
        let cg = Self.context.createCGImage(composed, from: full, format: .RGBA8, colorSpace: Self.outputSpace)!
        let image = CIImage(cgImage: cg)
        background = (frame, canvas, style, image)
        return image
    }
}

// MARK: - Composition shared by preview and export

public struct EditComposition: @unchecked Sendable {
    /// The recording folder: files the project names (webcam, background picture) are here.
    public let folder: URL
    public let asset: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVAudioMix?
    public let videoTrackID: CMPersistentTrackID
    /// Composition audio tracks holding the microphone (the others are computer audio).
    public let micTracks: Set<CMPersistentTrackID>
    public let cameraTrackID: CMPersistentTrackID?
}

/// The recording's tracks, loaded once so the editor can rebuild compositions synchronously.
public struct SourceTracks: @unchecked Sendable {
    let asset: AVURLAsset                     // tracks only weakly reference their asset
    let video: (track: AVAssetTrack, range: CMTimeRange)
    /// The recorder writes computer audio in stereo and the microphone in mono.
    let audio: [(track: AVAssetTrack, range: CMTimeRange, mic: Bool)]
    let camera: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)?

    public var hasSystemAudio: Bool { audio.contains { !$0.mic } }
    public var hasMicrophone: Bool { audio.contains { $0.mic } }

    /// `camera`: the webcam movie's file name next to the recording; an unreadable one only drops the circle.
    public static func load(_ url: URL, camera: String? = nil) async throws -> SourceTracks {
        var cam: (AVURLAsset, AVAssetTrack, CMTimeRange)?
        if let camera {
            let a = AVURLAsset(url: url.deletingLastPathComponent().appendingPathComponent(camera))
            if let t = try? await a.loadTracks(withMediaType: .video).first, let r = try? await t.load(.timeRange) { cam = (a, t, r) }
        }
        let source = AVURLAsset(url: url)
        guard let v = try await source.loadTracks(withMediaType: .video).first else { throw LoupecastError("The recording has no video track.") }
        var audio: [(AVAssetTrack, CMTimeRange, Bool)] = []
        for a in try await source.loadTracks(withMediaType: .audio) {
            let (range, formats) = try await a.load(.timeRange, .formatDescriptions)
            let channels = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
            audio.append((a, range, channels == 1))
        }
        return SourceTracks(asset: source, video: (v, try await v.load(.timeRange)), audio: audio, camera: cam)
    }
}

public enum Composer {
    /// `scale` 2: 4K. The frame's look scales with the short side, so both sizes look the same.
    public static func renderSize(_ aspect: AspectRatio, scale: Int = 1) -> CGSize {
        CGSize(width: aspect.pixels.width * scale, height: aspect.pixels.height * scale)
    }

    /// 4K adds detail only when the recording has clearly more pixels across than the 1080p frame shows at scale 1
    /// (a Retina screen does; a 1× display doesn't).
    public static func hasDetailFor4K(_ project: Project) -> Bool {
        let source = CGSize(width: project.pixelWidth, height: project.pixelHeight)
        let frame = LoupecastCompositor.frameRect(source: source, canvas: renderSize(project.aspect), style: FrameStyle(project.style), fill: project.fillsFrame)
        let shown = project.fillsFrame ? Window.filling(source: (source.width, source.height), frame: (frame.width, frame.height)).width : 1
        return source.width * shown >= 1.5 * frame.width
    }
    public static let frameDuration = CMTime(value: 1, timescale: 60)
    /// Sped-up clips keep the voice's pitch; preview and export use the same algorithm.
    public static let pitchAlgorithm = AVAudioTimePitchAlgorithm.spectral

    public static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60_000) }

    /// The kept clips back to back, for preview and export alike, with the same compositor and camera path.
    public static func make(project: Project, source: SourceTracks) throws -> EditComposition {
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LoupecastError("The recording has no video track.")
        }
        // (source, its range, composition track, recording time of the source's 0)
        var tracks = [(source.video.track, source.video.range, video, 0.0)]
        var micTracks = Set<CMPersistentTrackID>()
        for a in source.audio {
            guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            tracks.append((a.track, a.range, t, 0))
            if a.mic { micTracks.insert(t.trackID) }
        }
        if let cam = source.camera, let overlay = project.camera,
           let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            tracks.append((cam.track, cam.range, t, overlay.offset))
        }
        var at = CMTime.zero                     // exact running position: segments never overlap or gap
        for clip in project.clips.keptRanges {
            let range = CMTimeRange(start: time(clip.start), end: time(clip.end))
            for (src, srcRange, dst, offset) in tracks {
                let wanted = CMTimeRange(start: range.start - time(offset), duration: range.duration)
                let r = CMTimeRangeGetIntersection(wanted, otherRange: srcRange)
                guard r.duration > .zero else { continue }
                try dst.insertTimeRange(r, of: src, at: at + (r.start - wanted.start))
            }
            // a faster clip: every track's piece squeezed, sound kept at its pitch (pitchAlgorithm)
            let played = clip.speed == 1 ? range.duration : CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / clip.speed)
            if clip.speed != 1 { comp.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: played) }
            at = at + played
        }
        for (_, _, track, _) in tracks.dropFirst() where track.segments.isEmpty { comp.removeTrack(track) }
        let cameraID = comp.tracks(withMediaType: .video).map(\.trackID).first { $0 != video.trackID }
        let folder = source.asset.url.deletingLastPathComponent()
        let vc = videoComposition(project: project, folder: folder, trackID: video.trackID, cameraTrackID: cameraID, duration: comp.duration)
        return EditComposition(folder: folder, asset: comp, videoComposition: vc, audioMix: audioMix(comp, project: project, micTracks: micTracks),
                               videoTrackID: video.trackID, micTracks: micTracks, cameraTrackID: cameraID)
    }

    /// Each track at its volume, with the preview's fade around every cut on top (`fades`). AVAudioMix smooths ramps
    /// this short (measured: the level only dips to ~60 %), so export applies the exact envelope to the samples
    /// itself (see Exporter) and asks for the volumes only.
    public static func audioMix(_ comp: AVComposition, project: Project, micTracks: Set<CMPersistentTrackID>, fades: Bool = true) -> AVAudioMix? {
        let tracks = comp.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let cuts = fades ? project.clips.cutTimes : []
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let v = Float(micTracks.contains(track.trackID) ? project.micVolume : project.systemVolume)
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(v, at: .zero)
            for c in cuts {
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: time(c - Project.cutFade), end: time(c)))
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: time(c), end: time(c + Project.cutFade)))
            }
            return p
        }
        return mix
    }

    /// The path preview and export render with: its window has the frame's aspect when the project fills the frame.
    public static func cameraPath(_ project: Project) -> CameraPath {
        guard project.fillsFrame else { return CameraPath(project: project) }
        let source = CGSize(width: project.pixelWidth, height: project.pixelHeight)
        let frame = LoupecastCompositor.frameRect(source: source, canvas: renderSize(project.aspect), style: FrameStyle(project.style), fill: true)
        return CameraPath(project: project, window: .filling(source: (source.width, source.height), frame: (frame.width, frame.height)))
    }

    /// The recording point (normalized, top-left origin) shown at canvas point `p` (pixels, top-left origin) at
    /// recording time `t`, through the padding, the fill window and the camera then; nil outside the frame.
    public static func recordingPoint(canvas p: CGPoint, project: Project, at t: Double) -> Point? {
        let canvas = renderSize(project.aspect)
        let frame = LoupecastCompositor.frameRect(source: CGSize(width: project.pixelWidth, height: project.pixelHeight), canvas: canvas,
                                                  style: FrameStyle(project.style), fill: project.fillsFrame)
        let y = canvas.height - p.y                                  // the frame is in CI space, bottom-left origin
        guard (frame.minX...frame.maxX).contains(p.x), (frame.minY...frame.maxY).contains(y) else { return nil }   // edges included
        let path = cameraPath(project), cam = path.camera(at: t)
        let hx = path.window.width / 2 / cam.scale, hy = path.window.height / 2 / cam.scale
        return Point(x: cam.center.x - hx + (p.x - frame.minX) / frame.width * 2 * hx,
                     y: cam.center.y - hy + (frame.maxY - y) / frame.height * 2 * hy)
    }

    /// Rebuilt on every zoom edit; cheap (the camera path is a few thousand spring steps).
    /// The preset's look, with the project's background picture from `folder`.
    public static func frameStyle(_ project: Project, folder: URL) -> FrameStyle {
        var style = FrameStyle(project.style)
        if project.style != .plain, let file = project.backgroundImage { style.image = folder.appendingPathComponent(file) }
        return style
    }

    public static func videoComposition(project: Project, folder: URL, trackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID? = nil,
                                        duration: CMTime) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = LoupecastCompositor.self
        vc.renderSize = renderSize(project.aspect)
        vc.frameDuration = frameDuration
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.instructions = [LoupecastInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), trackID: trackID,
                                            path: cameraPath(project), style: frameStyle(project, folder: folder), fill: project.fillsFrame,
                                            camera: cameraTrackID.flatMap { id in project.camera.flatMap { $0.isVisible ? (id, $0) : nil } },
                                            project: project)]
        return vc
    }
}
