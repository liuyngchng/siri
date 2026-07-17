//
//  ChatInputBar.swift
//  SiriApp
//
//  Mode-switchable input bar: text mode (keyboard) ↔ voice mode (press-and-hold).
//  Follows the familiar WeChat-style toggle pattern.
//

import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    let voiceState: VoiceState
    let enginesReady: Bool
    let onSendText: () -> Void
    let onPressStart: () -> Void
    let onPressEnd: () -> Void
    let onPressCancel: () -> Void

    @State private var isVoiceMode = false

    var body: some View {
        VStack(spacing: 0) {
            // Subtle separator
            Rectangle()
                .fill(Color(.separator).opacity(0.3))
                .frame(height: 0.5)

            Group {
                if isVoiceMode {
                    voiceModeContent
                } else {
                    textModeContent
                }
            }
            .padding(.horizontal, InputBarMetrics.barHPadding)
            .padding(.vertical, InputBarMetrics.barVPadding)
        }
        .background(
            BlurView(style: .systemMaterial)
                .edgesIgnoringSafeArea(.bottom)
        )
        .onChange(of: voiceState) { state in
            // Auto-switch back to text mode after a completed voice interaction
            if case .idle = state {
                isVoiceMode = false
            }
        }
    }

    // MARK: - Text Mode

    private var textModeContent: some View {
        HStack(spacing: InputBarMetrics.elementSpacing) {
            TextField("输入消息…", text: $text, onCommit: {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSendText()
                }
            })
            .textFieldStyle(PlainTextFieldStyle())
            .padding(.horizontal, InputBarMetrics.fieldHPadding)
            .padding(.vertical, InputBarMetrics.fieldVPadding)
            .background(
                RoundedRectangle(cornerRadius: InputBarMetrics.fieldCornerRadius)
                    .fill(Color(.systemGray6))
            )
            .disabled(isTextFieldDisabled)

            textModeTrailingButton
        }
    }

    @ViewBuilder
    private var textModeTrailingButton: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            // Send button — tap to send the typed message
            Button(action: onSendText) {
                Image(systemName: "arrow.up")
                    .font(.system(size: MicButtonMetrics.compactSize * MicButtonMetrics.compactIconScale,
                                  weight: .semibold))
                    .foregroundColor(ChatColors.micIdleForeground)
                    .frame(width: MicButtonMetrics.compactSize,
                           height: MicButtonMetrics.compactSize)
                    .background(
                        Circle().fill(ChatColors.micIdleBackground)
                    )
            }
            .disabled(!enginesReady)
            .accessibilityLabel("发送消息")
        } else {
            // Mic toggle — tap to switch to voice mode
            Button(action: {
                dismissKeyboard()
                isVoiceMode = true
            }) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: MicButtonMetrics.compactSize,
                           height: MicButtonMetrics.compactSize)
            }
            .disabled(!enginesReady)
            .accessibilityLabel("切换到语音输入")
        }
    }

    // MARK: - Voice Mode

    private var voiceModeContent: some View {
        HStack(spacing: 0) {
            // Keyboard toggle — switches back to text mode
            Button(action: { isVoiceMode = false }) {
                Image(systemName: "keyboard")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("切换到文字输入")

            Spacer()

            // Full-size mic button for press-and-hold recording
            MicButton(
                voiceState: voiceState,
                enabled: enginesReady,
                onPressStart: onPressStart,
                onPressEnd: onPressEnd,
                onPressCancel: onPressCancel
            )

            Spacer()

            // Invisible spacer to balance the keyboard button
            Color.clear
                .frame(width: 40, height: 40)
        }
    }

    // MARK: - Derived State

    private var isTextFieldDisabled: Bool {
        switch voiceState {
        case .listening, .recognizing, .thinking, .speaking:
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
