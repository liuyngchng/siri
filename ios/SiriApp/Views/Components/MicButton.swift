//
//  MicButton.swift
//  SiriApp
//
//  Press-and-hold microphone button — redesigned following Apple HIG.
//
//  Visual style: filled tinted circle (blue idle / red recording) with a
//  descriptive label underneath, so users immediately understand the
//  "press and hold to talk" interaction.
//
//  Interaction model:
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

    /// When true, renders a compact icon-only button for use in an input bar.
    var compact: Bool = false

    // MARK: - Adaptive sizing

    private var effectiveSize: CGFloat {
        compact ? MicButtonMetrics.compactSize : MicButtonMetrics.defaultSize
    }

    private var effectiveIconScale: CGFloat {
        compact ? MicButtonMetrics.compactIconScale : MicButtonMetrics.iconScale
    }

    @ScaledMetric(relativeTo: .title) private var scaledDefaultSize: CGFloat = MicButtonMetrics.defaultSize
    @ScaledMetric(relativeTo: .title) private var scaledCompactSize: CGFloat = MicButtonMetrics.compactSize

    private var buttonSize: CGFloat {
        compact ? scaledCompactSize : scaledDefaultSize
    }

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
        if isRecording || isPressed { return "stop.fill" }
        return "mic.fill"
    }

    private var iconColor: Color {
        if !enabled || isDisabled { return ChatColors.micDisabledForeground }
        if isActive { return ChatColors.micActiveForeground }
        return ChatColors.micIdleForeground
    }

    private var buttonBackground: Color {
        if !enabled || isDisabled { return ChatColors.micDisabledBackground }
        if isActive { return ChatColors.micActiveBackground }
        return ChatColors.micIdleBackground
    }

    private var pulseColor: Color {
        ChatColors.micActiveBackground
    }

    private var showPulse: Bool {
        isRecording
    }

    // MARK: - Label

    private var labelText: String {
        if !enabled || isDisabled {
            if case .loading(let msg) = voiceState { return msg }
            if case .error = voiceState { return "错误" }
            return "不可用"
        }
        if isRecording { return "松开 结束" }
        if isProcessing {
            if case .recognizing = voiceState { return "识别中…" }
            if case .thinking = voiceState { return "思考中…" }
            if case .speaking = voiceState { return "播报中…" }
            return "处理中…"
        }
        return "按住 说话"
    }

    private var labelColor: Color {
        if !enabled || isDisabled { return Color(.tertiaryLabel) }
        if isActive { return ChatColors.micActiveBackground }
        return Color(.secondaryLabel)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: compact ? 0 : ChatSpacing.pt8) {
            ZStack {
                // Pulse ring while recording (full-size only)
                if showPulse, !compact {
                    PulseRing(
                        size: buttonSize * MicButtonMetrics.pulseRingScale,
                        strokeWidth: 3,
                        color: pulseColor
                    )
                }

                // Main button
                Image(systemName: iconName)
                    .font(.system(size: buttonSize * effectiveIconScale,
                                  weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(
                        Circle()
                            .fill(buttonBackground)
                    )
                    .shadow(color: Color.black.opacity(compact ? 0.10 : 0.15),
                            radius: compact ? 4 : 10, x: 0, y: compact ? 2 : 4)
                    .scaleEffect(isPressed ? MicButtonMetrics.pressScale : 1.0)
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

            // Descriptive label (hidden in compact mode)
            if !compact {
                Text(labelText)
                    .font(.caption.weight(.medium))
                    .foregroundColor(labelColor)
                    .animation(.easeInOut(duration: 0.2), value: labelText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityRemoveTraits(.isImage)
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

    private var accessibilityLabelText: String {
        if !enabled || isDisabled {
            if case .loading(let msg) = voiceState { return msg }
            return "语音输入不可用"
        }
        if isRecording { return "松开结束录音" }
        if isProcessing { return "按住重新开始" }
        return "按住开始录音"
    }

    private var accessibilityHint: String {
        switch voiceState {
        case .idle:        return ""
        case .listening:   return ""
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
