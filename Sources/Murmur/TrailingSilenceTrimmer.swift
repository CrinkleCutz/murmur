import AVFoundation
import Foundation

/// Cuts the silent tail off a recording before a Whisper-family engine sees it.
///
/// Whisper decodes audio in 30-second windows. A recording that runs a little
/// past 30 seconds — speech ending just before the mark, then a second or two
/// of quiet — leaves a final window with nothing in it, and the model fills
/// that window with the sign-off it saw after silence in its training data:
/// "Thank you." Measured, not assumed: in one real history, 3 of 41 recordings
/// between 30 and 40 seconds ended with a "Thank you." the speaker never said,
/// and none of the other 459 did. Reproduced with synthetic speech ending at
/// 29.0–29.4 s plus 1.2–2.6 s of room-level noise — whisper.cpp
/// (large-v3-turbo) appended "Thank you." three times out of four and a stray
/// ". ." the fourth — and the identical audio with its tail cut to a
/// half-second pad transcribed cleanly.
///
/// `HallucinationFilter` can't cover this: it only recognizes a dictation
/// that is *entirely* the phrase, and extending it to trailing sentences would
/// delete a real "Thank you." at the end of a dictated email. Removing the
/// silence removes the cause instead, for every phrase the model might invent
/// there, and costs nothing when the speaker really did say it — the speech
/// is what marks where the recording ends.
///
/// Conservative on purpose, because cutting real speech is far worse than
/// leaving silence in: only the tail, only when the voice-activity model found
/// no possible speech in it, only when that stretch is also quiet by raw
/// energy, only for recordings long enough to reach a second window, and
/// always leaving a pad after the last speech. Every failure path returns `nil` — "use the
/// original" — never a shortened recording.
enum TrailingSilenceTrimmer {
    /// Kept after the last speech so a decaying final word isn't clipped.
    static let padSeconds = 0.5
    /// Only recordings around Whisper's 30-second window or longer can end
    /// in a silent leftover window; shorter ones decode in one piece, and
    /// measured clean with a 1.8 s tail at 26.6 s and 29.6 s.
    static let minimumRecordingSeconds = 28.0
    /// Not worth touching a recording for less than this.
    static let minimumTrimSeconds = 0.2
    /// A removed stretch containing any ~100 ms of audio at least this loud is
    /// not silence. Same value as `AudioRecorder`'s silence threshold.
    static let audibleRMS: Float = 0.01

    /// Where to cut, in seconds from the start — or nil when nothing should
    /// be cut. Pure: the decision, separate from the file handling.
    static func cutPoint(totalSeconds: Double, speechEnd: Double) -> Double? {
        let keep = speechEnd + padSeconds
        guard speechEnd > 0, totalSeconds >= minimumRecordingSeconds,
              totalSeconds - keep >= minimumTrimSeconds else { return nil }
        return keep
    }

