//
//  ModelSlotCard.swift
//  SiriApp
//
//  Card UI for a model file slot (ASR, TTS, Vocoder).
//  Shows ready state, download button, upload button, progress.
//  Ported from Android: ModelSetupScreen.kt (ModelSlotCard)
//

import SwiftUI

struct SlotState {
    var extracting: Bool = false
    var progress: Float = 0
    var error: String? = nil
}

struct ModelSlotCard: View {
    let label: String
    let isReady: Bool
    let slot: SlotState
    let onSelect: () -> Void
    let onDownload: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(isReady ? Color(red: 0.3, green: 0.69, blue: 0.31) : Color(red: 1.0, green: 0.6, blue: 0.0))
                    .font(.title3)
                Text(label)
                    .font(.headline)
            }
            .padding(.bottom, 4)

            if slot.extracting {
                // Progress
                Text("处理中 \(Int(slot.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.bottom, 4)

                if slot.progress <= 0 {
                    ProgressView()
                        .progressViewStyle(LinearProgressViewStyle())
                } else {
                    ProgressView(value: Double(slot.progress))
                        .progressViewStyle(LinearProgressViewStyle())
                }
            } else if !isReady {
                // Action buttons
                HStack(spacing: 12) {
                    if onDownload != nil {
                        Button(action: { onDownload?() }) {
                            Text("下载")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BorderedProminentButtonStyle())
                    }
                    Button(action: onSelect) {
                        Text("上传")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
                .padding(.top, 8)
            }

            // Error
            if let error = slot.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}
