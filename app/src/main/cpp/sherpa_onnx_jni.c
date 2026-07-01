#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include <android/log.h>

#include "sherpa-onnx/c-api/c-api.h"

#define TAG "SiriJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Per-recognizer state (offline SenseVoice ASR) ──────────────────────────

typedef struct {
    const SherpaOnnxOfflineRecognizer *recognizer;
    float *buffer;
    int32_t buffer_len;
    int32_t buffer_cap;
} RecognizerState;

// ── ASR: Create Recognizer ─────────────────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_rd_siri_asr_SherpaAsrEngine_nativeCreateRecognizer(
    JNIEnv *env, jclass clazz, jstring modelPath, jstring tokensPath) {

    const char *c_model = (*env)->GetStringUTFChars(env, modelPath, NULL);
    const char *c_tokens = (*env)->GetStringUTFChars(env, tokensPath, NULL);

    if (!c_model || !c_tokens) {
        LOGE("ASR: Failed to get path strings");
        if (c_model) (*env)->ReleaseStringUTFChars(env, modelPath, c_model);
        if (c_tokens) (*env)->ReleaseStringUTFChars(env, tokensPath, c_tokens);
        return 0;
    }

    LOGI("ASR: Creating recognizer: model=%s, tokens=%s", c_model, c_tokens);

    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));

    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;

    config.model_config.sense_voice.model = c_model;
    config.model_config.sense_voice.language = "auto";
    config.model_config.sense_voice.use_itn = 1;

    config.model_config.tokens = c_tokens;
    config.model_config.num_threads = 4;
    config.model_config.provider = "cpu";
    config.model_config.debug = 0;

    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *recognizer =
        SherpaOnnxCreateOfflineRecognizer(&config);

    (*env)->ReleaseStringUTFChars(env, modelPath, c_model);
    (*env)->ReleaseStringUTFChars(env, tokensPath, c_tokens);

    if (!recognizer) {
        LOGE("ASR: Failed to create recognizer");
        return 0;
    }

    RecognizerState *state = malloc(sizeof(RecognizerState));
    memset(state, 0, sizeof(RecognizerState));
    state->recognizer = recognizer;

    LOGI("ASR: Recognizer created successfully");
    return (jlong)(intptr_t)state;
}

// ── ASR: Accept Waveform (buffer samples) ──────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_siri_asr_SherpaAsrEngine_nativeAcceptWaveform(
    JNIEnv *env, jclass clazz, jlong ptr, jfloatArray samples) {

    if (ptr == 0) return;
    RecognizerState *state = (RecognizerState *)(intptr_t)ptr;

    jsize n = (*env)->GetArrayLength(env, samples);
    if (n <= 0) return;

    // Grow buffer if needed
    int32_t needed = state->buffer_len + n;
    if (needed > state->buffer_cap) {
        int32_t new_cap = state->buffer_cap > 0 ? state->buffer_cap * 2 : 16000 * 30; // 30s default
        if (new_cap < needed) new_cap = needed;
        state->buffer = realloc(state->buffer, new_cap * sizeof(float));
        state->buffer_cap = new_cap;
    }

    jfloat *c_samples = (*env)->GetFloatArrayElements(env, samples, NULL);
    if (!c_samples) {
        LOGE("ASR: Failed to get sample array");
        return;
    }

    memcpy(state->buffer + state->buffer_len, c_samples, n * sizeof(float));
    state->buffer_len += n;

    (*env)->ReleaseFloatArrayElements(env, samples, c_samples, JNI_ABORT);
}

// ── ASR: Get Pending Text (none for offline) ───────────────────────────────

JNIEXPORT jstring JNICALL
Java_com_rd_siri_asr_SherpaAsrEngine_nativeGetText(
    JNIEnv *env, jclass clazz, jlong ptr) {
    // Offline recognizer doesn't produce partial results
    return (*env)->NewStringUTF(env, "");
}

// ── ASR: Input Finished (decode all buffered samples) ──────────────────────

JNIEXPORT jstring JNICALL
Java_com_rd_siri_asr_SherpaAsrEngine_nativeInputFinished(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return (*env)->NewStringUTF(env, "");

    RecognizerState *state = (RecognizerState *)(intptr_t)ptr;

    if (state->buffer_len == 0) {
        LOGI("ASR: Input finished with no samples");
        return (*env)->NewStringUTF(env, "");
    }

    LOGI("ASR: Decoding %d samples", state->buffer_len);

    const SherpaOnnxOfflineStream *stream =
        SherpaOnnxCreateOfflineStream(state->recognizer);

    if (!stream) {
        LOGE("ASR: Failed to create offline stream");
        state->buffer_len = 0;
        return (*env)->NewStringUTF(env, "");
    }

    SherpaOnnxAcceptWaveformOffline(stream, 16000, state->buffer, state->buffer_len);
    SherpaOnnxDecodeOfflineStream(state->recognizer, stream);

    const SherpaOnnxOfflineRecognizerResult *result =
        SherpaOnnxGetOfflineStreamResult(stream);

    jstring j_text = NULL;
    if (result && result->text) {
        j_text = (*env)->NewStringUTF(env, result->text);
        LOGI("ASR: Result: %s", result->text);
    } else {
        j_text = (*env)->NewStringUTF(env, "");
        LOGI("ASR: No result text");
    }

    if (result) SherpaOnnxDestroyOfflineRecognizerResult(result);
    SherpaOnnxDestroyOfflineStream(stream);

    // Clear buffer
    state->buffer_len = 0;

    return j_text;
}

