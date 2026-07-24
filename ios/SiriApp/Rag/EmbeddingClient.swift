//
//  EmbeddingClient.swift
//  SiriApp
//
//  OpenAI 兼容 embedding API 客户端。
//  与 LlmClient 共用 base URL + API key，只需额外配置 embedding model。
//
//  Ported from Android: EmbeddingClient.kt
//

import Foundation
import Combine
import os.log

class EmbeddingClient {

    private let log = OSLog(subsystem: "dev.richard.voicechat", category: "EmbeddingClient")

    private let configRepository: ConfigRepository

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    struct EmbeddingConfig {
        let apiBase: String
        let apiKey: String
        let model: String
    }

    init(configRepository: ConfigRepository) {
        self.configRepository = configRepository
    }

    /// 从 ConfigRepository 读取 embedding 配置，复用 LLM 的 base URL 和 API key
    private func loadConfig() -> EmbeddingConfig? {
        guard let llmConfig = configRepository.getConfig() else { return nil }
        let embeddingModel = configRepository.getEmbeddingModel()
        return EmbeddingConfig(
            apiBase: llmConfig.baseUrl,
            apiKey: llmConfig.apiKey,
            model: embeddingModel
        )
    }

    // MARK: - Embed

    /// 将单段文本嵌入为向量。
    /// iOS 14: Combine-free async via callback pattern, wrapped in Combine at call site
    /// iOS 15+: uses async/await
    @available(iOS 15.0, *)
    func embed(_ text: String) async -> [Float]? {
        guard let cfg = loadConfig() else {
            os_log(.error, log: log, "EmbeddingClient: no config available")
            return nil
        }

        guard let url = URL(string: "\(cfg.apiBase)/embeddings") else {
            os_log(.error, log: log, "EmbeddingClient: invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": cfg.model,
            "input": text
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let errorBody = String(data: data, encoding: .utf8) ?? "未知错误"
                os_log(.error, log: log,
                       "EmbeddingClient: API error (%{public}d): %{public}@",
                       code, String(errorBody.prefix(200)))
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first = dataArr.first,
                  let embeddingArr = first["embedding"] as? [Double] else {
                os_log(.error, log: log, "EmbeddingClient: unexpected response format")
                return nil
            }

            return embeddingArr.map { Float($0) }
        } catch {
            os_log(.error, log: log, "EmbeddingClient: network error: %{public}@",
                   error.localizedDescription)
            return nil
        }
    }

    /// iOS 14 兼容的 Combine-based 嵌入方法。
    /// 使用 Future + URLSession dataTask 实现。
    func embedPublisher(_ text: String) -> AnyPublisher<[Float]?, Never> {
        Future<[Float]?, Never> { [weak self] promise in
            guard let self = self else {
                promise(.success(nil))
                return
            }

            guard let cfg = self.loadConfig() else {
                os_log(.error, log: self.log, "EmbeddingClient: no config available")
                promise(.success(nil))
                return
            }

            guard let url = URL(string: "\(cfg.apiBase)/embeddings") else {
                os_log(.error, log: self.log, "EmbeddingClient: invalid URL")
                promise(.success(nil))
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "model": cfg.model,
                "input": text
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    os_log(.error, log: self.log,
                           "EmbeddingClient: network error: %{public}@",
                           error.localizedDescription)
                    promise(.success(nil))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data = data else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    os_log(.error, log: self.log,
                           "EmbeddingClient: API error (%{public}d)", code)
                    promise(.success(nil))
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArr = json["data"] as? [[String: Any]],
                      let first = dataArr.first,
                      let embeddingArr = first["embedding"] as? [Double] else {
                    os_log(.error, log: self.log,
                           "EmbeddingClient: unexpected response format")
                    promise(.success(nil))
                    return
                }

                promise(.success(embeddingArr.map { Float($0) }))
            }.resume()
        }.eraseToAnyPublisher()
    }
}
