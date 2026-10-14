import AVFoundation
import FluidAudio
import Foundation

/// Transcribe while you talk: a long whisper.cpp dictation is cut at a natural pause, and what was already said is
/// transcribed while the speaker carries on — so letting go of the key leaves only the last stretch to decode.
///
/// Why: Whisper decodes in 30-second windows and every window costs the same however little speech is in it
/// (measured 2026-09-28 on an M2 Max: 0.44 s for 5 s of speech, 0.98 s for 33 s, 1.15 s for 51 s — the jump is the
/// second window; a Mac with a smaller graphics chip pays several times that). With the earlier stretches already
/// done, the wait after release is one window again, however long the dictation ran.
///
/// Each stretch gets the same vocabulary prompt as a whole dictation, but not the text of the stretches before it —
/// measured on the Deepgram test set (scripts/eval): with the earlier text in the prompt whisper.cpp repeated
/// sentences from it (errors on the recordings that were cut 2.0% → 3.7%); without it, 3.2% → 3.1%, and the
/// sentence it had invented at the end of a 45-second recording was gone.
///
/// Nothing changes for a dictation shorter than `ChunkPlanner.forceCutAt`: no cut is ever made, and
/// `finish` returns nil so the caller runs the unchanged whole-recording path. Any failure does the same.
@MainActor
final class LiveChunkSession {
    let model: String
    let localeID: String
    let biasTerms: [String]
    /// Set once the field turns out to be a shell (`WhisperPrompt.shell`); read for each stretch decoded after that.
    var prompt: String? {
        get { promptLock.lock(); defer { promptLock.unlock() }; return storedPrompt }
        set { promptLock.lock(); storedPrompt = newValue; promptLock.unlock() }
    }
    private var storedPrompt: String?
    private let promptLock = NSLock()
    private let engine: WhisperCppEngine
    private let vadProvider: () async -> VadManager?

    /// 16 kHz mono audio so far, appended from the recorder's tap thread.
    private let audio = LiveAudioBuffer()
    /// Voice-activity probability per `VadManager.chunkSize` frame of `audio`, computed on the main actor.
    private var probabilities: [Float] = []
    private var vadState: VadStreamState?
    private var committedSeconds: Double = 0
    private var chunkTexts: [String] = []
    private var confidences: [(value: Float, seconds: Double)] = []
    private var work: Task<Void, Never>?
    private var failed = false
    private var poller: Task<Void, Never>?
    /// Debug only, for measuring the cost of a cut from the command line: a shorter minimum stretch, so more cuts.
    private let minimumChunk = ProcessInfo.processInfo.environment["MURMUR_CHUNK_MIN"].flatMap(Double.init)
        ?? ChunkPlanner.minimumChunk
    /// With that debug minimum, a cut is made as soon as it is reached.
    private let cutAfter = ProcessInfo.processInfo.environment["MURMUR_CHUNK_MIN"] == nil ? ChunkPlanner.forceCutAt : 0

    init(
        engine: WhisperCppEngine, vad vadProvider: @escaping () async -> VadManager?,
        model: String, localeID: String, biasTerms: [String]
    ) {
        self.engine = engine
        self.vadProvider = vadProvider
        self.model = model
        self.localeID = localeID
        self.biasTerms = biasTerms
    }

