//
//  MicButton.swift
//  SiriApp
//
//  Circular microphone button — press-and-hold to record.
//
//  Interaction model (two states):
//   "录音中"  — press & hold: recording in progress
//   "处理中"  — ASR → LLM → display → (optional) TTS
//
//  Press during "处理中" cancels everything and immediately
//  starts a new recording.
//

import SwiftUI
import UIKit

struct MicButton: View {
    let voiceState: VoiceState
    let enabled: Bool
    let onPressStart: () -> Void
    let onPressEnd: () -> Void
    let onPressCancel: () -> Void

    // MARK: - Adaptive sizing

    @ScaledMetric(relativeTo: .title) private var buttonSize: CGFloat = MicButtonMetrics.defaultSize

    @State private var isPressed = false

    // MARK: - Derived state

    private var isRecording: Bool {
        if case .listening = voiceState { return true }
        return false
    }

    private var isProcessing: Bool {
        switch voiceState {
        case .recognizing, .thinking, .speaking: return true
        default: return false
        }
    }

    private var isActive: Bool {
        isRecording || isPressed
    }

    private var isDisabled: Bool {
        switch voiceState {
        case .loading, .error: return true
        default: return false
        }
    }

    // MARK: - Styling

    private var iconName: String {
        if isActive { return "stop.fill" }
        return "mic.fill"
    }

    private var iconColor: Color {
        if isActive { return ChatColors.micActiveForeground }
        return ChatColors.micIdleForeground
    }

    private var buttonBackground: Color {
        if isActive { return ChatColors.micActiveBackground }
        return ChatColors.micIdleBackground
    }

    private var pulseColor: Color {
        ChatColors.micActiveBackground
    }

    private var showPulse: Bool {
        isRecording
    }

    // MARK: - Body

    var body: some View {
        ZStack {
                // Pulse ring
                if showPulse {
                    PulseRing(
                        size: buttonSize * MicButtonMetrics.pulseRingScale,
                        strokeWidth: 3,
                        color: pulseColor
                    )
                }

                // Main button — press-and-hold gesture
                Image(systemName: iconName)
                    .font(.system(size: buttonSize * MicButtonMetrics.iconScale,
                                  weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(buttonBackground)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(isActive ? 0 : 0.08),
                            radius: 6, x: 0, y: 3)
                    .opacity(enabled ? 1.0 : 0.5)
                    .scaleEffect(isPressed ? 0.92 : 1.0)
                    .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7),
                               value: isPressed)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !isPressed {
                                    isPressed = true
                                    handlePressDown()
                                }
                            }
                            .onEnded { _ in
                                isPressed = false
                                handlePressUp()
                            }
                    )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("语音输入")
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Press actions

    private func handlePressDown() {
        guard enabled, !isDisabled else { return }
        provideHaptic(.medium)

        // If processing, cancel current pipeline first
        switch voiceState {
        case .recognizing, .thinking, .speaking:
            onPressCancel()
        default:
            break
        }

        onPressStart()
    }

    private func handlePressUp() {
        guard enabled else { return }

        if case .listening = voiceState {
            onPressEnd()
        }
    }

    // MARK: - Accessibility

    private var accessibilityHint: String {
        switch voiceState {
        case .idle:        return "按住开始录音"
        case .listening:   return "松开结束录音"
        case .recognizing: return "按住以重新开始录音"
        case .thinking:    return "按住以重新开始录音"
        case .speaking:    return "按住以重新开始录音"
        case .error:       return "发生错误，请检查配置"
        case .loading:     return "引擎加载中"
        }
    }

    // MARK: - Haptics

    private func provideHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }
}
