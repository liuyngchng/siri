//
//  MainScreen.swift
//  SiriApp
//
//  Main chat UI: message list + microphone button.
//  Ported from Android: MainScreen.kt
//

import SwiftUI
import AVFoundation

struct MainScreen: View {
    @ObservedObject var viewModel: MainViewModel
    var onNavigateToSettings: () -> Void

    @State private var showClearDialog = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Chat messages
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            // Status center when no messages
                            if viewModel.messages.isEmpty {
                                StatusCenter(voiceState: viewModel.state.voiceState)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 120)
                            }

                            // Messages
                            ForEach(viewModel.messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    onLongPress: {
                                        viewModel.speakText(msg.content)
                                    }
                                )
                            }

                            // Partial ASR text
                            if viewModel.state.partialAsrText.isNotBlank {
                                MessageBubble(
                                    message: ChatMessage(
                                        role: .user,
                                        content: viewModel.state.partialAsrText + "…"
                                    )
                                )
                            }

                            // Thinking indicator
                            if case .thinking = viewModel.state.voiceState {
                                HStack(spacing: 8) {
                                    PulseRing(size: 16, strokeWidth: 2, color: .blue)
                                    Text("思考中…")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .onChange(of: viewModel.messages.count) { _ in
                        if let last = viewModel.messages.last?.id {
                            withAnimation {
                                scrollProxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.state.assistantReply) { _ in
                        if let last = viewModel.messages.last?.id {
                            withAnimation {
                                scrollProxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }

                // Microphone button area
                MicButton(
                    voiceState: viewModel.state.voiceState,
                    enabled: viewModel.state.enginesReady,
                    onPressStart: {
                        _ = viewModel.checkConfig()
                        viewModel.startListening()
                    },
                    onPressEnd: {
                        if case .listening = viewModel.state.voiceState {
                            viewModel.stopListening()
                        }
                    },
                    onPressCancel: {
                        viewModel.cancelListening()
                    },
                    onStopSpeaking: {
                        viewModel.stopSpeaking()
                    }
                )
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemBackground))
            .navigationTitle("语音助手")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 20) {
                        // Clear history
                        if !viewModel.messages.isEmpty {
                            Button(action: { showClearDialog = true }) {
                                Image(systemName: "trash")
                                    .font(.title2)
                            }
                        }
                        // Settings
                        Button(action: onNavigateToSettings) {
                            Image(systemName: "gearshape")
                                .font(.title2)
                        }
                    }
                }
            }
            .alert(isPresented: $showClearDialog) {
                // iOS 15+: use .destructive style; iOS 14: fall back to .default
                if #available(iOS 15.0, *) {
                    return Alert(
                        title: Text("清除历史"),
                        message: Text("确定要清除所有对话记录吗？此操作不可撤销。"),
                        primaryButton: .destructive(Text("确定"), action: { viewModel.clearHistory() }),
                        secondaryButton: .cancel(Text("取消"))
                    )
                } else {
                    return Alert(
                        title: Text("清除历史"),
                        message: Text("确定要清除所有对话记录吗？此操作不可撤销。"),
                        primaryButton: .default(Text("确定"), action: { viewModel.clearHistory() }),
                        secondaryButton: .cancel(Text("取消"))
                    )
                }
            }
            .onAppear {
                _ = viewModel.checkConfig()
                if !viewModel.state.enginesReady {
                    viewModel.initializeEngines()
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Status Center (empty state)

struct StatusCenter: View {
    let voiceState: VoiceState

    var body: some View {
        VStack(spacing: 16) {
            switch voiceState {
            case .loading:
                PulseRing(size: 48, strokeWidth: 3, color: .blue)
                Text(voiceState.message)
                    .font(.headline)
                    .foregroundColor(.secondary)

            case .error(let msg):
                Text(msg)
                    .font(.headline)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)

            case .idle:
                Text("按住麦克风开始说话")
                    .font(.headline)
                    .foregroundColor(.secondary)

            default:
                EmptyView()
            }
        }
    }
}
