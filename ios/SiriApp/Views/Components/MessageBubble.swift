//
//  MessageBubble.swift
//  SiriApp
//
//  Chat message bubble: user right-aligned, assistant left-aligned.
//  Long press to replay TTS.  Adaptive sizing via GeometryReader.
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    let onLongPress: (() -> Void)?
    /// Available width for the message list, passed in by the parent.
    var availableWidth: CGFloat = UIScreen.main.bounds.width

    @State private var isAppeared = false

    init(message: ChatMessage,
         availableWidth: CGFloat = UIScreen.main.bounds.width,
         onLongPress: (() -> Void)? = nil) {
        self.message = message
        self.availableWidth = availableWidth
        self.onLongPress = onLongPress
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: ChatBubbleMetrics.edgeMinimum) }

            Text(message.content)
                .font(.body)
                .foregroundColor(isUser
                    ? ChatColors.userBubbleText
                    : ChatColors.assistantBubbleText)
                .padding(.horizontal, ChatBubbleMetrics.textHPadding)
                .padding(.vertical, ChatBubbleMetrics.textVPadding)
                .background(bubbleShape)
                .frame(maxWidth: bubbleMaxWidth,
                       alignment: isUser ? .trailing : .leading)
                .contextMenu {
                    if onLongPress != nil {
                        Button(action: { onLongPress?() }) {
                            Label("重新播报", systemImage: "speaker.wave.2")
                        }
                    }
                }

            if !isUser { Spacer(minLength: ChatBubbleMetrics.edgeMinimum) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, 4)
        .opacity(isAppeared ? 1 : 0)
        .scaleEffect(isAppeared ? 1 : 0.92, anchor: isUser ? .trailing : .leading)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isAppeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isUser ? "你的消息" : "助理消息，长按重新播报")
    }

    // MARK: - Helpers

    private var isUser: Bool { message.role == .user }

    private var bubbleMaxWidth: CGFloat {
        min(availableWidth * ChatBubbleMetrics.maxWidthFraction,
            ChatBubbleMetrics.maxWidthCap)
    }

    @ViewBuilder
    private var bubbleShape: some View {
        RoundedRectangle(cornerRadius: ChatBubbleMetrics.cornerRadius)
            .fill(isUser
                ? ChatColors.userBubbleBackground
                : ChatColors.assistantBubbleBackground)
            .overlay(
                RoundedRectangle(cornerRadius: ChatBubbleMetrics.cornerRadius)
                    .stroke(Color(.separator).opacity(0.12), lineWidth: 0.5)
            )
    }

    private var accessibilityLabel: String {
        let role = isUser ? "用户" : "助理"
        return "\(role)消息：\(message.content)"
    }
}
