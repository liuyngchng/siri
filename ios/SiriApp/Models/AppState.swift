//
//  AppState.swift
//  SiriApp
//
//  Ported from Android: AppState.kt
//

import Foundation

enum VoiceState: Equatable {
    case idle
    case loading(String)
    case listening
    case recognizing
    case thinking
    case speaking
    case error(String)

    var message: String {
        switch self {
        case .idle: return ""
        case .loading(let msg): return msg
        case .listening: return "正在聆听…"
        case .recognizing: return "识别中…"
        case .thinking: return "思考中…"
        case .speaking: return "播报中…"
        case .error(let msg): return msg
        }
    }
}

struct AppState {
    var voiceState: VoiceState = .loading("模型加载中…")
    var enginesReady: Bool = false
    var partialAsrText: String = ""
    var finalAsrText: String = ""
    var assistantReply: String = ""
    var hasConfig: Bool = false
    var ttsEnabled: Bool = true
}
