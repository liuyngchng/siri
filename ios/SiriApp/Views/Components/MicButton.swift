//
//  MicButton.swift
//  SiriApp
//
//  Circular microphone button — tap to toggle recording on/off.
//  Follows Apple HIG for simple, tappable controls.
//
//  States:
//   idle              gray mic.fill         tap → start recording
//   listening         blue stop.fill        pulse ring (tap to stop)
//   recognizing       amber stop.fill       pulse ring (tap to cancel)
//   thinking          amber stop.fill       pulse ring (tap to cancel)
//   speaking          red stop.fill         pulse ring (tap to stop TTS)
//   loading/error     gray, disabled
//

import SwiftUI
import UIKit

struct MicButton: View {
    let voiceState: VoiceState
    let enabled: Bool
    let onPressStart: () -> Void
    let onPressEnd: () -> Void
    let onPressCancel: () -> Void
    let onStopSpeaking: () -> Void

    // MARK: - Adaptive sizing

    @ScaledMetric(relativeTo: .title) private var buttonSize: CGFloat = MicButtonMetrics.defaultSize

    // MARK: - Derived state

    private var isRecording: Bool {
        if case .listening = voiceState { return true }
        return false
    }

    private var isProcessing: Bool {
        switch voiceState {
        case .recognizing, .thinking: return true
        default: return false
        }
    }

    private var isSpeaking: Bool {
        if case .speaking = voiceState { return true }
        return false
    }

    private var isActive: Bool {
        isRecording || isProcessing || isSpeaking
    }

    private var isDisabled: Bool {
        switch voiceState {
        case .loading, .error: return true
        default: return false
        }
    }

    // MARK: - Styling

    private var iconName: String {
        if isProcessing { return "xmark.circle.fill" }
        if isActive { return "stop.fill" }
        return "mic.fill"
    }

    private var iconColor: Color {
        if isSpeaking { return ChatColors.micSpeakingForeground }
        if isProcessing { return .white }
        if isRecording { return ChatColors.micActiveForeground }
        return ChatColors.micIdleForeground
    }

    private var buttonBackground: Color {
        if isSpeaking { return ChatColors.micSpeakingBackground }
        if isProcessing { return .orange }
        if isRecording { return ChatColors.micActiveBackground }
        return ChatColors.micIdleBackground
    }

    private var pulseColor: Color {
        if isSpeaking { return ChatColors.micSpeakingBackground }
        if isProcessing { return .orange }
        return ChatColors.micActiveBackground
    }

    private var showPulse: Bool {
        isRecording || isProcessing || isSpeaking
    }

    private var statusHint: String {
        if isRecording { return "轻点停止" }
        if isProcessing { return "轻点取消" }
        if isSpeaking { return "轻点停止播报" }
        return "轻点开始说话"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            // Status hint above the button
            Text(statusHint)
                .font(.caption2.weight(.medium))
                .foregroundColor(ChatColors.tertiaryLabel)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color(.systemGray6).opacity(isActive ? 1 : 0.5))
                )
                .animation(.easeInOut(duration: 0.25), value: isActive)

            ZStack {
                // Pulse ring
                if showPulse {
                    PulseRing(
                        size: buttonSize * MicButtonMetrics.pulseRingScale,
                        strokeWidth: 3,
                        color: pulseColor
                    )
                }

                // Main button — simple tap gesture
                Button(action: handleTap) {
                    Image(systemName: iconName)
                        .font(.system(size: buttonSize * MicButtonMetrics.iconScale,
                                      weight: .medium))
                        .foregroundColor(iconColor)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(buttonBackground)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(isActive ? 0 : 0.08),
                                radius: 6, x: 0, y: 3)
                }
                .disabled(isDisabled)
                .opacity(enabled ? 1.0 : 0.5)
                .buttonStyle(MicButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("语音输入")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Tap action

    private func handleTap() {
        guard enabled, !isDisabled else { return }
        provideHaptic(.medium)

        switch voiceState {
        case .speaking:
            onStopSpeaking()
        case .recognizing, .thinking:
            onPressCancel()
        case .listening:
            onPressEnd()
        case .idle, .error, .loading:
            onPressStart()
        }
    }

    // MARK: - Accessibility

    private var accessibilityHint: String {
        switch voiceState {
        case .idle:       return "轻点开始录音"
        case .listening:  return "轻点以停止录音"
        case .recognizing: return "正在识别语音，轻点取消"
        case .thinking:   return "正在思考回复，轻点取消"
        case .speaking:   return "正在播报，轻点停止"
        case .error:      return "发生错误，请检查配置"
        case .loading:    return "引擎加载中"
        }
    }

    // MARK: - Haptics

    private func provideHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }
}

// MARK: - Custom button style to prevent default highlight animation

private struct MicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