    /// Called from the recorder's tap: must return at once, so it only resamples and appends.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        audio.append(buffer)
    }

    /// Looks for a cut every half second while recording.
    func start() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                await self.advance(to: nil)
            }
        }
    }

    /// Processes the audio up to `end` (all of it when nil): new voice-activity frames, then at most one new cut,
    /// whose stretch starts decoding behind any earlier one.
    func advance(to end: Int?) async {
        guard !failed else { return }
        let samples = audio.snapshot(upTo: end)
        guard await analyze(samples) else { failed = true; return }
        let frameSeconds = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
        guard let cut = ChunkPlanner.nextCut(
            probabilities: probabilities, frameSeconds: frameSeconds, from: committedSeconds,
            minimumChunk: minimumChunk, cutAfter: cutAfter) else { return }
        let from = Int(committedSeconds * 16000), to = min(Int(cut * 16000), samples.count)
        guard to > from else { return }
        let stretch = Array(samples[from..<to])
        committedSeconds = cut
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self, !self.failed else { return }
            do {
                let (text, confidence) = try await self.engine.transcribe(
                    samples: stretch, model: self.model, localeID: self.localeID, biasTerms: self.biasTerms,
                    reportsStatus: false, prompt: self.prompt)
                self.chunkTexts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let confidence { self.confidences.append((confidence, Double(stretch.count) / 16000)) }
                dictationLog.info("live chunks: stretch \(self.chunkTexts.count) done, \(stretch.count / 16000) s")
            } catch {
                self.failed = true
                dictationLog.error("live chunks: stretch failed, whole recording will be used: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Voice-activity probabilities for every whole frame of `samples` not yet looked at. False when the model failed.
    private func analyze(_ samples: [Float]) async -> Bool {
        let frame = VadManager.chunkSize
        guard (probabilities.count + 1) * frame <= samples.count else { return true }
        guard let vad = await vadProvider() else { return true }
        while (probabilities.count + 1) * frame <= samples.count {
            let start = probabilities.count * frame
            if vadState == nil { vadState = await vad.makeStreamState() }
            guard let state = vadState,
                  let result = try? await vad.processStreamingChunk(Array(samples[start..<start + frame]), state: state)
            else { return false }
            vadState = result.state
            probabilities.append(result.probability)
        }
        return true
    }

    /// Waits for every stretch cut so far — for the command line, which feeds a whole recording at once, so that what
    /// it times afterwards is only what a live dictation waits for after the key is released.
    func waitForStretches() async {
        await work?.value
    }

    /// Stops listening. The whole dictation's text when at least one stretch was transcribed while recording — the
    /// finished stretches plus the rest of `recording` (the same file, and the same trailing-silence trim, the
    /// whole-recording path uses) — or nil, meaning "use the whole recording as before".
    func finish(recording url: URL) async -> (text: String, confidence: Float?, stretches: Int)? {
        poller?.cancel()
        poller = nil
        await work?.value
        guard !failed, !chunkTexts.isEmpty else { return nil }
        do {
            let all = try WhisperCppEngine.pcm16kMono(from: url)
            let from = Int(committedSeconds * 16000)
            var texts = chunkTexts
            var weights = confidences
            if await speechAfterLastCut(), all.count - from >= 16000 / 4 {
                let (text, confidence) = try await engine.transcribe(
                    samples: Array(all[from...]), model: model, localeID: localeID, biasTerms: biasTerms, prompt: prompt)
                texts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let confidence { weights.append((confidence, Double(all.count - from) / 16000)) }
            }
            let seconds = weights.reduce(0) { $0 + $1.seconds }
            let confidence = seconds > 0
                ? Float(weights.reduce(0) { $0 + Double($1.value) * $1.seconds } / seconds) : nil
            return (ChunkPlanner.join(texts), confidence, texts.count)
        } catch {
            dictationLog.error("live chunks: tail failed, whole recording will be used: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether anything was said after the last cut. Nothing is left to decode when the key was held through a pause
    /// after the last word — Whisper fed only silence may invent a sign-off — so the rest is skipped only when the
    /// voice-activity model heard no speech there and the last sliver it hasn't seen is quiet too; any doubt decodes it.
    private func speechAfterLastCut() async -> Bool {
        let heard = audio.snapshot(upTo: nil)
        guard await analyze(heard) else { return true }
        let frame = VadManager.chunkSize
        let firstAfterCut = Int((committedSeconds * Double(VadManager.sampleRate) / Double(frame)).rounded())
        if probabilities.count > firstAfterCut,
           probabilities[firstAfterCut...].contains(where: { $0 >= ChunkPlanner.speechThreshold }) { return true }
        let analyzedEnd = probabilities.count * frame
        guard heard.count > analyzedEnd else { return false }
        let rate = Double(VadManager.sampleRate)
        return WhisperCppEngine.rms(heard, from: Double(analyzedEnd) / rate, to: Double(heard.count) / rate)
            >= TrailingSilenceTrimmer.audibleRMS
    }

    func cancel() {
        poller?.cancel()
        poller = nil
        work?.cancel()
        failed = true
    }
}

/// 16 kHz mono samples appended from the audio thread and read on the main actor.
final class LiveAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private let converter = AudioConverter()

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? converter.resampleBuffer(buffer) else { return }
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
    }

    func snapshot(upTo end: Int?) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard let end, end < samples.count else { return samples }
        return Array(samples[..<end])
    }
}

extension LiveChunkSession {
    /// The command line's stand-in for a live recording: the file is fed through `append` in 4096-frame buffers at its
    /// own sample rate — the recorder tap's path, resampling included — looking for a cut after every half second.
    func simulate(recording url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return }
        var fed = 0.0, lastLook = 0.0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 4096)
            guard buffer.frameLength > 0 else { break }
            append(buffer)
            fed += Double(buffer.frameLength) / rate
            if fed - lastLook >= 0.5 {
                lastLook = fed
                await advance(to: nil)
            }
        }
        await advance(to: nil)
    }
}

