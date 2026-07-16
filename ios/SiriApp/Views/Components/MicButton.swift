//
//  MicButton.swift
//  SiriApp
//
//  Circular microphone button with hybrid gesture model:
//
//  - TAP (idle)       → toggle recording on; tap again to stop + process.
//  - LONG PRESS (idle) → hold-to-talk recording; release to stop + process.
//  - TAP (any active) → cancel / stop.
//
//  States:
//   idle              gray mic.fill        tap → toggle,  hold → talk
//   listening         blue stop.fill       pulse ring (recording)
//   recognizing       amber stop.fill      pulse ring (processing, tap to cancel)
//   thinking          amber stop.fill      pulse ring (processing, tap to cancel)
//   speaking          red stop.fill        pulse ring (tap to stop TTS only)
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

    // MARK: - Internal gesture state

    @State private var isPressing = false
    @State private var thresholdReached = false
    @State private var showReminder = false
    @State private var pressWorkItem: DispatchWorkItem?
    @State private var isToggleMode = false

    private let longPressThreshold: TimeInterval = 0.3

    // MARK: - Derived state

    /// Recording (either toggle or hold mode).
    private var isRecording: Bool {
        if case .listening = voiceState { return true }
        return false
    }

    /// System is processing after recording — tap to cancel.
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

    /// Tapping the button during these states triggers a cancel/stop.
    private var isActive: Bool {
        isRecording || isProcessing || isSpeaking
    }

    /// States where gesture is completely disabled.
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
        if isToggleMode, isRecording { return "轻点停止" }
        if isRecording { return "松手停止" }
        if isProcessing { return "轻点取消" }
        if isSpeaking { return "轻点停止播报" }
        return "轻点切换 / 按住说话"
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
                    Capsule().fill(Color(.systemGray6).opacity(showReminder ? 1 : 0))
                )
                .opacity(isActive || showReminder ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: isActive)
                .animation(.easeInOut(duration: 0.25), value: showReminder)

            ZStack {
                // Pulse ring
                if showPulse {
                    PulseRing(
                        size: buttonSize * MicButtonMetrics.pulseRingScale,
                        strokeWidth: 3,
                        color: pulseColor
                    )
                }

                // Main button
                Image(systemName: iconName)
                    .font(.system(size: buttonSize * MicButtonMetrics.iconScale,
                                  weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(buttonBackground)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(isActive ? 0 : 0.08),
                            radius: 6, x: 0, y: 3)
                    .scaleEffect(isPressing && !isDisabled
                        ? MicButtonMetrics.pressScale : 1.0)
                    .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7),
                               value: isPressing)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in handlePressDown() }
                            .onEnded { _ in handlePressUp() }
                    )
                    .disabled(isDisabled)
                    .opacity(enabled ? 1.0 : 0.5)
            }
        }
        .onChange(of: voiceState) { newState in
            // Reset toggle flag when returning to idle
            if case .idle = newState {
                isToggleMode = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("语音输入")
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Accessibility

    private var accessibilityHint: String {
        switch voiceState {
        case .idle:       return "轻点开始录音，或按住说话"
        case .listening:  return isToggleMode ? "轻点以停止录音" : "松手以停止录音"
        case .recognizing: return "正在识别语音，轻点取消"
        case .thinking:   return "正在思考回复，轻点取消"
        case .speaking:   return "正在播报，轻点停止"
        case .error:      return "发生错误，请检查配置"
        case .loading:    return "引擎加载中"
        }
    }

    // MARK: - Gesture: press down

    private func handlePressDown() {
        guard enabled, !isDisabled else { return }

        // Universal cancel: processing or speaking → cancel immediately on press
        if isProcessing {
            provideHaptic(.heavy)
            onPressCancel()
            return
        }
        if isSpeaking {
            provideHaptic(.light)
            onStopSpeaking()
            return
        }

        // Idle or recording — start tap-vs-hold detection
        if !isPressing {
            isPressing = true
            thresholdReached = false
            showReminder = false
            pressWorkItem?.cancel()

            let work = DispatchWorkItem { [self] in
                guard isPressing else { return }
                thresholdReached = true

                // Long press threshold reached
                if case .idle = voiceState {
                    // Hold-to-talk
                    isToggleMode = false
                    provideHaptic(.light)
                    onPressStart()
                }
                // During toggle recording: hold does nothing
            }
            pressWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + longPressThreshold,
                execute: work
            )
        }
    }

    // MARK: - Gesture: press up

    private func handlePressUp() {
        guard isPressing else { return }
        isPressing = false
        pressWorkItem?.cancel()
        pressWorkItem = nil

        if !thresholdReached {
            // Short tap (released before 0.3s threshold)
            switch voiceState {
            case .idle:
                // Tap → start toggle recording
                isToggleMode = true
                showReminder = false
                provideHaptic(.light)
                onPressStart()

            case .listening where isToggleMode:
                // Tap again → stop toggle recording
                isToggleMode = false
                provideHaptic(.medium)
                onPressEnd()

            default:
                break
            }
        } else {
            // Long press threshold was reached
            if case .listening = voiceState, !isToggleMode {
                // Hold-to-talk release → stop recording
                provideHaptic(.medium)
                onPressEnd()
            }
            // Toggle mode + threshold reached → ignore (hold does nothing in toggle mode)
        }

        thresholdReached = false
    }

    // MARK: - Haptics

    private func provideHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }
}
