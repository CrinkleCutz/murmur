#include "include/shim.h"

#include <sherpa_onnx/c-api.h>
#include <stdlib.h>
#include <string.h>

MurmurSherpaRecognizer MurmurSherpaCreateSenseVoiceRecognizer(
    const char *model_path, const char *tokens_path, const char *language,
    int use_itn, int num_threads) {
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));

  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;

  config.model_config.sense_voice.model = model_path;
  config.model_config.sense_voice.language = language;
  config.model_config.sense_voice.use_itn = use_itn;
  config.model_config.tokens = tokens_path;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";

  config.decoding_method = "greedy_search";

  return (MurmurSherpaRecognizer)SherpaOnnxCreateOfflineRecognizer(&config);
}

MurmurSherpaRecognizer MurmurSherpaCreateZipformerRecognizer(
    const char *encoder_path, const char *decoder_path,
    const char *joiner_path, const char *tokens_path,
    const char *bpe_vocab_path, int num_threads) {
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));

  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;

  config.model_config.transducer.encoder = encoder_path;
  config.model_config.transducer.decoder = decoder_path;
  config.model_config.transducer.joiner = joiner_path;
  config.model_config.tokens = tokens_path;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";
  config.model_config.model_type = "transducer";
  config.model_config.modeling_unit = "bpe";
  config.model_config.bpe_vocab = bpe_vocab_path;

  config.decoding_method = "greedy_search";

  return (MurmurSherpaRecognizer)SherpaOnnxCreateOfflineRecognizer(&config);
}

MurmurSherpaRecognizer MurmurSherpaCreateMoonshineRecognizer(
    const char *preprocessor_path, const char *encoder_path,
    const char *uncached_decoder_path, const char *cached_decoder_path,
    const char *tokens_path, int num_threads) {
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));

  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;

  config.model_config.moonshine.preprocessor = preprocessor_path;
  config.model_config.moonshine.encoder = encoder_path;
  config.model_config.moonshine.uncached_decoder = uncached_decoder_path;
  config.model_config.moonshine.cached_decoder = cached_decoder_path;
  config.model_config.tokens = tokens_path;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";

  config.decoding_method = "greedy_search";

  return (MurmurSherpaRecognizer)SherpaOnnxCreateOfflineRecognizer(&config);
}

MurmurSherpaRecognizer MurmurSherpaCreateCanaryRecognizer(
    const char *encoder_path, const char *decoder_path,
    const char *tokens_path, const char *src_lang, const char *tgt_lang,
    int num_threads) {
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));

  // Canary's own feature extractor was trained on 128-dim features, not
  // the 80 every other model here uses.
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 128;

  config.model_config.canary.encoder = encoder_path;
  config.model_config.canary.decoder = decoder_path;
  config.model_config.canary.src_lang = src_lang;
  config.model_config.canary.tgt_lang = tgt_lang;
  // The Python bindings' own OfflineCanaryModelConfig defaults use_pnc to
  // true (verified directly — the plain zero-init this file uses
  // everywhere else would silently turn punctuation/capitalization off,
  // unlike every other struct here where a zeroed field is the correct
  // "unused" default).
  config.model_config.canary.use_pnc = 1;
  config.model_config.tokens = tokens_path;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";

  config.decoding_method = "greedy_search";

  return (MurmurSherpaRecognizer)SherpaOnnxCreateOfflineRecognizer(&config);
}

MurmurSherpaRecognizer MurmurSherpaCreateFunAsrNanoRecognizer(
    const char *encoder_adaptor_path, const char *llm_path,
    const char *embedding_path, const char *tokenizer_dir_path,
    int num_threads) {
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));

  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;

  config.model_config.funasr_nano.encoder_adaptor = encoder_adaptor_path;
  config.model_config.funasr_nano.llm = llm_path;
  config.model_config.funasr_nano.embedding = embedding_path;
  config.model_config.funasr_nano.tokenizer = tokenizer_dir_path;
  // Matches the Python reference bindings' own defaults exactly (verified
  // directly, not guessed) — this family's prompt/sampling fields aren't
  // exposed as user-facing options here, so there's no reason to diverge.
  //
  // Unlike Qwen3-ASR just above, there's no max_total_len knob to raise
  // here at all — checked exhaustively (Python's `OfflineFunASRNanoModelConfig`
  // has no such attribute, not just an unexposed default). This family's
  // 512-token prompt+audio budget is baked into the ONNX graph at export
  // time (see Wasser1462/FunASR-nano-onnx's `export_llm_onnx.py --seq-len
  // 256 --past-len 256`, 256+256=512), so audio past ~20-30s decodes to an
  // empty string with no runtime fix available — only a re-export with the
  // original PyTorch checkpoint and larger values would raise this.
  config.model_config.funasr_nano.system_prompt = "You are a helpful assistant.";
  config.model_config.funasr_nano.user_prompt = "Transcribe the audio:";
  config.model_config.funasr_nano.max_new_tokens = 512;
  config.model_config.funasr_nano.temperature = 1e-6f;
  config.model_config.funasr_nano.top_p = 0.8f;
  config.model_config.funasr_nano.seed = 42;
  config.model_config.funasr_nano.itn = 1;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";

  config.decoding_method = "greedy_search";

  return (MurmurSherpaRecognizer)SherpaOnnxCreateOfflineRecognizer(&config);
}

