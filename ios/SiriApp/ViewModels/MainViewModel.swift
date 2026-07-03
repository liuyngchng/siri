//
//  MainViewModel.swift
//  SiriApp
//
//  Main pipeline orchestrator: ASR → LLM → TTS → Audio playback.
//  Ported from Android: MainViewModel.kt
//

import Foundation
import Combine
import os.log

@MainActor
class MainViewModel: ObservableObject {
    @Published var state = AppState()
    @Published var messages: [ChatMessage] = []
    @Published var assistantReply: String = ""

    private let audioRecorder = AudioRecorder()
    private let audioPlayer = AudioPlayer()
    private let configRepo = ConfigRepository()
    private let documentsDir: URL

    private lazy var asrEngine: SherpaAsrEngine = {
        SherpaAsrEngine(documentsDir: documentsDir)
    }()
    private lazy var ttsEngine: SherpaTtsEngine = {
        SherpaTtsEngine(documentsDir: documentsDir)
    }()
    private lazy var llmClient = LlmClient(configRepository: configRepo)
    private(set) lazy var chatSession = ChatSession(llmClient: llmClient)

    private var recordingCancellable: AnyCancellable?
    private var streamingCancellable: AnyCancellable?
    private var speakingTask: Task<Void, Never>?
    private var engineCleanup: (() -> Void)?

    init() {
        documentsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        // Observe chat messages
        chatSession.$messages
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)
    }

    // MARK: - Initialization

    func initializeEngines() {
        state.voiceState = .loading("模型加载中…")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let asrReady = await MainActor.run { self.asrEngine.initialize() }
            let ttsReady = await MainActor.run { self.ttsEngine.initialize() }

            await MainActor.run {
                self.state.enginesReady = asrReady && ttsReady
                self.state.voiceState = (asrReady && ttsReady)
                    ? .idle
                    : .error("模型加载失败，请检查模型文件")
            }

            // Store cleanup closure captured on main actor for deinit
            await MainActor.run { [weak self] in
                self?.engineCleanup = { [asr = self?.asrEngine, tts = self?.ttsEngine] in
                    asr?.destroy()
                    tts?.destroy()
                }
            }
        }
    }

    func checkConfig() -> Bool {
        let hasConfig = configRepo.hasConfig
        state.hasConfig = hasConfig
        if hasConfig, case .error(let msg) = state.voiceState, msg.contains("配置 API") {
            state.voiceState = .idle
        }
        return hasConfig
    }

    // MARK: - Recording

    func startListening() {
        guard state.enginesReady else {
            state.voiceState = .error("模型未就绪，请先上传模型文件")
            return
        }

        AudioSessionManager.configure()

        os_log(.info, "MainVM: start listening")
        state.voiceState = .listening
        state.partialAsrText = ""
        state.finalAsrText = ""

        recordingCancellable = audioRecorder.startRecordingPublisher()
            .sink { [weak self] samples in
                guard let self = self else { return }
                self.asrEngine.acceptWaveform(samples)
                let partial = self.asrEngine.getPendingText()
                if partial.isNotBlank {
                    self.state.partialAsrText = partial
                }
            }
    }

    func stopListening() {
        os_log(.info, "MainVM: stop listening")
        audioRecorder.stop()
        recordingCancellable?.cancel()
        recordingCancellable = nil

        state.voiceState = .recognizing

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let text = await MainActor.run { self.asrEngine.inputFinished() }

            await MainActor.run {
                if text.isEmpty {
                    os_log(.info, "MainVM: ASR returned blank, returning to idle")
                    self.state.voiceState = .idle
                    self.state.partialAsrText = ""
                    return
                }
                self.state.finalAsrText = text
                self.state.partialAsrText = ""
                self.state.voiceState = .thinking
            }

            // Check config
            let hasConfig = await MainActor.run { self.configRepo.hasConfig }
            if !hasConfig {
                await MainActor.run {
                    self.state.voiceState = .error("请先在设置中配置 API 信息")
                }
                return
            }

            // Stream LLM response
            os_log(.info, "MainVM: sending to LLM, text='%@'", text)
            await self.streamLLMResponse(text)
        }
    }

    func cancelListening() {
        os_log(.info, "MainVM: cancel listening")
        audioRecorder.stop()
        recordingCancellable?.cancel()
        recordingCancellable = nil
        state.voiceState = .idle
        state.partialAsrText = ""
    }

    // MARK: - LLM Streaming

    private func streamLLMResponse(_ text: String) async {
        let streamPublisher = chatSession.sendStream(text)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var fullReply = ""
            var hasCompleted = false

            streamingCancellable = streamPublisher
                .flatMap { $0 }  // unwrap inner publisher
                .sink(
                    receiveCompletion: { [weak self] completion in
                        guard !hasCompleted else { return }
                        hasCompleted = true

                        Task { @MainActor in
                            if case .failure(let error) = completion {
                                os_log(.error, "MainVM: LLM failed: %{public}@",
                                       error.localizedDescription)
                                self?.state.voiceState = .error(
                                    "请求失败: \(error.localizedDescription)"
                                )
                            } else {
                                self?.chatSession.appendAssistantReply(fullReply)
                                self?.state.assistantReply = fullReply
                                self?.speakText(fullReply)
                            }
                        }
                        continuation.resume()
                    },
                    receiveValue: { [weak self] token in
                        fullReply += token
                        Task { @MainActor in
                            self?.state.assistantReply = fullReply
                        }
                    }
                )
        }

        streamingCancellable = nil
    }

    // MARK: - TTS + Playback

    func speakText(_ text: String) {
        speakingTask?.cancel()
        audioPlayer.stop()

        state.voiceState = .speaking

        speakingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            let sentences = TextNormalizer.splitSentences(text)
            os_log(.info, "MainVM: %d sentences to speak", sentences.count)
            let sr = Double(self.ttsEngine.sampleRate)

            for sentence in sentences {
                if Task.isCancelled { break }

                let normalized = TextNormalizer.normalize(sentence)
                guard normalized.isNotBlank else { continue }

                os_log(.info, "MainVM: synthesizing '%{public}@'", String(normalized.prefix(40)))

                if let pcm = await Task.detached(priority: .userInitiated, operation: {
                    await self.ttsEngine.synthesize(text: normalized)
                }).value {
                    // Play and wait for completion
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        self.audioPlayer.play(pcmFloats: pcm, sampleRate: sr) {
                            cont.resume()
                        }
                    }

                    // Brief pause between sentences
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            self.state.voiceState = .idle
            os_log(.info, "MainVM: speaking complete")
        }
    }

    func stopSpeaking() {
        speakingTask?.cancel()
        audioPlayer.stop()
        state.voiceState = .idle
    }

    // MARK: - Helpers

    func clearError() {
        state.voiceState = .idle
    }

    func clearHistory() {
        chatSession.clear()
        state.assistantReply = ""
        state.partialAsrText = ""
        state.finalAsrText = ""
    }

    deinit {
        audioRecorder.stop()
        audioPlayer.stop()
        engineCleanup?()
        recordingCancellable?.cancel()
        streamingCancellable?.cancel()
        speakingTask?.cancel()
    }
}
