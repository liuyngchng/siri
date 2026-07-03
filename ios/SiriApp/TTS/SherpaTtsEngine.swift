//
//  SherpaTtsEngine.swift
//  SiriApp
//
//  Offline TTS engine using sherpa-onnx Matcha-TTS model.
//  Calls sherpa-onnx C API via bridging header.
//  Ported from Android: SherpaTtsEngine.kt
//

import Foundation
import os.log

class SherpaTtsEngine {
    private let modelDir: URL
    private let acousticModel = "model.onnx"
    private let vocoderModel = "vocos.onnx"
    private let tokensFile = "tokens.txt"
    private let lexiconFile = "lexicon.txt"

    static let defaultSpeed: Float = 1.0
    static let defaultSampleRate: Int32 = 22050

    private var ttsPtr: UnsafeMutableRawPointer?
    private var isInitialized = false

    init(documentsDir: URL) {
        self.modelDir = documentsDir
            .appendingPathComponent("models/tts")
    }

    var isReady: Bool { isInitialized }

    var sampleRate: Int32 {
        guard isInitialized else { return SherpaTtsEngine.defaultSampleRate }

        // === sherpa-onnx C API call ===
        // return SherpaOnnxOfflineTtsSampleRate(ttsPtr)

        return SherpaTtsEngine.defaultSampleRate
    }

    func initialize() -> Bool {
        guard !isInitialized else { return true }

        let acPath = modelDir.appendingPathComponent(acousticModel).path
        let vcPath = modelDir.appendingPathComponent(vocoderModel).path
        let tkPath = modelDir.appendingPathComponent(tokensFile).path
        let lxPath = modelDir.appendingPathComponent(lexiconFile).path

        let fm = FileManager.default
        let missing = [acPath, vcPath, tkPath, lxPath].filter { !fm.fileExists(atPath: $0) }
        if !missing.isEmpty {
            os_log(.error, "TTS: missing model files: %{public}@",
                   missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
            return false
        }

        os_log(.info, "TTS: initializing")

        // === sherpa-onnx C API call ===
        // When sherpa-onnx xcframework/SPM is added and bridging header imports c-api.h:
        //
        // var config = SherpaOnnxOfflineTtsConfig()
        // memset(&config, 0, MemoryLayout<SherpaOnnxOfflineTtsConfig>.size)
        // config.model.matcha.acoustic_model = strdup(acPath)
        // config.model.matcha.vocoder = strdup(vcPath)
        // config.model.matcha.tokens = strdup(tkPath)
        // config.model.matcha.lexicon = strdup(lxPath)
        // config.model.matcha.noise_scale = 0.667
        // config.model.matcha.length_scale = 1.0
        // config.model.num_threads = 4
        // config.model.provider = strdup("cpu")
        // config.max_num_sentences = 2
        //
        // ttsPtr = UnsafeMutableRawPointer(SherpaOnnxCreateOfflineTts(&config))
        // isInitialized = ttsPtr != nil

        // STUB: Mark as initialized for now
        os_log(.info, "TTS: sherpa-onnx framework not yet linked; engine stub initialized")
        isInitialized = true

        if isInitialized {
            os_log(.info, "TTS: initialized OK, sample_rate=%d", sampleRate)
        } else {
            os_log(.error, "TTS: failed to create engine")
        }
        return isInitialized
    }

    func synthesize(text: String, speed: Float = defaultSpeed, sid: Int = 0) -> [Float]? {
        guard isInitialized else { return nil }

        os_log(.info, "TTS: synthesizing %d chars, speed=%.2f", text.count, speed)

        // === sherpa-onnx C API call ===
        // var genConfig = SherpaOnnxGenerationConfig()
        // memset(&genConfig, 0, MemoryLayout<SherpaOnnxGenerationConfig>.size)
        // genConfig.sid = Int32(sid)
        // genConfig.speed = speed
        //
        // let audio = SherpaOnnxOfflineTtsGenerateWithConfig(
        //     ttsPtr, text, &genConfig, nil, nil
        // )
        //
        // guard let audio = audio, audio.pointee.n > 0, let samples = audio.pointee.samples else {
        //     if let audio = audio {
        //         SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
        //     }
        //     return nil
        // }
        //
        // let n = Int(audio.pointee.n)
        // let result = Array(UnsafeBufferPointer(start: samples, count: n))
        // SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
        // os_log(.info, "TTS: synthesized %d samples at %d Hz", n, audio.pointee.sample_rate)
        // return result

        // STUB: Return empty array
        os_log(.info, "TTS: synthesize stub (sherpa-onnx not linked)")
        return nil
    }

    func destroy() {
        guard isInitialized else { return }

        // === sherpa-onnx C API call ===
        // SherpaOnnxDestroyOfflineTts(ttsPtr)

        ttsPtr = nil
        isInitialized = false
        os_log(.info, "TTS: destroyed")
    }
}
