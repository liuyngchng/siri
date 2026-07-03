//
//  SherpaAsrEngine.swift
//  SiriApp
//
//  Offline ASR engine using sherpa-onnx SenseVoice model.
//  Calls sherpa-onnx C API via bridging header.
//  Ported from Android: SherpaAsrEngine.kt
//

import Foundation
import os.log

class SherpaAsrEngine {
    private let modelDir: URL
    private let modelFile = "model.int8.onnx"
    private let tokensFile = "tokens.txt"

    // C API state pointers (opaque)
    // These will hold the sherpa-onnx recognizer and stream pointers
    // once the xcframework/SPM is linked.
    // For now, these are placeholders that the sherpa-onnx wrapper will manage.
    private var recognizerPtr: UnsafeMutableRawPointer?
    private var sampleBuffer: [Float] = []
    private var isInitialized = false

    init(documentsDir: URL) {
        self.modelDir = documentsDir
            .appendingPathComponent("models/asr")
    }

    var isReady: Bool { isInitialized }

    func initialize() -> Bool {
        guard !isInitialized else { return true }

        let modelPath = modelDir.appendingPathComponent(modelFile).path
        let tokensPath = modelDir.appendingPathComponent(tokensFile).path

        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath) else {
            os_log(.error, "ASR: model file not found: %{public}@", modelPath)
            return false
        }
        guard fm.fileExists(atPath: tokensPath) else {
            os_log(.error, "ASR: tokens file not found: %{public}@", tokensPath)
            return false
        }

        os_log(.info, "ASR: initializing with model=%@", modelPath)

        // === sherpa-onnx C API call ===
        // When sherpa-onnx xcframework/SPM is added and bridging header imports c-api.h:
        //
        // var config = SherpaOnnxOfflineRecognizerConfig()
        // memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)
        // config.feat_config.sample_rate = 16000
        // config.feat_config.feature_dim = 80
        // config.model_config.sense_voice.model = strdup(modelPath)
        // config.model_config.sense_voice.language = strdup("auto")
        // config.model_config.sense_voice.use_itn = 1
        // config.model_config.tokens = strdup(tokensPath)
        // config.model_config.num_threads = 4
        // config.model_config.provider = strdup("cpu")
        // config.decoding_method = strdup("greedy_search")
        //
        // recognizerPtr = UnsafeMutableRawPointer(
        //     SherpaOnnxCreateOfflineRecognizer(&config)
        // )
        //
        // isInitialized = recognizerPtr != nil

        // STUB: Mark as initialized for now — replace with above code when sherpa-onnx is linked
        os_log(.info, "ASR: sherpa-onnx framework not yet linked; engine stub initialized")
        isInitialized = true

        if isInitialized {
            os_log(.info, "ASR: initialized OK")
        } else {
            os_log(.error, "ASR: failed to create recognizer")
        }
        return isInitialized
    }

    func acceptWaveform(_ samples: [Float]) {
        guard isInitialized else { return }
        sampleBuffer.append(contentsOf: samples)

        // === sherpa-onnx C API call (per-sample decode) ===
        // let stream = SherpaOnnxCreateOfflineStream(recognizerPtr)
        // samples.withUnsafeBufferPointer { ptr in
        //     SherpaOnnxAcceptWaveformOffline(stream, 16000, ptr.baseAddress, Int32(samples.count))
        // }
        // SherpaOnnxDecodeOfflineStream(recognizerPtr, stream)
        // let result = SherpaOnnxGetOfflineStreamResult(stream)
        // if let text = result?.pointee.text {
        //     pendingText = String(cString: text)
        // }
        // SherpaOnnxDestroyOfflineRecognizerResult(result)
        // SherpaOnnxDestroyOfflineStream(stream)
    }

    private var pendingText = ""

    func getPendingText() -> String {
        // Offline recognizer doesn't produce partial results
        return ""
    }

    func inputFinished() -> String {
        guard isInitialized, !sampleBuffer.isEmpty else {
            sampleBuffer = []
            return ""
        }

        os_log(.info, "ASR: decoding %d samples", sampleBuffer.count)

        // === sherpa-onnx C API call (final decode) ===
        // let stream = SherpaOnnxCreateOfflineStream(recognizerPtr)
        // sampleBuffer.withUnsafeBufferPointer { ptr in
        //     SherpaOnnxAcceptWaveformOffline(
        //         stream, 16000, ptr.baseAddress, Int32(sampleBuffer.count)
        //     )
        // }
        // SherpaOnnxDecodeOfflineStream(recognizerPtr, stream)
        // let result = SherpaOnnxGetOfflineStreamResult(stream)
        // let text = result?.pointee.text.map { String(cString: $0) } ?? ""
        // SherpaOnnxDestroyOfflineRecognizerResult(result)
        // SherpaOnnxDestroyOfflineStream(stream)
        //
        // sampleBuffer = []
        // os_log(.info, "ASR: result='%@'", text)
        // return text

        // STUB: Return empty for now
        os_log(.info, "ASR: inputFinished stub (sherpa-onnx not linked)")
        sampleBuffer = []
        return ""
    }

    func destroy() {
        guard isInitialized else { return }

        // === sherpa-onnx C API call ===
        // SherpaOnnxDestroyOfflineRecognizer(recognizerPtr)

        recognizerPtr = nil
        sampleBuffer = []
        isInitialized = false
        os_log(.info, "ASR: destroyed")
    }
}
