import FluidAudio
import Foundation

/// A sharper, second opinion on top of `AudioRecorder`'s RMS-based silence
/// gate, using FluidAudio's real voice-activity-detection model instead of
/// raw signal amplitude. Not a recognition engine and not user-facing: no
/// Settings row, no model choice — it's invisible pipeline infrastructure
/// that runs regardless of which recognition engine is selected.
///
/// Deliberately not used inside `AudioRecorder`'s real-time audio tap: that
/// callback runs synchronously on a real-time audio thread, and this is an
/// `async` call into an actor — mixing the two risks audio glitches. Instead
/// this runs once, after recording stops, on the completed file, as an
/// additional gate before the (expensive) recognition engine runs — never
/// instead of `AudioRecorder`'s existing gate, only in addition to it.
@MainActor
final class VadEngine {
    private var manager: VadManager?
    private var loadTask: Task<VadManager, Error>?

    /// Kicks off model load/download in the background.
    func preload() {
        Task { _ = try? await self.pipeline() }
    }

    private func pipeline() async throws -> VadManager {
        if let manager {
            return manager
        }
        if let loadTask {
            return try await loadTask.value
        }
        let task = Task { try await VadManager() }
        loadTask = task
        let loaded = try await task.value
        manager = loaded
        return loaded
    }

    /// The loaded model, for callers doing more than a one-shot file check
    /// (`TurnDetector`'s live streaming session). `nil` while still loading
    /// or on failure — same fail-open contract as `hasNoDetectedSpeech`.
    func loadedManager() async -> VadManager? {
        try? await pipeline()
    }

    /// True only when VAD confidently found zero speech anywhere in the
    /// recording. Fails open on any problem — model still loading, a
    /// processing error — by returning `false`, the same philosophy as
    /// `AudioRecorder.hasSignal`'s own doc comment: failing open means a
    /// VAD hiccup can only ever let a recording through for recognition as
    /// normal, never silently discard a real dictation.
    func hasNoDetectedSpeech(fileAt url: URL) async -> Bool {
        guard let analysis = await analyze(fileAt: url) else { return false }
        return !analysis.hasSpeech
    }

    /// What the voice-activity model found in a finished recording.
    struct SpeechAnalysis {
        /// The model was confident there was speech somewhere.
        let hasSpeech: Bool
        /// Where the last chunk that looks like speech ends, in seconds
        /// from the start. Looser than `hasSpeech`, which needs the manager's
        /// own 0.85 confidence somewhere.
        let lastSpeechEnd: TimeInterval?
    }

    /// The probability at which a chunk counts as speech when locating the
    /// end of the speech — the usual Silero cut. Measured: real (synthetic
    /// TTS) speech scores 1.00, while a near-silent room-tone tail scores
    /// about 0.2 — a lower floor read that tail as speech and put the "end of
    /// speech" a second late.
    private static let speechEndProbability: Float = 0.5

    /// One pass over the file for both questions. `nil` on any problem
    /// (model still loading, a processing error) — callers fail open, same
    /// as `hasNoDetectedSpeech`.
    func analyze(fileAt url: URL) async -> SpeechAnalysis? {
        guard let manager = try? await pipeline() else { return nil }
        guard let results = try? await manager.process(url) else { return nil }
        let chunkSeconds = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
        let lastSpeech = results.lastIndex { $0.probability >= Self.speechEndProbability }
        return SpeechAnalysis(
            hasSpeech: results.contains { $0.isVoiceActive },
            lastSpeechEnd: lastSpeech.map { Double($0 + 1) * chunkSeconds })
    }
}
