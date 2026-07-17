//
//  MainScreen.swift
//  SiriApp
//
//  Main chat UI: message list + microphone button.
//  Redesigned following Apple HIG with adaptive spacing,
//  smooth animations, and proper empty-state treatment.
//

import SwiftUI
import AVFoundation

// MARK: - Main Screen

struct MainScreen: View {
    @ObservedObject var viewModel: MainViewModel
    var onNavigateToSettings: () -> Void

    @State private var showClearDialog = false

    var body: some View {
        NavigationView {
            ZStack {
                // Full-screen background that extends behind the nav bar
                // to prevent chat content from visually bleeding through.
                Color(.systemBackground).edgesIgnoringSafeArea(.all)

                Group {
                    if #available(iOS 15.0, *) {
                        chatContent
                            .safeAreaInset(edge: .bottom, spacing: 0) { micBar }
                    } else {
                        VStack(spacing: 0) {
                            chatContent
                            micBar
                                .padding(.bottom, ChatSpacing.pt32)
                        }
                    }
                }
            }
            .navigationTitle("语音助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .alert(isPresented: $showClearDialog) { clearConfirmationAlert }
            .onAppear {
                _ = viewModel.checkConfig()
                if !viewModel.state.enginesReady {
                    viewModel.initializeEngines()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Chat Content (scrollable area)

    private var chatContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if viewModel.messages.isEmpty {
                            StatusCenter(voiceState: viewModel.state.voiceState)
                                .frame(minHeight: geometry.size.height)
                        } else {
                            ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, msg in
                                messageRow(at: index, message: msg, availableWidth: geometry.size.width)
                                    .id(msg.id)
                            }
                        }

                        // Partial ASR text
                        if viewModel.state.partialAsrText.isNotBlank {
                            MessageBubble(
                                message: ChatMessage(role: .user, content: viewModel.state.partialAsrText + "…"),
                                availableWidth: geometry.size.width
                            )
                            .padding(.bottom, ChatSpacing.pt4)
                        }

                        // Thinking indicator
                        if case .thinking = viewModel.state.voiceState {
                            ThinkingIndicator()
                                .padding(.leading, ChatBubbleMetrics.cornerRadius)
                                .padding(.bottom, ChatSpacing.pt8)
                        }
                    }
                    .padding(.horizontal, ChatSpacing.listHorizontal)
                    .padding(.top, ChatSpacing.listTopInset)
                    .padding(.bottom, ChatSpacing.listBottomInset)
                }
                .onChange(of: viewModel.messages.count) { _ in
                    scrollToBottom(scrollProxy)
                }
                .onChange(of: viewModel.state.assistantReply) { _ in
                    scrollToBottom(scrollProxy)
                }
            }
        }
    }

    // MARK: - Message Row (with contextual spacing + date separator)

    private func messageRow(at index: Int, message: ChatMessage, availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            if shouldShowDateSeparator(at: index) {
                DateSeparator(date: message.timestamp)
                    .padding(.vertical, ChatSpacing.pt8)
            }

            MessageBubble(message: message, availableWidth: availableWidth) {
                viewModel.speakText(message.content)
            }
            .padding(.bottom, bubbleSpacing(at: index))
            .padding(.top, index == 0 ? ChatSpacing.pt8 : 0)
        }
    }

    private func bubbleSpacing(at index: Int) -> CGFloat {
        guard index + 1 < viewModel.messages.count else { return 0 }
        let current = viewModel.messages[index]
        let next = viewModel.messages[index + 1]
        let sameRole = current.role == next.role
        let closeInTime = next.timestamp.timeIntervalSince(current.timestamp) < 120
        return (sameRole && closeInTime)
            ? ChatSpacing.sameSenderSpacing
            : ChatSpacing.differentSenderSpacing
    }

    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard index > 0 else { return false }
        let current = viewModel.messages[index]
        let previous = viewModel.messages[index - 1]
        return !Calendar.current.isDate(current.timestamp, inSameDayAs: previous.timestamp)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = viewModel.messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    // MARK: - Mic Bar (blurred bottom bar)

    private var micBar: some View {
        VStack(spacing: 0) {
            // Subtle separator line
            Rectangle()
                .fill(Color(.separator).opacity(0.3))
                .frame(height: 0.5)

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
                }
            )
            .padding(.top, ChatSpacing.pt8)
            .padding(.bottom, ChatSpacing.pt6)
        }
        .background(
            BlurView(style: .systemMaterial)
                .edgesIgnoringSafeArea(.bottom)
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
                if !viewModel.messages.isEmpty {
                    Button(action: { showClearDialog = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .accessibilityLabel("清除历史")
                }
                Button(action: onNavigateToSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                }
                .accessibilityLabel("设置")
            }
        }
    }

    // MARK: - Alert

    private var clearConfirmationAlert: Alert {
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
}

// MARK: - Status Center (empty state)

struct StatusCenter: View {
    let voiceState: VoiceState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            content
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch voiceState {
        case .loading(let msg):
            VStack(spacing: ChatSpacing.pt16) {
                PulseRing(size: 48, strokeWidth: 3, color: .blue)
                Text(msg)
                    .font(.subheadline)
                    .foregroundColor(ChatColors.secondaryLabel)
            }

        case .error(let msg):
            VStack(spacing: ChatSpacing.pt12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                Text(msg)
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, ChatSpacing.pt32)

        case .idle:
            VStack(spacing: ChatSpacing.pt16) {
                if #available(iOS 15.0, *) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(ChatColors.emptyStateAccent)
                        .symbolRenderingMode(.hierarchical)
                } else {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(ChatColors.emptyStateAccent)
                }

                VStack(spacing: ChatSpacing.pt6) {
                    Text("语音助手")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(ChatColors.emptyStatePrimary)

                    Text("按住麦克风按钮开始说话")
                        .font(.body)
                        .foregroundColor(ChatColors.emptyStateSecondary)
                }
            }
            .frame(maxWidth: 280)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("语音助手，按住麦克风按钮开始说话")

        default:
            EmptyView()
        }
    }
}

// MARK: - Date Separator

struct DateSeparator: View {
    let date: Date

    var body: some View {
        Text(date, style: .date)
            .font(.caption2)
            .foregroundColor(ChatColors.tertiaryLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
    @State private var dotPhase = 0

    var body: some View {
        HStack(spacing: 10) {
            PulseRing(size: 14, strokeWidth: 2, color: ChatColors.thinkingTint)

            Text("思考中")
                .font(.subheadline)
                .foregroundColor(ChatColors.thinkingForeground)

            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(ChatColors.tertiaryLabel)
                        .frame(width: 4, height: 4)
                        .opacity(dotPhase == i ? 1.0 : 0.25)
                }
            }
        }
        .padding(.vertical, ChatSpacing.pt6)
        .padding(.horizontal, ChatSpacing.pt12)
        .background(
            RoundedRectangle(cornerRadius: ChatBubbleMetrics.smallCornerRadius)
                .fill(Color(.systemGray6))
        )
        .onAppear { animateDots() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("助理正在思考")
    }

    private func animateDots() {
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
            withAnimation(.easeInOut(duration: 0.3)) {
                dotPhase = (dotPhase + 1) % 3
            }
        }
    }
}
