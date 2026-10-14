import AVFoundation
import LoupecastCore
import Speech

/// The microphone recognized on this Mac (requiresOnDeviceRecognition: the sound never leaves it), as caption lines in
/// recording time. The language is the system's.
enum Transcriber {
    /// The microphone track alone as a temporary m4a that starts at recording time 0 (the recorder writes it mono).
    static func microphoneAudio(_ movie: URL) async throws -> URL {
        let asset = AVURLAsset(url: movie)
        var mic: AVAssetTrack?
        for t in try await asset.loadTracks(withMediaType: .audio) {
            let formats = try await t.load(.formatDescriptions)
            if formats.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }) == 1 { mic = t }
        }
        guard let mic else { throw LoupecastError("The recording has no microphone sound.") }
        let range = try await mic.load(.timeRange)
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LoupecastError("The recording has no microphone sound.")
        }
        try track.insertTimeRange(range, of: mic, at: range.start)          // a late start stays late: times are recording time
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw LoupecastError("Couldn’t start writing.")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("loupecast-mic-\(UUID().uuidString).m4a")
        try await session.export(to: out, as: .m4a)
        return out
    }

    /// Asks for Speech Recognition the first time (Info.plist NSSpeechRecognitionUsageDescription).
    static func authorize() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in SFSpeechRecognizer.requestAuthorization { _ in done.resume() } }
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// The recognizer for the system language, if this Mac can run it offline.
    static var recognizer: SFSpeechRecognizer? {
        (SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()).flatMap { $0.supportsOnDeviceRecognition ? $0 : nil }
    }

    /// `progress` gets the share of `duration` recognized so far when the recognizer reports times, else nothing.
    static func captions(_ movie: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Caption] {
        guard let recognizer = recognizer else {
            let language = Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier
            throw LoupecastError("This Mac can’t recognize \(language) speech offline.")
        }
        guard await authorize() else {
            throw LoupecastError("Turn on Loupecast in System Settings › Privacy & Security › Speech Recognition.")
        }
        let audio = try await microphoneAudio(movie)
        defer { try? FileManager.default.removeItem(at: audio) }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        let box = Recognition()
        let words = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<[(start: Double, end: Double, text: String)], Error>) in
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let segments = result.bestTranscription.segments
                        // partial results may carry no times; a result with times replaces the words from its first one on
                        if let first = segments.first, segments.contains(where: { $0.timestamp > 0 || $0.duration > 0 }) {
                            let new = segments.map { (start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring) }
                            box.words = box.words.filter { $0.end <= first.timestamp + 0.01 } + new
                            progress(min(1, (new.last?.end ?? 0) / max(0.1, duration)))
                        }
                        if result.isFinal { box.finish(done, .success(box.words)) }
                    } else if let error {
                        box.finish(done, box.words.isEmpty ? .failure(error) : .success(box.words))
                    }
                }
            }
        } onCancel: { box.task?.cancel() }
        try Task.checkCancellation()
        return Caption.lines(words)
    }
}

/// The recognition's state, touched by its result handler (one at a time).
private final class Recognition: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
    var words: [(start: Double, end: Double, text: String)] = []
    private var resumed = false

    func finish(_ done: CheckedContinuation<[(start: Double, end: Double, text: String)], Error>,
                _ result: Result<[(start: Double, end: Double, text: String)], Error>) {
        guard !resumed else { return }
        resumed = true
        done.resume(with: result)
    }
}
