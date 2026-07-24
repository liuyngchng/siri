//
//  ChatSession.swift
//  SiriApp
//
//  Multi-turn conversation manager. Keeps last MAX_HISTORY messages.
//  Supports RAG (Retrieval-Augmented Generation) via HybridSearcher.
//
//  Ported from Android: ChatSession.kt
//

import Foundation
import Combine
import os.log

class ChatSession: ObservableObject {
    /// Messages shown on screen — capped at maxScreenMessages.
    @Published private(set) var messages: [ChatMessage] = []

    /// LLM context buffer — preserved across screen clears so the model
    /// remembers previous turns. Never cleared except by user action.
    private var contextBuffer: [ChatMessage] = []

    /// Maximum messages shown on screen (older messages are trimmed).
    private let maxScreenMessages: Int

    /// Context window for LLM — last N messages from the full context buffer.
    private var contextMessages: [ChatMessage] {
        Array(contextBuffer.suffix(maxHistory))
    }

    private let llmClient: LlmClient
    private let configRepository: ConfigRepository
    private let hybridSearcher: HybridSearcher?
    private let maxHistory: Int
    private var cancellables = Set<AnyCancellable>()

    private let log = OSLog(subsystem: "dev.richard.voicechat", category: "ChatSession")

    init(llmClient: LlmClient,
         configRepository: ConfigRepository,
         hybridSearcher: HybridSearcher? = nil,
         maxHistory: Int = 5,
         maxScreenMessages: Int = 20) {
        self.llmClient = llmClient
        self.configRepository = configRepository
        self.hybridSearcher = hybridSearcher
        self.maxHistory = maxHistory
        self.maxScreenMessages = maxScreenMessages
    }

    // MARK: - RAG Context Retrieval

    /// 混合检索：向量语义 + BM25 关键词 → RRF 融合。
    /// 如果 HybridSearcher 未配置或 RAG 被禁用，返回 nil。
    private func retrieveContext(_ userText: String) async -> String? {
        guard let hybridSearcher = hybridSearcher else { return nil }
        guard configRepository.isRagEnabled() else { return nil }

        let results = await hybridSearcher.search(query: userText, topK: 3)
        if results.isEmpty {
            os_log(.debug, log: log, "retrieveContext: no relevant chunks found")
            return nil
        }

        os_log(.info, log: log,
               "retrieveContext: found %{public}d chunks, top RRF scores: %{public}@",
               results.count,
               results.map { String(format: "%.4f", $0.score) }.joined(separator: ", "))

        return results.map { $0.content }.joined(separator: "\n---\n")
    }

    // MARK: - Send

    /// Send message (non-streaming)
    func send(_ text: String) -> AnyPublisher<String, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        appendToScreen(userMsg)
        contextBuffer.append(userMsg)

        return Future<String, Error> { [weak self] promise in
            guard let self = self else { return }
            Task {
                let ragContext = await self.retrieveContext(text)
                let publisher = self.llmClient.chat(
                    messages: self.contextMessages,
                    ragContext: ragContext
                )
                var cancellable: AnyCancellable?
                var didFulfill = false
                cancellable = publisher.sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            self.messages.removeLast()
                            self.contextBuffer.removeLast()
                            if !didFulfill { didFulfill = true; promise(.failure(error)) }
                        }
                        _ = cancellable
                    },
                    receiveValue: { reply in
                        let assistantMsg = ChatMessage(role: .assistant, content: reply)
                        self.appendToScreen(assistantMsg)
                        self.contextBuffer.append(assistantMsg)
                        if !didFulfill { didFulfill = true; promise(.success(reply)) }
                    }
                )
            }
        }.eraseToAnyPublisher()
    }

    /// Send message with streaming (iOS 14+).
    /// Retrieves RAG context asynchronously before starting the LLM stream.
    func sendStream(_ text: String) -> AnyPublisher<AnyPublisher<String, Error>, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        appendToScreen(userMsg)
        contextBuffer.append(userMsg)

        // If RAG is not available, skip the async wrapper for lower latency
        guard hybridSearcher != nil && configRepository.isRagEnabled() else {
            let streamPublisher = llmClient.chatStreamPublisher(messages: contextMessages)
            return Just(streamPublisher)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        // Wrap the async retrieval in a Deferred+Future so the outer publisher
        // emits the inner stream publisher once RAG context is ready.
        return Deferred {
            Future<AnyPublisher<String, Error>, Error> { [weak self] promise in
                guard let self = self else { return }

                Task { [weak self] in
                    guard let self = self else { return }
                    let ragContext = await self.retrieveContext(text)
                    let streamPublisher = self.llmClient.chatStreamPublisher(
                        messages: self.contextMessages,
                        ragContext: ragContext
                    )
                    promise(.success(streamPublisher))
                }
            }
        }.eraseToAnyPublisher()
    }

    /// Save assistant reply to history (called after streaming completes)
    func appendAssistantReply(_ text: String) {
        guard text.isNotBlank else { return }
        let msg = ChatMessage(role: .assistant, content: text)
        appendToScreen(msg)
        contextBuffer.append(msg)
    }

    // MARK: - Screen / Context Management

    /// Append a message to the on-screen list, trimming to maxScreenMessages.
    private func appendToScreen(_ msg: ChatMessage) {
        messages.append(msg)
        if messages.count > maxScreenMessages {
            messages = Array(messages.suffix(maxScreenMessages))
        }
    }

    /// Clear screen only — LLM context is preserved.
    func clearScreen() {
        messages = []
    }

    /// Full clear — both screen and LLM context (user-initiated).
    func clear() {
        messages = []
        contextBuffer = []
    }

    var messageCount: Int {
        messages.count
    }
}
