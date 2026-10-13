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

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, path: CameraPath, style: FrameStyle, fill: Bool) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.path = path
        self.style = style
        self.fill = fill
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
            let image = render(src, camera: ins.path.camera(composition: request.compositionTime.seconds), canvas: size, style: ins.style,
                               fill: ins.fill, window: ins.path.window)
            Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.outputSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    /// Gradient + framed recording. `camera` crops the recording inside the fixed rounded frame; `window` is the crop
    /// at scale 1 (the whole recording, or the frame's aspect when filling).
    func render(_ source: CIImage, camera: Camera, canvas: CGSize, style: FrameStyle, fill: Bool = false, window: Window = .full) -> CIImage {
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
        let content = lanczos.outputImage!
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
            .cropped(to: frame)
        let bg = backgroundImage(frame: frame, canvas: canvas, style: style)
        return content.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: Self.roundedRect(frame, canvas: canvas, style: style, color: .white),
        ]).cropped(to: CGRect(origin: .zero, size: canvas))
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

    /// Gradient and drop shadow never change within a render, so they are rendered once and cached.
    private func backgroundImage(frame: CGRect, canvas: CGSize, style: FrameStyle) -> CIImage {
        if let bg = background, bg.frame == frame, bg.canvas == canvas, bg.style == style { return bg.image }
        let k = min(canvas.width, canvas.height) / 1080
        let full = CGRect(origin: .zero, size: canvas)
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: canvas.height)            // top-left
        gradient.point1 = CGPoint(x: canvas.width, y: 0)             // bottom-right
        gradient.color0 = style.topLeft
        gradient.color1 = style.bottomRight
        let shadow = Self.roundedRect(frame, canvas: canvas, style: style,
                                      color: CIColor(red: 0, green: 0, blue: 0, alpha: style.shadowOpacity))
            .applyingGaussianBlur(sigma: style.shadowRadius * k / 2)
            .transformed(by: CGAffineTransform(translationX: 0, y: -style.shadowOffset * k))
        let composed = shadow.composited(over: gradient.outputImage!).cropped(to: full)
        let cg = Self.context.createCGImage(composed, from: full, format: .RGBA8, colorSpace: Self.outputSpace)!
        let image = CIImage(cgImage: cg)
        background = (frame, canvas, style, image)
        return image
    }
}

// MARK: - Composition shared by preview and export

public struct EditComposition: @unchecked Sendable {
    public let asset: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVAudioMix?
    public let videoTrackID: CMPersistentTrackID
}

/// The recording's tracks, loaded once so the editor can rebuild compositions synchronously.
public struct SourceTracks: @unchecked Sendable {
    let asset: AVURLAsset                     // tracks only weakly reference their asset
    let video: (track: AVAssetTrack, range: CMTimeRange)
    let audio: [(track: AVAssetTrack, range: CMTimeRange)]

    public static func load(_ url: URL) async throws -> SourceTracks {
        let source = AVURLAsset(url: url)
        guard let v = try await source.loadTracks(withMediaType: .video).first else { throw LoupecastError("The recording has no video track.") }
        var audio: [(AVAssetTrack, CMTimeRange)] = []
        for a in try await source.loadTracks(withMediaType: .audio) { audio.append((a, try await a.load(.timeRange))) }
        return SourceTracks(asset: source, video: (v, try await v.load(.timeRange)), audio: audio)
    }
}

public enum Composer {
    public static func renderSize(_ aspect: AspectRatio) -> CGSize {
        CGSize(width: aspect.pixels.width, height: aspect.pixels.height)
    }
    public static let frameDuration = CMTime(value: 1, timescale: 60)

    public static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60_000) }

    /// The kept clips back to back, for preview and export alike, with the same compositor and camera path.
    public static func make(project: Project, source: SourceTracks) throws -> EditComposition {
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LoupecastError("The recording has no video track.")
        }
        var tracks = [(source.video.track, source.video.range, video)]
        for a in source.audio {
            if let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { tracks.append((a.track, a.range, t)) }
        }
        var at = CMTime.zero                     // exact running position: segments never overlap or gap
        for clip in project.clips.keptRanges {
            let range = CMTimeRange(start: time(clip.start), end: time(clip.end))
            for (src, srcRange, dst) in tracks {
                let r = CMTimeRangeGetIntersection(range, otherRange: srcRange)
                guard r.duration > .zero else { continue }
                try dst.insertTimeRange(r, of: src, at: at + (r.start - range.start))
            }
            at = at + range.duration
        }
        for (_, _, track) in tracks.dropFirst() where track.segments.isEmpty { comp.removeTrack(track) }
        let vc = videoComposition(project: project, trackID: video.trackID, duration: comp.duration)
        return EditComposition(asset: comp, videoComposition: vc, audioMix: audioMix(comp, cuts: project.clips.cutTimes),
                               videoTrackID: video.trackID)
    }

    /// Preview's fade around every cut. AVAudioMix smooths ramps this short (measured: the level only
    /// dips to ~60 %), so export applies the exact envelope to the samples itself (see Exporter).
    static func audioMix(_ comp: AVComposition, cuts: [Double]) -> AVAudioMix? {
        let tracks = comp.tracks(withMediaType: .audio)
        guard !cuts.isEmpty, !tracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let p = AVMutableAudioMixInputParameters(track: track)
            for c in cuts {
                p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: time(c - Project.cutFade), end: time(c)))
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: time(c), end: time(c + Project.cutFade)))
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
    public static func videoComposition(project: Project, trackID: CMPersistentTrackID, duration: CMTime) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = LoupecastCompositor.self
        vc.renderSize = renderSize(project.aspect)
        vc.frameDuration = frameDuration
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.instructions = [LoupecastInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), trackID: trackID,
                                            path: cameraPath(project), style: FrameStyle(project.style), fill: project.fillsFrame)]
        return vc
    }
}
