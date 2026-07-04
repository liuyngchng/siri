//
//  ChatSession.swift
//  SiriApp
//
//  Multi-turn conversation manager. Keeps last MAX_HISTORY messages.
//  Ported from Android: ChatSession.kt
//

import Foundation
import Combine

class ChatSession: ObservableObject {
    /// Messages shown on screen — cleared when a new recording starts.
    @Published private(set) var messages: [ChatMessage] = []

    /// LLM context buffer — preserved across screen clears so the model
    /// remembers previous turns. Never cleared except by user action.
    private var contextBuffer: [ChatMessage] = []

    /// Context window for LLM — last N messages from the full context buffer.
    private var contextMessages: [ChatMessage] {
        Array(contextBuffer.suffix(maxHistory))
    }

    private let llmClient: LlmClient
    private let maxHistory: Int
    private var cancellables = Set<AnyCancellable>()

    init(llmClient: LlmClient, maxHistory: Int = 10) {
        self.llmClient = llmClient
        self.maxHistory = maxHistory
    }

    /// Send message (non-streaming)
    func send(_ text: String) -> AnyPublisher<String, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        contextBuffer.append(userMsg)

        return llmClient.chat(messages: contextMessages)
            .handleEvents(receiveOutput: { [weak self] reply in
                let assistantMsg = ChatMessage(role: .assistant, content: reply)
                self?.messages.append(assistantMsg)
                self?.contextBuffer.append(assistantMsg)
            }, receiveCompletion: { [weak self] completion in
                if case .failure = completion {
                    self?.messages.removeLast()
                    self?.contextBuffer.removeLast()
                }
            })
            .eraseToAnyPublisher()
    }

    /// Send message with streaming (iOS 14+)
    func sendStream(_ text: String) -> AnyPublisher<AnyPublisher<String, Error>, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)
        contextBuffer.append(userMsg)

        let streamPublisher = llmClient.chatStreamPublisher(messages: contextMessages)
        return Just(streamPublisher)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    /// Save assistant reply to history (called after streaming completes)
    func appendAssistantReply(_ text: String) {
        guard text.isNotBlank else { return }
        let msg = ChatMessage(role: .assistant, content: text)
        messages.append(msg)
        contextBuffer.append(msg)
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
