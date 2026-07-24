//
//  ConfigRepository.swift
//  SiriApp
//
//  Config storage backed by Keychain (hardware-encrypted).
//  Ported from Android: ConfigRepository.kt (EncryptedSharedPreferences)
//

import Foundation

class ConfigRepository {
    private let serviceName = "dev.richard.voicechat.llmConfig"
    private let accountName = "config"

    // MARK: - UserDefaults keys (non-sensitive preferences)
    private let udEmbeddingModel = "embedding_model"
    private let udEnableRag = "enable_rag"

    func getConfig() -> LlmConfig? {
        guard let data = KeychainHelper.read(service: serviceName, account: accountName),
              let config = try? JSONDecoder().decode(LlmConfig.self, from: data) else {
            return nil
        }
        // Merge non-sensitive RAG preferences from UserDefaults
        var merged = config
        let ud = UserDefaults.standard
        merged.embeddingModel = ud.string(forKey: udEmbeddingModel) ?? config.embeddingModel
        if ud.object(forKey: udEnableRag) != nil {
            merged.enableRag = ud.bool(forKey: udEnableRag)
        }
        return merged
    }

    func saveConfig(_ config: LlmConfig) {
        if let data = try? JSONEncoder().encode(config) {
            _ = KeychainHelper.save(data: data, service: serviceName, account: accountName)
        }
        // Persist RAG preferences in UserDefaults
        let ud = UserDefaults.standard
        ud.set(config.embeddingModel, forKey: udEmbeddingModel)
        ud.set(config.enableRag, forKey: udEnableRag)
    }

    func clearConfig() {
        KeychainHelper.delete(service: serviceName, account: accountName)
        let ud = UserDefaults.standard
        ud.removeObject(forKey: udEmbeddingModel)
        ud.removeObject(forKey: udEnableRag)
    }

    var hasConfig: Bool {
        getConfig() != nil
    }

    // MARK: - RAG preferences

    func getEmbeddingModel() -> String {
        UserDefaults.standard.string(forKey: udEmbeddingModel) ?? "text-embedding-v3"
    }

    func isRagEnabled() -> Bool {
        // Default true; if key not set in UserDefaults, return true
        if UserDefaults.standard.object(forKey: udEnableRag) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: udEnableRag)
    }
}
