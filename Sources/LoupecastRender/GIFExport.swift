import AVFoundation
import CoreImage
import ImageIO
import LoupecastCore
import UniformTypeIdentifiers

/// A silent, looping GIF of the same composition (zooms, cuts, speed, background), for READMEs, issues and PR
/// descriptions that don't play MP4. 15 fps, longest side 960 px.
public enum GIFExporter {
    public static let fps = 15
    public static let longSide = 960.0

    /// 960×540 for 16:9, 540×960 for 9:16, 960×960 for 1:1: the compositor draws straight at this size.
    public static func size(_ aspect: AspectRatio) -> CGSize {
        let canvas = Composer.renderSize(aspect), k = longSide / max(canvas.width, canvas.height)
        return CGSize(width: (canvas.width * k).rounded(), height: (canvas.height * k).rounded())
    }

    public static func export(project: Project, videoURL: URL, to output: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let edit = try Composer.make(project: project, source: try await SourceTracks.load(videoURL, camera: project.camera?.file))
        let vc = edit.videoComposition.mutableCopy() as! AVMutableVideoComposition
        vc.renderSize = size(project.aspect)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let reader = try AVAssetReader(asset: edit.asset)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: edit.asset.tracks(withMediaType: .video),
                                                      videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = vc
        reader.add(out)
        let total = edit.asset.duration.seconds
        let frames = Int((total * Double(fps)).rounded(.up))

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        // the count only sizes the file's index: fewer frames are fine
        guard let gif = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw LoupecastError("Couldn’t start writing.")
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // a cancelled or failed export leaves no half-written file behind
        do {
            guard reader.startReading() else { throw reader.error ?? LoupecastError("Couldn’t start reading.") }
            // One thread reads and stops reading, so cancelReading() never meets a copyNextSampleBuffer() in progress.
            nonisolated(unsafe) let (reader, out, gif) = (reader, out, gif)
            let work = Task.detached(priority: .userInitiated) {
                let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
                var i = 0
                while let buffer = out.copyNextSampleBuffer() {
                    if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                    guard let pb = CMSampleBufferGetImageBuffer(buffer) else { continue }
                    let image = CIImage(cvPixelBuffer: pb)
                    guard let cg = LoupecastCompositor.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb)
                    else { continue }
                    // GIF delays are whole hundredths: 7, 7, 6… keeps 15 fps on average instead of drifting to 14.3
                    let delay = Double(Self.centiseconds(i + 1) - Self.centiseconds(i)) / 100
                    CGImageDestinationAddImage(gif, cg, [kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
                    i += 1
                    progress(min(1, Double(i) / Double(max(1, frames))))
                }
                if reader.status == .failed { throw reader.error ?? LoupecastError("Reading failed") }
                guard CGImageDestinationFinalize(gif) else { throw LoupecastError("Writing failed") }
            }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress(1)
    }

    /// Time of frame `i` in hundredths of a second, rounded.
    static func centiseconds(_ i: Int) -> Int { Int((Double(i) * 100 / Double(fps)).rounded()) }
}
