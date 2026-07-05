//
//  MicButton.swift
//  SiriApp
//
//  Circular microphone button with press-hold-release gesture.
//
//  Behavior:
//  - Idle (gray):   Tap → show "请按住说话" reminder. Long press → start recording.
//  - Listening (blue):  Release → stop + process. Short release → cancel.
//  - Speaking (red):    Tap → no action. Long press → stop playback + start recording.
//  - Recognizing/Thinking (blue): gesture ignored (system processing).
//
//  Ported from Android: MainScreen.kt (MicButton composable)
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

    /// Button diameter that scales with Dynamic Type.
    @ScaledMetric(relativeTo: .title) private var buttonSize: CGFloat = MicButtonMetrics.defaultSize

    @State private var isPressing = false
    @State private var thresholdReached = false
    @State private var showReminder = false
    @State private var pressWorkItem: DispatchWorkItem?

    /// Duration in seconds the user must hold before the press is treated as
    /// intentional (triggers recording). Values below this are treated as a tap.
    private let longPressThreshold: TimeInterval = 0.3

    /// How long the "请按住说话" reminder stays visible after a tap.
    private let reminderDismissDelay: TimeInterval = 1.5

    // MARK: - Computed state

    private var isActive: Bool {
        switch voiceState {
        case .listening, .recognizing, .thinking: return true
        default: return false
        }
    }

    private var isSpeaking: Bool {
        if case .speaking = voiceState { return true }
        return false
    }

    /// States where the gesture should start a press timer
    /// (idle: wait for threshold to start recording,
    ///  speaking: wait for threshold to stop + record).
    /// Other active states (.listening/.recognizing/.thinking) are ignored.
    private var isInteractive: Bool {
        switch voiceState {
        case .idle, .speaking: return true
        default: return false
        }
    }

    private var isRecognizingOrThinking: Bool {
        switch voiceState {
        case .recognizing, .thinking: return true
        default: return false
        }
    }

    // MARK: - Styling

    private var iconName: String {
        if isActive { return "stop.fill" }
        if isSpeaking { return "stop.fill" }
        return "mic.fill"
    }

    private var iconColor: Color {
        if isSpeaking { return ChatColors.micSpeakingForeground }
        if isActive  { return ChatColors.micActiveForeground }
        return ChatColors.micIdleForeground
    }

    private var buttonBackground: Color {
        if isSpeaking { return ChatColors.micSpeakingBackground }
        if isActive  { return ChatColors.micActiveBackground }
        return ChatColors.micIdleBackground
    }

    private var pulseColor: Color {
        isSpeaking ? ChatColors.micSpeakingBackground : ChatColors.micActiveBackground
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            // Reminder tip above the button
            if showReminder {
                Text("请按住说话")
                    .font(.caption.weight(.medium))
                    .foregroundColor(ChatColors.secondaryLabel)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(.systemGray6)))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.25), value: showReminder)
            }

            ZStack {
                // Pulse animation when active
                if isActive {
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
                    .shadow(color: Color.black.opacity(isActive || isSpeaking ? 0 : 0.08),
                            radius: 6, x: 0, y: 3)
                    .scaleEffect(isPressing && (isInteractive || (isActive && !isRecognizingOrThinking))
                        ? MicButtonMetrics.pressScale : 1.0)
                    .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7),
                               value: isPressing)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in handlePressDown() }
                            .onEnded { _ in handlePressUp() }
                    )
                    .disabled(!enabled && !isSpeaking)
                    .opacity(enabled || isSpeaking ? 1.0 : 0.5)
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
        case .idle:       return "按住开始录音，松手结束"
        case .listening:  return "正在录音，松开以结束"
        case .recognizing: return "正在识别语音"
        case .thinking:   return "正在思考回复"
        case .speaking:   return "正在播报，按住可打断并重新录音"
        case .error:      return "发生错误，请检查配置"
        case .loading:    return "引擎加载中"
        }
    }

    // MARK: - Gesture handlers

    private func handlePressDown() {
        guard enabled else { return }

        // Ignore presses during system-processing states.
        guard !isRecognizingOrThinking else { return }

        if !isPressing {
            isPressing = true
            thresholdReached = false
            showReminder = false
            pressWorkItem?.cancel()

            if isInteractive {
                let work = DispatchWorkItem { [self] in
                    guard isPressing else { return }
                    thresholdReached = true

                    if isSpeaking {
                        onStopSpeaking()
                        let gen = UIImpactFeedbackGenerator(style: .light)
                        gen.prepare()
                        gen.impactOccurred()
                        onPressStart()
                    } else {
                        let gen = UIImpactFeedbackGenerator(style: .light)
                        gen.prepare()
                        gen.impactOccurred()
                        onPressStart()
                    }
                }
                pressWorkItem = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + longPressThreshold,
                    execute: work
                )
            }
        }
    }

    private func handlePressUp() {
        guard isPressing else { return }
        isPressing = false
        pressWorkItem?.cancel()
        pressWorkItem = nil

        if !thresholdReached {
            if isSpeaking {
                // Red button tap: no action.
            } else if case .idle = voiceState {
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.impactOccurred()
                withAnimation { showReminder = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + reminderDismissDelay) {
                    showReminder = false
                }
            } else if case .listening = voiceState {
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred()
                onPressCancel()
            }
        } else {
            if case .listening = voiceState {
                onPressEnd()
            }
        }

        thresholdReached = false
    }
}