    /// A copy of `url` ending shortly after `speechEnd`, or nil to use the
    /// original as is. The caller deletes the copy.
    static func trimmedCopy(of url: URL, speechEnd: TimeInterval) -> URL? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, let cut = cutPoint(totalSeconds: Double(file.length) / rate, speechEnd: speechEnd)
        else { return nil }
        let cutFrame = AVAudioFramePosition(cut * rate)
        guard cutFrame > 0, cutFrame < file.length,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10))
        else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-trimmed-\(UUID().uuidString).caf")
        do {
            // The stretch that would go must really be quiet.
            file.framePosition = cutFrame
            while file.framePosition < file.length {
                try file.read(into: chunk)
                if chunk.frameLength == 0 { break }
                if !isQuiet(chunk) { return nil }
            }
            // Copy everything before the cut. `AVAudioFile.read` may hand
            // back fewer frames than asked for (measured: 87,040 of 88,000
            // in one call), so it's read in a loop until the count is met —
            // a single read would silently shorten the recording.
            file.framePosition = 0
            let trimmed = try AVAudioFile(forWriting: output, settings: file.fileFormat.settings)
            var copied: AVAudioFramePosition = 0
            while copied < cutFrame {
                let wanted = AVAudioFrameCount(min(AVAudioFramePosition(chunk.frameCapacity), cutFrame - copied))
                try file.read(into: chunk, frameCount: wanted)
                guard chunk.frameLength > 0 else { break }
                try trimmed.write(from: chunk)
                copied += AVAudioFramePosition(chunk.frameLength)
            }
            trimmed.close()
            guard copied == cutFrame else {
                try? FileManager.default.removeItem(at: output)
                return nil
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
    }

    /// True when the buffer's overall level is below `audibleRMS`.
    static func isQuiet(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return true }
        var sum: Float = 0
        for channel in 0..<channelCount {
            for i in 0..<frames { sum += channels[channel][i] * channels[channel][i] }
        }
        return (sum / Float(frames * channelCount)).squareRoot() < audibleRMS
    }

    static func runSelfTest() -> Bool {
        var passed = true
        func check(_ ok: Bool, _ label: String) {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \(label)")
        }

        // The decision.
        check(cutPoint(totalSeconds: 31.2, speechEnd: 29.4).map { abs($0 - 29.9) < 1e-9 } ?? false,
              "cuts 0.5 s after the last speech in the measured failure case")
        check(cutPoint(totalSeconds: 30.2, speechEnd: 29.0).map { abs($0 - 29.5) < 1e-9 } ?? false,
              "cuts the 30.2 s recording that grew a \"Thank you.\" below the 30 s window")
        check(cutPoint(totalSeconds: 30.0, speechEnd: 29.4) == nil, "leaves a trivial tail alone")
        check(cutPoint(totalSeconds: 20.0, speechEnd: 12.0) == nil,
              "leaves a recording shorter than one window alone")
        check(cutPoint(totalSeconds: 40.0, speechEnd: 0) == nil, "does nothing without a speech end")

        // The file handling, on real audio files.
        func makeFile(speech: Double, tail: Double, tailAmplitude: Float) -> URL? {
            let rate = 16000.0
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount((speech + tail) * rate))
            else { return nil }
            buffer.frameLength = buffer.frameCapacity
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                let t = Double(i) / rate
                samples[i] = t < speech ? Float(0.2 * sin(2 * .pi * 220 * t))
                                        : tailAmplitude * Float(sin(2 * .pi * 90 * t))
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("murmur-trim-selftest-\(UUID().uuidString).caf")
            guard let file = try? AVAudioFile(forWriting: url, settings: format.settings),
                  (try? file.write(from: buffer)) != nil else { return nil }
            return url
        }
        func seconds(of url: URL) -> Double? {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }

        if let quiet = makeFile(speech: 29, tail: 3, tailAmplitude: 0.003) {
            defer { try? FileManager.default.removeItem(at: quiet) }
            if let trimmed = trimmedCopy(of: quiet, speechEnd: 29.0) {
                defer { try? FileManager.default.removeItem(at: trimmed) }
                check(abs((seconds(of: trimmed) ?? 0) - 29.5) < 1e-6, "trims a quiet 3 s tail down to exactly a 0.5 s pad, losing no frames")
            } else {
                check(false, "trims a quiet 3 s tail down to a 0.5 s pad")
            }
            check(trimmedCopy(of: quiet, speechEnd: 31.5) == nil, "keeps a recording whose speech runs to the end")
        } else {
            check(false, "could not build the quiet-tail test recording")
        }
        if let loud = makeFile(speech: 29, tail: 3, tailAmplitude: 0.1) {
            defer { try? FileManager.default.removeItem(at: loud) }
            check(trimmedCopy(of: loud, speechEnd: 29.0) == nil,
                  "refuses to cut a tail that is audible, even if the VAD said it was silent")
        } else {
            check(false, "could not build the loud-tail test recording")
        }
        return passed
    }
}
