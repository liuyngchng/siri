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
    private var streamingContinuation: CheckedContinuation<Void, Never>?
    private var speakingTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var engineCleanup: (() -> Void)?

    init() {
        documentsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        // Load TTS preference
        state.ttsEnabled = UserDefaults.standard.object(forKey: "tts_enabled") as? Bool ?? false

        // Observe chat messages
        chatSession.$messages
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)

        // Audio interruption handling
        AudioSessionManager.startObservingInterruptions()
        AudioSessionManager.onInterruptionBegan = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                os_log(.info, "MainVM: handling audio interruption began")
                self.cancelListening()
            }
        }
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

    // MARK: - Config

    func checkConfig() -> Bool {
        let hasConfig = configRepo.hasConfig
        state.hasConfig = hasConfig
        if hasConfig, case .error(let msg) = state.voiceState, msg.contains("配置 API") {
            state.voiceState = .idle
        }
        return hasConfig
    }

    func toggleTts(_ enable: Bool) {
        state.ttsEnabled = enable
        UserDefaults.standard.set(enable, forKey: "tts_enabled")
        if !enable {
            stopSpeaking()
        }
    }

    // MARK: - Cancel all tasks

    private func cancelAllTasks() {
        os_log(.info, "MainVM: cancelAllTasks — aborting all in-progress work")

        // Coroutine tasks
        recordingCancellable?.cancel()
        recordingCancellable = nil
        streamingCancellable?.cancel()
        streamingCancellable = nil
        streamingContinuation?.resume()
        streamingContinuation = nil
        speakingTask?.cancel()
        speakingTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        // Audio I/O
        audioRecorder.stop()
        audioPlayer.stop()

        // ASR engine buffer — discard stale samples from cancelled sessions
        asrEngine.reset()
    }

    // MARK: - Recording

    func startListening() {
        guard state.enginesReady else {
            state.voiceState = .error("模型未就绪，请先上传模型文件")
            return
        }

        // Cancel everything in flight — ASR, LLM, TTS, etc.
        cancelAllTasks()

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

        recognitionTask?.cancel()
        recognitionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            let text = await MainActor.run { self.asrEngine.inputFinished() }

            if text.isEmpty {
                await MainActor.run {
                    os_log(.info, "MainVM: ASR returned blank, returning to idle")
                    self.state.voiceState = .idle
                    self.state.partialAsrText = ""
                }
                return
            }

            await MainActor.run {
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
        os_log(.info, "MainVM: cancel all active operations")
        audioRecorder.stop()
        recordingCancellable?.cancel()
        recordingCancellable = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        streamingCancellable?.cancel()
        streamingCancellable = nil
        streamingContinuation?.resume()
        streamingContinuation = nil
        speakingTask?.cancel()
        speakingTask = nil
        audioPlayer.stop()
        asrEngine.reset()
        state.voiceState = .idle
        state.partialAsrText = ""
    }

    // MARK: - LLM Streaming

    private func streamLLMResponse(_ text: String) async {
        let streamPublisher = chatSession.sendStream(text)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.streamingContinuation = continuation
            var fullReply = ""
            var hasCompleted = false

            streamingCancellable = streamPublisher
                .flatMap { $0 }  // unwrap inner publisher
                .sink(
                    receiveCompletion: { [weak self] completion in
                        guard !hasCompleted else { return }
                        hasCompleted = true
                        self?.streamingContinuation = nil

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
                                if self?.state.ttsEnabled == true {
                                    self?.speakText(fullReply)
                                } else {
                                    self?.state.voiceState = .idle
                                }
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
        streamingContinuation = nil
    }

    // MARK: - TTS + Playback

    func speakText(_ text: String) {
        guard state.ttsEnabled else {
            state.voiceState = .idle
            return
        }
        speakingTask?.cancel()
        audioPlayer.stop()

        state.voiceState = .speaking

        speakingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            let sentences = TextNormalizer.splitSentences(text)
            os_log(.info, "MainVM: %d sentences to speak", sentences.count)
            let sr = self.ttsEngine.sampleRate

            // Synthesise each sentence on a background thread, then
            // concatenate everything into one buffer so we play once.
            // This avoids engine start/stop clicks between sentences.
            let merged: [Float] = await Task.detached(priority: .userInitiated) {
                let silenceSamples = Int(0.3 * Double(sr))  // 300ms gap
                var allSamples: [Float] = []

                for sentence in sentences {
                    if Task.isCancelled { break }
                    let normalized = TextNormalizer.normalize(sentence)
                    guard normalized.isNotBlank else { continue }

                    if let pcm = await self.ttsEngine.synthesize(text: normalized) {
                        allSamples.append(contentsOf: pcm)
                        // Insert silence gap between sentences
                        allSamples.append(contentsOf: Array(repeating: 0, count: silenceSamples))
                    }
                }

                // Fade out last ~10ms to prevent click from abrupt cutoff
                let fadeLen = min(Int(0.01 * Double(sr)), allSamples.count)
                if fadeLen > 0 {
                    for i in 0..<fadeLen {
                        let idx = allSamples.count - fadeLen + i
                        let gain = Float(fadeLen - i) / Float(fadeLen)
                        allSamples[idx] *= gain
                    }
                }

                return allSamples
            }.value

            guard !merged.isEmpty else {
                os_log(.info, "MainVM: nothing to speak (empty TTS output)")
                self.state.voiceState = .idle
                return
            }

            os_log(.info, "MainVM: playing %d samples at %d Hz", merged.count, sr)

            // Single playback of the merged buffer
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.audioPlayer.play(pcmFloats: merged, sampleRate: Double(sr)) {
                    cont.resume()
                }
            }

            // Stop the player engine so it doesn't compete with AudioRecorder
            self.audioPlayer.stop()

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
        recognitionTask?.cancel()
    }
}
