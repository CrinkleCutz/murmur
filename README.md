# Murmur 🎙️

**Private, unlimited voice dictation for macOS — 100% on-device.**

Hold `fn`, speak, release — clean text appears at your cursor in any app.
No cloud, no subscription, no word limits. Your audio and transcripts never
leave your Mac.

<img src="Resources/screenshot.jpg" alt="Murmur dashboard">

Murmur is an open-source, fully local take on the modern AI dictation app
(in the spirit of Wispr Flow), built natively in Swift on Apple's on-device
speech and language models, with an optional local Whisper engine.

## Features

- **Push-to-talk dictation** — hold `fn` (or right ⌥) anywhere; release to
  paste at your cursor. Double-tap for hands-free mode.
- **Five recognition engines**, all offline:
  - **Apple** — instant, built into macOS (SpeechAnalyzer, macOS 26).
  - **WhisperKit** — precision engine via
    [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML on the
    Neural Engine). Your vocabulary is fed into the decoder prompt.
  - **whisper.cpp** — the same Whisper models, running via Metal on the
    GPU instead, with phrase-based filtering for the sign-off
    hallucinations ("Thank you.", etc.) Whisper-family models are known to
    produce on near-silent audio.
  - **Parakeet** — NVIDIA's model via
    [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML on
    the Neural Engine). Murmur's fastest engine; no vocabulary biasing yet.
  - **sherpa-onnx** — SenseVoice, NVIDIA Canary, or two LLM-backed models
    (FunASR Nano, Qwen3-ASR — a small generative decoder rather than a
    direct CTC/transducer decode, still fully local) via
    [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (ONNX
    Runtime, CPU only — no Neural Engine backend). Experimental: English
    only for now, less tested than the four engines above.
- **Harper grammar pass** — [Harper](https://github.com/Automattic/harper)
  runs alongside the Apple Intelligence edit pass below: deterministic,
  millisecond-speed local linting (agreement, punctuation, repeated words)
  that catches what an LLM edit occasionally misses. No model, no warm-up,
  no network.
- **Per-app profiles** — one place to set what Murmur does when you dictate
  into a specific app: tone and note template together, instead of two
  separate override systems answering "what happens in Slack?" differently.
- **Ask Murmur** — ask questions about your own dictation history, answered
  entirely on-device via lightweight keyword retrieval into the local model
  (no embeddings, no network).
- **Note templates** — restructure a transcript into a specific document
  shape via the on-device LLM; trigger one by voice at the start of a
  dictation, or apply manually.
- **Pronunciation learning** — a Voice Training page learns how *you* say
  tricky words; corrections you make to transcripts are diffed and learned
  automatically; everything biases future recognition.
- **Cleanup pipeline** — filler-word removal, spoken "new line"/"new
  paragraph", auto-capitalization, personal dictionary, snippets
  (say a trigger phrase → paste a saved block).
- **Styles** — per-app tone rewriting (formal / casual / very casual) using
  Apple Intelligence's on-device model.
- **Transforms** — select text in any app, press ⌥1 to polish grammar or ⌥2
  to turn rough notes into a structured AI prompt, rewritten in place.
- **Dashboard** — history with search and correction-learning, usage stats
  (words, WPM, day streak), insights chart, a Voice Profile persona derived
  locally from what you dictate, scratchpad.
- **Guided first run** — welcome → permissions → recognition engine →
  hotkey → mic test, shown once.

## Screenshots

<table>
<tr>
  <td width="50%"><img src="Resources/screenshot-insights.jpg" alt="Insights"><br><sub>Insights</sub></td>
  <td width="50%"><img src="Resources/screenshot-ask.jpg" alt="Ask Murmur"><br><sub>Ask Murmur</sub></td>
</tr>
<tr>
  <td width="50%"><img src="Resources/screenshot-voice-profile.jpg" alt="Voice Profile"><br><sub>Voice Profile</sub></td>
  <td width="50%"><img src="Resources/screenshot-style.jpg" alt="Style"><br><sub>Style</sub></td>
</tr>
<tr>
  <td width="50%"><img src="Resources/screenshot-snippets.jpg" alt="Snippets"><br><sub>Snippets</sub></td>
  <td width="50%"><img src="Resources/screenshot-settings.jpg" alt="Settings"><br><sub>Settings</sub></td>
</tr>
</table>

## Requirements

- macOS 26 (Tahoe) or newer
- Apple Silicon Mac
- Xcode 26 command-line tools (`xcode-select --install`)
- For Styles / Transforms / Voice Profile: Apple Intelligence enabled
- For the Whisper engine: a one-time model download (150 MB – 1.6 GB)

## Build & run

```bash
git clone <this-repo>
cd murmur
./scripts/make_app.sh     # builds build/Murmur.app
open build/Murmur.app
```

Optional: run `./scripts/make_signing_cert.sh` once to create a local
self-signed signing certificate — this keeps macOS permission grants valid
across rebuilds. Without it the app is ad-hoc signed and you'll need to
re-grant Accessibility after each rebuild.

### One-time permissions

1. **Microphone** — allow when prompted on first dictation.
2. **Accessibility** — allow when prompted (needed for the global hotkey and
   for pasting). If the app still shows it as missing, use *Settings →
   Reset Grant & Relaunch* inside Murmur.

## CLI test modes

```bash
.build/debug/Murmur --selftest                          # formatter + learning tests
.build/debug/Murmur --transcribe audio.wav              # Apple engine
.build/debug/Murmur --transcribe audio.wav --engine whisper
.build/debug/Murmur --format "um hello new line hi"     # cleanup pipeline only
.build/debug/Murmur --transform "fix this grammer pls"  # on-device LLM polish
```

## Privacy

Recognition (Apple SpeechAnalyzer or a local speech model), cleanup, tone
rewriting (Apple Intelligence), and Voice Profile analysis run on this Mac.
Dictation data is stored in `~/Library/Application Support/Murmur/`; history
keeps up to 90 days or 5,000 entries and can be cleared from Home. macOS may
download Apple speech assets, and choosing another engine may download its
model from its provider. Source builds check GitHub for app updates. Official
release builds check Murmur's signed update feed and use the licensing server
for activation and roughly weekly license checks; those requests do not
include dictated audio or transcripts.

## Architecture

Swift Package. WhisperKit and FluidAudio are remote SwiftPM dependencies,
each used only if you pick that engine; whisper.cpp/ggml, Harper, and
sherpa-onnx (plus its ONNX Runtime dependency) are vendored as prebuilt
xcframeworks under `Vendor/` (Harper's Rust source is included, the
others' isn't — see [NOTICE.md](NOTICE.md) for all of them).

```
HotkeyMonitor  →  AudioRecorder  →  Transcriber (Apple / WhisperKit / whisper.cpp / Parakeet / sherpa-onnx)
                                        ↓
     TextFormatter → LearnedStore → SnippetStore → RewriteEngine (Styles) → HarperChecker
                                        ↓
                        TextInserter (clipboard + ⌘V)
```

See [PLAN.md](PLAN.md) for the original design document and
[CHANGELOG.md](CHANGELOG.md) for what's new in each release.

## License

[MIT](LICENSE). Not affiliated with Wispr Flow, OpenAI, NVIDIA, or Apple.