MurmurSherpaRecognizer MurmurSherpaCreateQwen3AsrRecognizer(
    const char *conv_frontend_path, const char *encoder_path,
    const char *decoder_path, const char *tokenizer_dir_path,
    int num_threads) {
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));

  // Qwen3-ASR's own feature extractor was trained on 128-dim features,
  // same as Canary — not the 80 most models here use.
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 128;

  config.model_config.qwen3_asr.conv_frontend = conv_frontend_path;
  config.model_config.qwen3_asr.encoder = encoder_path;
  config.model_config.qwen3_asr.decoder = decoder_path;
  config.model_config.qwen3_asr.tokenizer = tokenizer_dir_path;
  // Deliberately NOT the Python reference bindings' defaults (512/128) —
  // those are sized for short ASR utterances, not dictation. Verified
  // directly: at 512, audio past ~20-30s pushes context_len over budget
  // and decode returns garbage (an 8-character fragment on a 45s test
  // clip); raising max_total_len alone still truncated output on
  // max_new_tokens, so both need to move together. 1024/512 round-tripped
  // that same clip complete and accurate. Unlike FunASR Nano just below,
  // Qwen3-ASR actually exposes max_total_len as a real runtime knob — this
  // isn't hacking around a fixed export-time limit, the model supports it.
  config.model_config.qwen3_asr.max_total_len = 1024;
  config.model_config.qwen3_asr.max_new_tokens = 512;
  config.model_config.qwen3_asr.temperature = 1e-6f;
  config.model_config.qwen3_asr.top_p = 0.8f;
  config.model_config.qwen3_asr.seed = 42;
  config.model_config.num_threads = num_threads;
  config.model_config.provider = "cpu";

  config.decoding_method = "greedy_search";

  return (MurmurSherpaRecognizer)SherpaOnnxCreateOfflineRecognizer(&config);
}

void MurmurSherpaDestroyRecognizer(MurmurSherpaRecognizer recognizer) {
  if (recognizer) {
    SherpaOnnxDestroyOfflineRecognizer(
        (const SherpaOnnxOfflineRecognizer *)recognizer);
  }
}

char *MurmurSherpaTranscribeJSON(
    MurmurSherpaRecognizer recognizer,
    const float *samples, int32_t sample_count, int32_t sample_rate) {
  if (!recognizer) return NULL;
  const SherpaOnnxOfflineRecognizer *r =
      (const SherpaOnnxOfflineRecognizer *)recognizer;

  const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(r);
  if (!stream) return NULL;

  SherpaOnnxAcceptWaveformOffline(stream, sample_rate, samples, sample_count);
  SherpaOnnxDecodeOfflineStream(r, stream);

  const SherpaOnnxOfflineRecognizerResult *result =
      SherpaOnnxGetOfflineStreamResult(stream);

  char *json = NULL;
  if (result && result->json) {
    json = strdup(result->json);
  }

  if (result) SherpaOnnxDestroyOfflineRecognizerResult(result);
  SherpaOnnxDestroyOfflineStream(stream);

  return json;
}

char *MurmurSherpaTranscribe(
    MurmurSherpaRecognizer recognizer,
    const float *samples, int32_t sample_count, int32_t sample_rate) {
  if (!recognizer) return NULL;
  const SherpaOnnxOfflineRecognizer *r =
      (const SherpaOnnxOfflineRecognizer *)recognizer;

  const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(r);
  if (!stream) return NULL;

  SherpaOnnxAcceptWaveformOffline(stream, sample_rate, samples, sample_count);
  SherpaOnnxDecodeOfflineStream(r, stream);

  const SherpaOnnxOfflineRecognizerResult *result =
      SherpaOnnxGetOfflineStreamResult(stream);

  char *text = NULL;
  if (result && result->text) {
    text = strdup(result->text);
  }

  if (result) SherpaOnnxDestroyOfflineRecognizerResult(result);
  SherpaOnnxDestroyOfflineStream(stream);

  return text;
}
