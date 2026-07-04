//
//  MicButton.swift
//  SiriApp
//
//  Circular microphone button with press-hold-release gesture.
//  - Press and hold: start recording
//  - Short press (<300ms): cancel
//  - Release: stop recording and process
//  - Speaking state: tap to stop
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
    @State private var pressStartTime: Date?

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

    var body: some View {
        ZStack {
            // Pulse animation when listening
            if isActive {
                PulseRing(size: 130, strokeWidth: 3, color: .blue)
            }

            // Main button
            Image(systemName: iconName)
                .font(.system(size: 36))
                .foregroundColor(iconColor)
                .frame(width: 108, height: 108)
                .background(backgroundColor)
                .clipShape(Circle())
                // DragGesture(minimumDistance: 0) detects touch-down immediately,
                // unlike LongPressGesture which has inherent delay. This is the
                // standard SwiftUI pattern for press-and-hold-to-talk buttons.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard enabled, !isSpeaking else { return }
                            if !isPressing {
                                isPressing = true
                                pressStartTime = Date()
                                if case .idle = voiceState {
                                    // Prepare haptic early for responsive feel
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.prepare()
                                    generator.impactOccurred()
                                    onPressStart()
                                }
                            }
                        }
                        .onEnded { _ in
                            guard isPressing else { return }
                            isPressing = false

                            if case .listening = voiceState {
                                let duration = pressStartTime.map { Date().timeIntervalSince($0) } ?? 0
                                if duration < 0.3 {
                                    // Short press = cancel
                                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                                    generator.impactOccurred()
                                    onPressCancel()
                                } else {
                                    onPressEnd()
                                }
                            }
                            pressStartTime = nil
                        }
                )
                // Tap to stop speaking (only when speaking)
                .onTapGesture {
                    if isSpeaking {
                        onStopSpeaking()
                    }
                }
                .disabled(!enabled && !isSpeaking)
                .opacity(enabled || isSpeaking ? 1.0 : 0.5)
        }
    }

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