/// Where to cut a dictation that is still being spoken. Pure, so it can be tested without audio.
enum ChunkPlanner {
    /// A cut is never placed sooner than this after the last one, so each stretch keeps enough context for Whisper to
    /// punctuate it well.
    static let minimumChunk = 16.0
    /// Nothing is cut before this much audio has built up since the last cut: a dictation that fits in one of
    /// Whisper's 30-second windows is decoded whole, since a cut saves it no waiting and costs it context (measured
    /// 2026-10-11, the 150 test recordings cut at 16 s against whole: 3.50% word errors against 3.36%, six worse and
    /// two better, the worse ones accented voices). Past it, the cut goes in the latest clear pause — or, with none,
    /// at the quietest moment — so no stretch spills into a second window.
    static let forceCutAt = 27.0
    /// A pause at least this long is a place a sentence or clause ends.
    static let minimumPause = 0.5
    static let speechThreshold: Float = 0.5

    /// The next cut, in seconds from the start, or nil to keep listening.
    static func nextCut(
        probabilities: [Float], frameSeconds: Double, from committed: Double, minimumChunk: Double = minimumChunk,
        cutAfter: Double = forceCutAt
    ) -> Double? {
        let first = Int((committed / frameSeconds).rounded())
        guard probabilities.count > first,
              Double(probabilities.count - first) * frameSeconds >= max(minimumChunk, cutAfter) else { return nil }
        let earliest = first + Int(minimumChunk / frameSeconds)
        let pauseFrames = max(1, Int((minimumPause / frameSeconds).rounded(.up)))
        // The latest pause that is long enough, cut in its middle.
        var best: Int?
        var runStart: Int?
        for index in first..<probabilities.count {
            if probabilities[index] < speechThreshold {
                if runStart == nil { runStart = index }
                if let start = runStart, index - start + 1 >= pauseFrames, start >= earliest {
                    best = start + (index - start + 1) / 2
                }
            } else {
                runStart = nil
            }
        }
        if let best { return Double(best) * frameSeconds }
        let window = earliest..<max(earliest + 1, probabilities.count - 1)
        guard let quietest = window.filter({ $0 < probabilities.count }).min(by: { probabilities[$0] < probabilities[$1] })
        else { return nil }
        return Double(quietest) * frameSeconds
    }

    /// The stretches' texts as one dictation.
    static func join(_ texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): live chunks: \(label)")
        }
        let f = 0.256
        func frames(_ seconds: Double, _ p: Float) -> [Float] { Array(repeating: p, count: Int((seconds / f).rounded())) }
        let paused = frames(10, 0.9) + frames(1, 0.1) + frames(8, 0.9) + frames(0.8, 0.1) + frames(2, 0.9)
        check(nextCut(probabilities: paused, frameSeconds: f, from: 0) == nil,
              "a dictation that fits in one pass is never cut, pauses or not")
        let cut = nextCut(probabilities: paused + frames(6, 0.9), frameSeconds: f, from: 0)
        check(cut.map { $0 > 18.5 && $0 < 19.6 } == true, "past 27 s: the latest pause after 16 s (got \(cut ?? -1))")
        let early = frames(10, 0.9) + frames(1, 0.1) + frames(15, 0.9)
        check(nextCut(probabilities: early, frameSeconds: f, from: 0) == nil, "a pause before 16 s is not used")
        let breath = frames(17, 0.9) + frames(0.25, 0.1) + frames(9, 0.9)
        check(nextCut(probabilities: breath, frameSeconds: f, from: 0) == nil, "a breath is not a pause")
        let unbroken = frames(18, 0.9) + frames(0.3, 0.6) + frames(10, 0.9)
        let forced = nextCut(probabilities: unbroken, frameSeconds: f, from: 0)
        check(forced.map { abs($0 - 18.2) < 0.4 } == true, "no pause by 27 s: the quietest moment (got \(forced ?? -1))")
        let second = paused + frames(26, 0.9) + frames(1, 0.1) + frames(1, 0.9)
        let next = nextCut(probabilities: second, frameSeconds: f, from: 18.5)
        check(next.map { $0 > 34.5 } == true, "the next cut counts from the last one (got \(next ?? -1))")
        check(nextCut(probabilities: paused, frameSeconds: f, from: 0, cutAfter: 0).map { $0 > 18.5 && $0 < 19.6 } == true,
              "the debug minimum cuts as soon as it is reached")
        check(join(["First part.", "", "and the rest."]) == "First part. and the rest.", "stretches join with a space")
        return passed
    }
}
