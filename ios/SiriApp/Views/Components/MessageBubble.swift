//
//  MessageBubble.swift
//  SiriApp
//
//  Chat message bubble: user right-aligned, assistant left-aligned.
//  Long press to replay TTS.
//  Ported from Android: MainScreen.kt (MessageBubble composable)
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    let onLongPress: (() -> Void)?

    init(message: ChatMessage, onLongPress: (() -> Void)? = nil) {
        self.message = message
        self.onLongPress = onLongPress
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            Text(message.content)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundColor(isUser
                    ? Color(.systemBackground)
                    : Color(.label))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isUser
                            ? Color.blue
                            : Color(.systemGray5))
                )
                .frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: isUser ? .trailing : .leading)
                .contextMenu {
                    if onLongPress != nil {
                        Button(action: { onLongPress?() }) {
                            Label("重新播报", systemImage: "speaker.wave.2")
                        }
                    }
                }

            if !isUser { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private var isUser: Bool {
        message.role == .user
    }
}
