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

    @State private var isPressing = false
    @State private var thresholdReached = false
    @State private var showReminder = false
    @State private var pressWorkItem: DispatchWorkItem?

    /// Duration in seconds the user must hold before the press is treated as
    /// intentional (triggers recording). Values below this are treated as a tap.
    private let longPressThreshold: TimeInterval = 0.3

    /// How long the "请按住说话" reminder stays visible after a tap.
    private let reminderDismissDelay: TimeInterval = 1.5

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

    var body: some View {
        VStack(spacing: 12) {
            // Reminder tip above the button
            if showReminder {
                Text("请按住说话")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.2), value: showReminder)
            }

            ZStack {
                // Pulse animation when active
                if isActive {
                    PulseRing(size: 104, strokeWidth: 3, color: isSpeaking ? .red : .blue)
                }

                // Main button
                Image(systemName: iconName)
                    .font(.system(size: 29))
                    .foregroundColor(iconColor)
                    .frame(width: 86, height: 86)
                    .background(backgroundColor)
                    .clipShape(Circle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                handlePressDown()
                            }
                            .onEnded { _ in
                                handlePressUp()
                            }
                    )
                    .disabled(!enabled && !isSpeaking)
                    .opacity(enabled || isSpeaking ? 1.0 : 0.5)
            }
        }
    }

    // MARK: - Gesture handlers

    private func handlePressDown() {
        guard enabled else { return }

        // Ignore presses during system-processing states.
        // .listening already has thresholdReached=true from the press that
        // started it, so we don't re-enter here (isPressing stays true).
        guard !isRecognizingOrThinking else { return }

        if !isPressing {
            isPressing = true
            thresholdReached = false
            showReminder = false
            pressWorkItem?.cancel()

            if isInteractive {
                // idle or speaking: start the long-press timer.
                let work = DispatchWorkItem { [self] in
                    guard isPressing else { return }
                    thresholdReached = true

                    if isSpeaking {
                        // Stop TTS and immediately start recording.
                        // Both are synchronous main-actor calls — no gap needed.
                        onStopSpeaking()
                        let gen = UIImpactFeedbackGenerator(style: .light)
                        gen.prepare()
                        gen.impactOccurred()
                        onPressStart()
                    } else {
                        // Idle → start recording with haptic.
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
            // else: .listening — already recording, no timer needed.
        }
    }

    private func handlePressUp() {
        guard isPressing else { return }
        isPressing = false
        pressWorkItem?.cancel()
        pressWorkItem = nil

        if !thresholdReached {
            // --- Short press / tap (released before threshold) ---

            if isSpeaking {
                // Red button tap: no action.
            } else if case .idle = voiceState {
                // Gray button tap: show reminder with haptic.
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.impactOccurred()
                withAnimation { showReminder = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + reminderDismissDelay) {
                    showReminder = false
                }
            } else if case .listening = voiceState {
                // Short press during listening: cancel.
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred()
                onPressCancel()
            }
            // .recognizing/.thinking: unreachable (guarded in handlePressDown).
        } else {
            // --- Long press (threshold reached) ---

            if case .listening = voiceState {
                // Release after holding: stop recording and process.
                onPressEnd()
            }
            // .speaking → already handled inside the timer (stopped + started).
            // .idle → already handled inside the timer (started recording).
        }

        thresholdReached = false
    }

    // MARK: - Styling

    private var iconName: String {
        if isActive { return "stop.fill" }
        if isSpeaking { return "stop.fill" }
        return "mic.fill"
    }

    private var iconColor: Color {
        if isSpeaking { return .white }
        if isActive { return .white }
        return .blue
    }

    private var backgroundColor: Color {
        if isSpeaking { return .red }
        if isActive { return .blue }
        return Color(.systemGray5)
    }
}
