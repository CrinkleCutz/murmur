#ifndef MURMUR_SHERPA_SHIM_H
#define MURMUR_SHERPA_SHIM_H

#include <stdint.h>

// A thin C wrapper around sherpa-onnx's own C API (Vendor/sherpa-onnx.xcframework,
// vendored from the official `sherpa-onnx` PyPI wheel — see NOTICE.md). The
// real API's SherpaOnnxOfflineRecognizerConfig is a large, deeply nested
// struct with ~20 alternate model-family sub-configs (Whisper, Paraformer,
// Canary, ...); Swift auto-imports C structs with a memberwise initializer
// that requires every field, which would mean spelling out every field of
// every sub-config by hand at the call site. Isolating the zero-init +
// SenseVoice-only field selection here means Swift only ever sees an opaque
// handle and plain scalars/strings.
typedef void *MurmurSherpaRecognizer;

/// Creates a SenseVoice-backed offline (non-streaming) recognizer from a
/// model + tokens file already on disk. `language` is a hint ("en", or
/// "auto" to let the model detect it); non-zero `use_itn` turns on inverse
/// text normalization (e.g. "twelve" -> "12"). Returns NULL on failure —
/// the underlying C API doesn't report why (bad path, corrupt model, etc).
MurmurSherpaRecognizer MurmurSherpaCreateSenseVoiceRecognizer(
    const char *model_path, const char *tokens_path, const char *language,
    int use_itn, int num_threads);

/// Creates a Zipformer-transducer-backed offline recognizer (encoder/
/// decoder/joiner triple — k2-fsa's own architecture, English-only model).
/// `bpe_vocab_path` is this specific checkpoint's BPE tokenizer model
/// (`bpe.model`) — required for it to produce real casing and punctuation
/// instead of the flat, uppercase-only output k2-fsa's older, plainer
/// LibriSpeech-trained Zipformer checkpoints give. Returns NULL on failure.
MurmurSherpaRecognizer MurmurSherpaCreateZipformerRecognizer(
    const char *encoder_path, const char *decoder_path,
    const char *joiner_path, const char *tokens_path,
    const char *bpe_vocab_path, int num_threads);

/// Creates a Moonshine-backed offline recognizer (Useful Sensors' small,
/// fast English model — four separate ONNX stages rather than one). Returns
/// NULL on failure.
MurmurSherpaRecognizer MurmurSherpaCreateMoonshineRecognizer(
    const char *preprocessor_path, const char *encoder_path,
    const char *uncached_decoder_path, const char *cached_decoder_path,
    const char *tokens_path, int num_threads);

/// Creates an NVIDIA Canary-backed offline recognizer (180M "flash" variant
/// — genuinely multilingual: en/es/de/fr). `src_lang`/`tgt_lang` are both
/// "en" for plain English transcription; Canary is translation-capable, but
/// nothing here uses that. Returns NULL on failure.
MurmurSherpaRecognizer MurmurSherpaCreateCanaryRecognizer(
    const char *encoder_path, const char *decoder_path,
    const char *tokens_path, const char *src_lang, const char *tgt_lang,
    int num_threads);

/// Creates a FunASR Nano-backed offline recognizer — a SenseVoice-style
/// encoder/adaptor feeding a small (Qwen3-0.6B) LLM decoder, rather than a
/// direct CTC/transducer decode like every other model here.
/// `tokenizer_dir_path` is a directory (the Qwen3 tokenizer's own
/// merges.txt/tokenizer.json/vocab.json live inside it), not a single file.
/// Sampling/prompt fields are fixed to the same values the Python
/// reference bindings default to, verified directly rather than guessed —
/// this family has no exposed knobs Murmur needs to vary. Returns NULL on
/// failure.
MurmurSherpaRecognizer MurmurSherpaCreateFunAsrNanoRecognizer(
    const char *encoder_adaptor_path, const char *llm_path,
    const char *embedding_path, const char *tokenizer_dir_path,
    int num_threads);

/// Creates a Qwen3-ASR-backed offline recognizer (Alibaba's 0.6B-parameter
/// LLM-based ASR model — the heaviest of the sherpa-onnx models here).
/// `tokenizer_dir_path` is a directory, same as FunASR Nano's. Returns NULL
/// on failure.
MurmurSherpaRecognizer MurmurSherpaCreateQwen3AsrRecognizer(
    const char *conv_frontend_path, const char *encoder_path,
    const char *decoder_path, const char *tokenizer_dir_path,
    int num_threads);

void MurmurSherpaDestroyRecognizer(MurmurSherpaRecognizer recognizer);

/// Runs one full offline decode over 16kHz mono Float32 PCM samples.
/// Returns a newly malloc'd, NUL-terminated UTF-8 string the caller must
/// free() — or NULL on failure. Isolates the raw C API's two-object
/// lifecycle (an offline stream AND its result each need their own create/
/// destroy call) behind one call so the Swift side only ever deals with a
/// string in, a string out.
/// The same decode, returning sherpa-onnx's whole result as JSON — text, tokens and, where the model gives them, each
/// token's log probability ("ys_log_probs") — for the unsure-word name fix. Caller frees it with free().
char *MurmurSherpaTranscribeJSON(
    MurmurSherpaRecognizer recognizer,
    const float *samples, int32_t sample_count, int32_t sample_rate);

char *MurmurSherpaTranscribe(
    MurmurSherpaRecognizer recognizer,
    const float *samples, int32_t sample_count, int32_t sample_rate);

#endif
