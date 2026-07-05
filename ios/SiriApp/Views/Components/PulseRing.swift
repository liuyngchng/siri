//
//  PulseRing.swift
//  SiriApp
//
//  Animated pulsing ring indicator.
//  iOS 15+: TimelineView(.animation)
//  iOS 14: Timer.publish fallback
//
//  Ported from Android: MainScreen.kt (PulseRing composable)
//

import SwiftUI

struct PulseRing: View {
    let size: CGFloat
    let strokeWidth: CGFloat
    let color: Color

    init(size: CGFloat = 48, strokeWidth: CGFloat = 3, color: Color = .blue) {
        self.size = size
        self.strokeWidth = strokeWidth
        self.color = color
    }

    @State private var scale: CGFloat = 0.85
    @State private var opacity: Double = 1.0

    var body: some View {
        if #available(iOS 15.0, *) {
            timelineRing
        } else {
            timerRing
        }
    }

    // MARK: - iOS 15+ (TimelineView)

    @available(iOS 15.0, *)
    private var timelineRing: some View {
        TimelineView(.animation) { _ in
            Circle()
                .stroke(color.opacity(opacity), lineWidth: strokeWidth)
                .scaleEffect(scale)
                .frame(width: size, height: size)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        scale = 1.25
                        opacity = 0.12
                    }
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: - iOS 14 (Timer fallback)

    private var timerRing: some View {
        let timer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

        return Circle()
            .stroke(color.opacity(opacity), lineWidth: strokeWidth)
            .scaleEffect(scale)
            .frame(width: size, height: size)
            .onReceive(timer) { _ in
                withAnimation(.easeInOut(duration: 1.2)) {
                    scale = scale == 0.85 ? 1.25 : 0.85
                    opacity = opacity == 1.0 ? 0.12 : 1.0
                }
            }
            .onAppear {
                scale = 1.25
                opacity = 0.12
            }
            .accessibilityHidden(true)
    }
}
