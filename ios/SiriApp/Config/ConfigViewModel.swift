//
//  ConfigViewModel.swift
//  SiriApp
//
//  Settings ViewModel: save / test / clear config.
//  Ported from Android: ConfigViewModel.kt
//

import Foundation
import Combine

enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

class ConfigViewModel: ObservableObject {
    @Published var config: LlmConfig?
    @Published var testResult: ConnectionTestState = .idle

    private let repository = ConfigRepository()

    init() {
        config = repository.getConfig()
    }

    func saveConfig(_ apiUrl: String, _ model: String, _ apiKey: String) {
        let trimmedUrl = apiUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        guard !trimmedUrl.isEmpty, !trimmedModel.isEmpty, !trimmedKey.isEmpty else {
            testResult = .failure("所有字段不能为空")
            return
        }

        guard trimmedUrl.hasPrefix("http://") || trimmedUrl.hasPrefix("https://") else {
            testResult = .failure("API 地址必须以 http:// 或 https:// 开头")
            return
        }

        let newConfig = LlmConfig(
            apiUrl: trimmedUrl,
            model: trimmedModel,
            apiKey: trimmedKey
        )
        repository.saveConfig(newConfig)
        config = newConfig
        testResult = .success("配置已保存")
    }

    func testConnection(_ apiUrl: String, _ model: String, _ apiKey: String) {
        let trimmedUrl = apiUrl.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        guard !trimmedUrl.isEmpty, !trimmedModel.isEmpty, !trimmedKey.isEmpty else {
            testResult = .failure("请先填写完整信息")
            return
        }

        testResult = .testing

        // Test both LLM and Embedding APIs
        Task {
            let llmResult = await testLLM(baseUrl: trimmedUrl, model: trimmedModel, apiKey: trimmedKey)
            let embResult = await testEmbedding(baseUrl: trimmedUrl, apiKey: trimmedKey)

            await MainActor.run {
                switch (llmResult, embResult) {
                case (.success, .success):
                    testResult = .success("连接成功！LLM OK, Embedding OK")
                case (.success, .failure(let embErr)):
                    testResult = .failure("LLM OK, 但 Embedding 失败: \(embErr)")
                case (.failure(let llmErr), .success):
                    testResult = .failure("LLM 失败: \(llmErr)")
                case (.failure(let llmErr), .failure(let embErr)):
                    testResult = .failure("LLM 失败: \(llmErr)\nEmbedding 也失败: \(embErr)")
                }
            }
        }
    }

    // MARK: - Individual API tests

    private enum ApiTestResult {
        case success
        case failure(String)
    }

    private func testLLM(baseUrl: String, model: String, apiKey: String) async -> ApiTestResult {
        guard let url = URL(string: "\(baseUrl)/chat/completions") else {
            return .failure("无效的 API 地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(returning: .failure(self.summarizeError(error)))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(returning: .failure("无效的服务器响应"))
                    return
                }
                if (200...299).contains(httpResponse.statusCode) {
                    continuation.resume(returning: .success)
                } else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "未知错误"
                    continuation.resume(returning: .failure("\(httpResponse.statusCode) \(String(errorBody.prefix(100)))"))
                }
            }.resume()
        }
    }

    private func testEmbedding(baseUrl: String, apiKey: String) async -> ApiTestResult {
        guard let url = URL(string: "\(baseUrl)/embeddings") else {
            return .failure("无效的 API 地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let embeddingModel = repository.getEmbeddingModel()
        let body: [String: Any] = [
            "model": embeddingModel,
            "input": "test",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(returning: .failure(self.summarizeError(error)))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(returning: .failure("无效的服务器响应"))
                    return
                }
                if (200...299).contains(httpResponse.statusCode) {
                    continuation.resume(returning: .success)
                } else {
                    let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "未知错误"
                    continuation.resume(returning: .failure("\(httpResponse.statusCode) \(String(errorBody.prefix(100)))"))
                }
            }.resume()
        }
    }

    private func summarizeError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            return "无法连接到服务器，请检查 API 地址"
        case NSURLErrorTimedOut:
            return "连接超时，请检查网络"
        case NSURLErrorServerCertificateUntrusted:
            return "SSL 证书验证失败"
        default:
            return error.localizedDescription
        }
    }

    func clearConfig() {
        repository.clearConfig()
        config = nil
        testResult = .idle
    }

    func resetTestResult() {
        testResult = .idle
    }
}
