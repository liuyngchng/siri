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
    @Published private(set) var messages: [ChatMessage] = []

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
        messages = Array((messages + [userMsg]).suffix(maxHistory))

        return llmClient.chat(messages: messages)
            .handleEvents(receiveOutput: { [weak self] reply in
                let assistantMsg = ChatMessage(role: .assistant, content: reply)
                self?.messages = Array(((self?.messages ?? []) + [assistantMsg]).suffix(self?.maxHistory ?? 10))
            }, receiveCompletion: { [weak self] completion in
                if case .failure = completion {
                    // Remove user message on failure
                    self?.messages.removeLast()
                }
            })
            .eraseToAnyPublisher()
    }

    /// Send message with streaming (iOS 14+)
    func sendStream(_ text: String) -> AnyPublisher<AnyPublisher<String, Error>, Error> {
        let userMsg = ChatMessage(role: .user, content: text)
        messages = Array((messages + [userMsg]).suffix(maxHistory))

        // Return the stream publisher wrapped
        let streamPublisher = llmClient.chatStreamPublisher(messages: messages)
        return Just(streamPublisher)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    /// Save assistant reply to history (called after streaming completes)
    func appendAssistantReply(_ text: String) {
        guard text.isNotBlank else { return }
        let assistantMsg = ChatMessage(role: .assistant, content: text)
        messages = Array((messages + [assistantMsg]).suffix(maxHistory))
    }

    func clear() {
        messages = []
    }

    var messageCount: Int {
        messages.count
    }
}
