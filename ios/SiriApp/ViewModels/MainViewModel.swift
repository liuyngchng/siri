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

    // Wake word
    private let wakeWordEngine = WakeWordEngine()
    private let wakeWordManager = WakeWordManager.shared
    private var wakeWordTriggered = false
    private var multiTurnActive = false
    private var multiTurnRound = 0
    private let maxMultiTurnRounds = 8
    private var lastWakeTime: Date = .distantPast
    private var resumeCancellable: AnyCancellable?
    private var wakeEventCancellable: AnyCancellable?
    private var wakeRunningCancellable: AnyCancellable?

    private var recordingCancellable: AnyCancellable?
    private var streamingCancellable: AnyCancellable?
    private var streamingContinuation: CheckedContinuation<Void, Never>?
    private var speakingTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var vadTask: Task<Void, Never>?
    private var engineCleanup: (() -> Void)?

    /// Latest audio RMS energy, updated by the recording sink.
    /// Read by the multi-turn VAD for speech/silence detection.
    private var latestRms: Float = 0

    init() {
        documentsDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]

        // Observe chat messages
        chatSession.$messages
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)

        // Observe wake word running state
        wakeRunningCancellable = wakeWordManager.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.state.wakeWordEnabled = running
            }

        // Observe wake word events
        wakeEventCancellable = wakeWordManager.wakeEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.onWakeWordDetected()
            }

        // Observe resume signal
        resumeCancellable = wakeWordManager.resumeSignal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.onResumeKws()
            }

        // Check KWS model readiness
        state.kwsReady = ModelManager.checkKwsReady()

        // Audio interruption handling
        AudioSessionManager.startObservingInterruptions()
        AudioSessionManager.onInterruptionBegan = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                os_log(.info, "MainVM: handling audio interruption began")
                // Cancel any active voice flow
                self.multiTurnActive = false
                self.multiTurnRound = 0
                self.wakeWordTriggered = false
                self.vadTask?.cancel()
                self.vadTask = nil
                self.audioRecorder.stop()
                self.recordingCancellable?.cancel()
                self.recordingCancellable = nil
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
                self.streamingCancellable?.cancel()
                self.streamingCancellable = nil
                self.streamingContinuation?.resume()
                self.streamingContinuation = nil
                self.speakingTask?.cancel()
                self.speakingTask = nil
                self.audioPlayer.stop()
                self.wakeWordEngine.stop()
                self.wakeWordManager.setRunning(false)
                self.state.voiceState = .idle
                self.state.partialAsrText = ""
            }
        }
        AudioSessionManager.onInterruptionEnded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                os_log(.info, "MainVM: handling audio interruption ended")
                // Resume KWS if it was enabled before the interruption
                if self.state.wakeWordEnabled {
                    self.onResumeKws()
                }
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

    // MARK: - Wake Word

    func isWakeWordEnabled() -> Bool { state.wakeWordEnabled }

    func toggleWakeWord(_ enable: Bool) {
        if enable {
            startWakeWordDetection()
        } else {
            stopWakeWordDetection()
        }
    }

    private func startWakeWordDetection() {
        // Check KWS model availability
        state.kwsReady = ModelManager.checkKwsReady()
        guard state.kwsReady else {
            state.voiceState = .error("唤醒模型未下载，请在模型管理界面下载")
            return
        }

        let modelDir = ModelManager.kwsModelDirURL()

        if !wakeWordEngine.isReady {
            guard wakeWordEngine.initialize(modelDir: modelDir) else {
                state.voiceState = .error("唤醒引擎初始化失败")
                return
            }
        }

        // KWS needs its own audio session
        AudioSessionManager.configureForKws()

        wakeWordEngine.start(
            onDetected: { [weak self] keyword in
                Task { @MainActor in
                    self?.onKwsDetected(keyword)
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    self?.onKwsError(message)
                }
            }
        )

        wakeWordManager.setRunning(true)
        os_log(.info, "MainVM: wake word detection started")
    }

    private func stopWakeWordDetection() {
        wakeWordEngine.stop()
        wakeWordManager.setRunning(false)
        os_log(.info, "MainVM: wake word detection stopped")
    }

    private func onKwsDetected(_ keyword: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastWakeTime)
        let debounce = wakeWordManager.currentDebounceSec

        if elapsed < debounce {
            os_log(.info, "MainVM: wake word debounced (%.1fs < %.1fs)", elapsed, debounce)
            return
        }
        lastWakeTime = now

        os_log(.info, "MainVM: wake word '%{public}@' detected — pausing KWS engine", keyword)

        // Pause KWS engine and then start the voice flow.
        // stop() busy-waits for the detection thread to finish, which can take
        // up to ~100ms. Run it on a background thread so we don't block the UI,
        // and only proceed with the voice flow AFTER the KWS engine has fully
        // released the microphone.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            // Block the background thread (not main) while KWS winds down
            await MainActor.run { self.wakeWordEngine.stop() }

            // Now safe to start voice flow — microphone is free
            await MainActor.run { [weak self] in
                guard let self = self else { return }

                // Check engine readiness
                guard self.state.enginesReady else {
                    os_log(.info, "MainVM: wake word detected but engines not ready — restarting KWS")
                    self.state.voiceState = .error("模型未就绪，请在模型管理界面下载模型")
                    self.onResumeKws()
                    return
                }

                // Notify manager — starts the voice flow
                self.wakeWordManager.notifyWakeWord()
            }
        }
    }

    private func onKwsError(_ message: String) {
        os_log(.error, "MainVM: KWS engine error: %{public}@", message)
        wakeWordManager.setRunning(false)

        // Attempt recovery after a short delay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self, self.state.wakeWordEnabled else { return }
            self.startWakeWordDetection()
        }
    }

    /// Called when wake word event fires — start the voice flow.
    private func onWakeWordDetected() {
        os_log(.info, "MainVM: wake word event received!")

        guard case .idle = state.voiceState, state.enginesReady else {
            os_log(.info, "MainVM: ignoring wake word — state is not idle")
            return
        }

        wakeWordTriggered = true
        multiTurnActive = true
        multiTurnRound = 0

        // TTS "哎，我在呢" then auto-start listening
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.state.voiceState = .speaking

            // Switch from KWS voiceChat mode to default playback mode for full volume
            AudioSessionManager.configure()

            if let pcm = await Task.detached(priority: .userInitiated, operation: {
                await self.ttsEngine.synthesize(text: "哎，我在呢", speed: 1.0)
            }).value {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let sr = Double(self.ttsEngine.sampleRate)
                    self.audioPlayer.play(pcmFloats: pcm, sampleRate: sr) {
                        cont.resume()
                    }
                }
                // Release player engine before starting AudioRecorder
                self.audioPlayer.stop()
            }

            self.startListening()
        }
    }

    /// Called when the voice flow completes and KWS should resume.
    private func onResumeKws() {
        guard state.wakeWordEnabled else { return }
        os_log(.info, "MainVM: resuming KWS detection")

        // Reset audio session for KWS
        AudioSessionManager.configureForKws()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !self.wakeWordEngine.isReady {
                let modelDir = ModelManager.kwsModelDirURL()
                guard self.wakeWordEngine.initialize(modelDir: modelDir) else {
                    os_log(.error, "MainVM: KWS re-init failed")
                    return
                }
            }
            self.wakeWordEngine.start(
                onDetected: { [weak self] keyword in
                    Task { @MainActor in
                        self?.onKwsDetected(keyword)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.onKwsError(message)
                    }
                }
            )
            self.wakeWordManager.setRunning(true)
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

        // Reset energy tracker for VAD
        latestRms = 0

        recordingCancellable = audioRecorder.startRecordingPublisher()
            .sink { [weak self] samples in
                guard let self = self else { return }
                self.asrEngine.acceptWaveform(samples)
                let partial = self.asrEngine.getPendingText()
                if partial.isNotBlank {
                    self.state.partialAsrText = partial
                }
                // Track energy for VAD
                self.latestRms = Self.rms(samples)
            }

        // VAD-based auto-stop when multi-turn mode is active (wake-word triggered)
        if multiTurnActive {
            startVadAutoStop()
        }
    }

    // MARK: - VAD Auto-Stop (multi-turn)

    private func startVadAutoStop() {
        vadTask?.cancel()
        vadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            let maxPeakWaitSec: Double = 5.0   // TTS done → wait 5s then exit multi-turn
            let silenceThresholdSec: Double = 1.5
            let energyThreshold: Float = 0.01
            let energyHighNeeded = 5   // 5 × 200ms = 1s sustained energy
            let pollInterval: UInt64 = 200_000_000  // 200ms

            var speechDetected = false
            var silenceStart: Date?
            var energyHighCount = 0
            let startTime = Date()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollInterval)

                let s = self.state
                if case .listening = s.voiceState {} else { break }

                let rms = self.latestRms
                let hasPartial = s.partialAsrText.isNotBlank

                // Speech detection: ASR partial text is definitive.
                // Energy alone requires sustained signal to filter out transient noise.
                if hasPartial {
                    speechDetected = true
                    silenceStart = nil
                    energyHighCount = 0
                } else if !speechDetected && rms > energyThreshold {
                    energyHighCount += 1
                    if energyHighCount >= energyHighNeeded {
                        speechDetected = true
                    }
                } else if !speechDetected {
                    energyHighCount = 0
                }

                // Silence after speech detected → auto-stop
                if speechDetected && rms <= energyThreshold && !hasPartial {
                    if silenceStart == nil {
                        silenceStart = Date()
                    } else if Date().timeIntervalSince(silenceStart!) >= silenceThresholdSec {
                        os_log(.info, "MainVM: VAD silence for %.1fs, auto-stopping", silenceThresholdSec)
                        self.stopListening()
                        break
                    }
                } else if speechDetected {
                    silenceStart = nil
                }

                // No speech detected at all → timeout
                if !speechDetected && Date().timeIntervalSince(startTime) >= maxPeakWaitSec {
                    os_log(.info, "MainVM: VAD no speech for %.0fs, auto-stopping", maxPeakWaitSec)
                    self.stopListening()
                    break
                }
            }
        }
    }

    /// Compute RMS energy of a float sample buffer.
    private static func rms(_ samples: [Float]) -> Float {
        var sum: Double = 0
        for s in samples {
            sum += Double(s) * Double(s)
        }
        return Float(sqrt(sum / Double(samples.count)))
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

            // Early return if ASR produced no text — must be at Task level,
            // NOT inside MainActor.run, or it only exits the inner closure.
            if text.isEmpty {
                await MainActor.run {
                    os_log(.info, "MainVM: ASR returned blank, returning to idle")
                    if self.wakeWordTriggered {
                        self.wakeWordManager.notifyFalseTrigger()
                    }
                    self.multiTurnActive = false
                    self.multiTurnRound = 0
                    self.state.voiceState = .idle
                    self.state.partialAsrText = ""
                }
                // Signal that voice flow is done so KWS can resume
                if await MainActor.run(body: { self.wakeWordTriggered }) {
                    await MainActor.run {
                        self.wakeWordTriggered = false
                        self.wakeWordManager.notifyVoiceFlowDone()
                    }
                }
                return
            }

            // Productive wake — reset adaptive debounce
            await MainActor.run {
                if self.wakeWordTriggered {
                    self.wakeWordManager.notifyProductiveWake()
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
        os_log(.info, "MainVM: cancel all active operations")
        // User-initiated cancel is NOT a false trigger — don't penalise debounce.
        multiTurnActive = false
        multiTurnRound = 0
        let wasWakeTriggered = wakeWordTriggered
        wakeWordTriggered = false

        vadTask?.cancel()
        vadTask = nil
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
        state.voiceState = .idle
        state.partialAsrText = ""

        // Resume KWS if was wake-word-triggered
        if wasWakeTriggered {
            wakeWordManager.notifyVoiceFlowDone()
        }
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
        streamingContinuation = nil
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
                self.finishSpeakingOrMultiTurn()
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
            // or WakeWordEngine when the next audio operation starts.
            self.audioPlayer.stop()

            self.finishSpeakingOrMultiTurn()
        }
    }

    /// Handle state after TTS playback completes: either next multi-turn round or resume KWS.
    private func finishSpeakingOrMultiTurn() {
        if multiTurnActive && multiTurnRound < maxMultiTurnRounds {
            multiTurnRound += 1
            os_log(.info, "MainVM: multi-turn round %d/%d — auto-starting listening",
                   multiTurnRound, maxMultiTurnRounds)
            startListening()
        } else {
            if multiTurnRound >= maxMultiTurnRounds {
                os_log(.info, "MainVM: multi-turn max rounds reached, exiting")
                multiTurnActive = false
            }
            state.voiceState = .idle
            os_log(.info, "MainVM: speaking complete")
            if wakeWordTriggered {
                wakeWordTriggered = false
                wakeWordManager.notifyVoiceFlowDone()
            }
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
        wakeWordEngine.destroy()
        engineCleanup?()
        recordingCancellable?.cancel()
        streamingCancellable?.cancel()
        speakingTask?.cancel()
        recognitionTask?.cancel()
        wakeEventCancellable?.cancel()
        resumeCancellable?.cancel()
        wakeRunningCancellable?.cancel()
        vadTask?.cancel()
    }
}