// ── ASR: Destroy Recognizer ────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_siri_asr_SherpaAsrEngine_nativeDestroyRecognizer(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return;

    RecognizerState *state = (RecognizerState *)(intptr_t)ptr;

    if (state->recognizer) {
        SherpaOnnxDestroyOfflineRecognizer(state->recognizer);
    }
    free(state->buffer);
    free(state);
    LOGI("ASR: Recognizer destroyed");
}

// ═══════════════════════════════════════════════════════════════════════════
// TTS: Matcha-TTS
// ═══════════════════════════════════════════════════════════════════════════

typedef struct {
    const SherpaOnnxOfflineTts *tts;
} TtsState;

// ── TTS: Create ────────────────────────────────────────────────────────────

JNIEXPORT jlong JNICALL
Java_com_rd_siri_tts_SherpaTtsEngine_nativeCreateTts(
    JNIEnv *env, jclass clazz,
    jstring acousticModel, jstring vocoder,
    jstring tokens, jstring lexicon) {

    const char *c_acoustic = (*env)->GetStringUTFChars(env, acousticModel, NULL);
    const char *c_vocoder = (*env)->GetStringUTFChars(env, vocoder, NULL);
    const char *c_tokens = (*env)->GetStringUTFChars(env, tokens, NULL);
    const char *c_lexicon = (*env)->GetStringUTFChars(env, lexicon, NULL);

    LOGI("TTS: Creating with acoustic=%s, vocoder=%s", c_acoustic, c_vocoder);

    SherpaOnnxOfflineTtsConfig config;
    memset(&config, 0, sizeof(config));

    config.model.matcha.acoustic_model = c_acoustic;
    config.model.matcha.vocoder = c_vocoder;
    config.model.matcha.tokens = c_tokens;
    config.model.matcha.lexicon = c_lexicon;
    config.model.matcha.noise_scale = 0.667f;
    config.model.matcha.length_scale = 1.0f;
    config.model.num_threads = 4;
    config.model.provider = "cpu";
    config.model.debug = 0;
    config.max_num_sentences = 2;

    const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&config);

    (*env)->ReleaseStringUTFChars(env, acousticModel, c_acoustic);
    (*env)->ReleaseStringUTFChars(env, vocoder, c_vocoder);
    (*env)->ReleaseStringUTFChars(env, tokens, c_tokens);
    (*env)->ReleaseStringUTFChars(env, lexicon, c_lexicon);

    if (!tts) {
        LOGE("TTS: Failed to create");
        return 0;
    }

    TtsState *state = malloc(sizeof(TtsState));
    state->tts = tts;

    int32_t sr = SherpaOnnxOfflineTtsSampleRate(tts);
    LOGI("TTS: Created successfully, sample_rate=%d", sr);
    return (jlong)(intptr_t)state;
}

// ── TTS: Synthesize ────────────────────────────────────────────────────────

JNIEXPORT jfloatArray JNICALL
Java_com_rd_siri_tts_SherpaTtsEngine_nativeSynthesize(
    JNIEnv *env, jclass clazz, jlong ptr, jstring text, jfloat speed, jint sid) {

    if (ptr == 0) return NULL;

    TtsState *state = (TtsState *)(intptr_t)ptr;
    const char *c_text = (*env)->GetStringUTFChars(env, text, NULL);

    if (!c_text) {
        LOGE("TTS: Failed to get text string");
        return NULL;
    }

    LOGI("TTS: Synthesizing %d chars, speed=%.2f, sid=%d", (int)strlen(c_text), (double)speed, (int)sid);

    SherpaOnnxGenerationConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.sid = (int32_t)sid;
    cfg.speed = speed;

    const SherpaOnnxGeneratedAudio *audio =
        SherpaOnnxOfflineTtsGenerateWithConfig(state->tts, c_text, &cfg, NULL, NULL);

    (*env)->ReleaseStringUTFChars(env, text, c_text);

    if (!audio || !audio->samples || audio->n <= 0) {
        LOGE("TTS: Synthesis produced no audio");
        if (audio) SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        return NULL;
    }

    jfloatArray result = (*env)->NewFloatArray(env, audio->n);
    (*env)->SetFloatArrayRegion(env, result, 0, audio->n, audio->samples);

    LOGI("TTS: Synthesized %d samples at %d Hz", audio->n, audio->sample_rate);

    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
    return result;
}

// ── TTS: Get Sample Rate ───────────────────────────────────────────────────

JNIEXPORT jint JNICALL
Java_com_rd_siri_tts_SherpaTtsEngine_nativeGetSampleRate(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return 22050;
    TtsState *state = (TtsState *)(intptr_t)ptr;
    return SherpaOnnxOfflineTtsSampleRate(state->tts);
}

// ── TTS: Destroy ───────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_rd_siri_tts_SherpaTtsEngine_nativeDestroyTts(
    JNIEnv *env, jclass clazz, jlong ptr) {

    if (ptr == 0) return;
    TtsState *state = (TtsState *)(intptr_t)ptr;
    if (state->tts) {
        SherpaOnnxDestroyOfflineTts(state->tts);
    }
    free(state);
    LOGI("TTS: Destroyed");
}
