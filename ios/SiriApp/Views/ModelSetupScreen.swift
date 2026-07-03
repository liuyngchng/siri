//
//  ModelSetupScreen.swift
//  SiriApp
//
//  First-launch screen: download or upload model files.
//  Three slots: ASR (tar), TTS (tar), Vocoder (onnx).
//  Ported from Android: ModelSetupScreen.kt
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

struct ModelSetupScreen: View {
    let onReady: () -> Void

    @State private var asrOk: Bool = ModelManager.checkAsrReady()
    @State private var ttsTarOk: Bool = ModelManager.checkTtsExtracted()
    @State private var vocoderOk: Bool = ModelManager.checkVocoderReady()

    @State private var asrSlot = SlotState()
    @State private var ttsSlot = SlotState()
    @State private var vocoderSlot = SlotState()

    @State private var showAsrPicker = false
    @State private var showTtsPicker = false
    @State private var showVocoderPicker = false

    @State private var cancellables = Set<AnyCancellable>()  // placeholder for Combine

    private var anyExtracting: Bool {
        asrSlot.extracting || ttsSlot.extracting || vocoderSlot.extracting
    }

    private var ttsOk: Bool { ttsTarOk && vocoderOk }
    private var allReady: Bool { asrOk && ttsOk }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("首次使用需下载/上传模型文件")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    // Native lib status
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0.3, green: 0.69, blue: 0.31))
                            .font(.title3)
                        VStack(alignment: .leading) {
                            Text("sherpa-onnx 引擎")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("已内置于 App")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // ASR slot
                    ModelSlotCard(
                        label: "ASR 模型",
                        isReady: asrOk,
                        slot: asrSlot,
                        onSelect: { showAsrPicker = true },
                        onDownload: { downloadAsr() }
                    )

                    // TTS slot
                    ModelSlotCard(
                        label: "TTS 模型",
                        isReady: ttsTarOk,
                        slot: ttsSlot,
                        onSelect: { showTtsPicker = true },
                        onDownload: { downloadTts() }
                    )

                    // Vocoder slot
                    ModelSlotCard(
                        label: "Vocoder",
                        isReady: vocoderOk,
                        slot: vocoderSlot,
                        onSelect: { showVocoderPicker = true },
                        onDownload: { downloadVocoder() }
                    )

                    Spacer(minLength: 24)

                    // Start button
                    Button(action: onReady) {
                        Text("下一步")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .disabled(!allReady || anyExtracting)
                }
                .padding(16)
            }
            .navigationTitle("模型设置")
            // File pickers
            .fileImporter(
                isPresented: $showAsrPicker,
                allowedContentTypes: [.archive, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result, slot: .asr)
            }
            .fileImporter(
                isPresented: $showTtsPicker,
                allowedContentTypes: [.archive, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result, slot: .tts)
            }
            .fileImporter(
                isPresented: $showVocoderPicker,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result, slot: .vocoder)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - File Import Handling

    private enum SlotType { case asr, tts, vocoder }

    private func handleFileImport(result: Result<[URL], Error>, slot: SlotType) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            switch slot {
            case .asr:
                asrSlot = SlotState(extracting: true)
                let cancellable = ModelManager.extractTarFile(
                    sourceURL: url,
                    destSubDir: ModelManager.asrModelDir,
                    progress: { p in
                        DispatchQueue.main.async {
                            asrSlot = SlotState(extracting: true, progress: p)
                        }
                    }
                )
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            DispatchQueue.main.async {
                                asrSlot = SlotState(error: "解压失败: \(error.localizedDescription)")
                            }
                        }
                    },
                    receiveValue: {
                        DispatchQueue.main.async {
                            asrOk = ModelManager.checkAsrReady()
                            asrSlot = SlotState()
                        }
                    }
                )
                // Keep cancellable alive
                _ = cancellable

            case .tts:
                ttsSlot = SlotState(extracting: true)
                let cancellable = ModelManager.extractTarFile(
                    sourceURL: url,
                    destSubDir: ModelManager.ttsModelDir,
                    progress: { p in
                        DispatchQueue.main.async {
                            ttsSlot = SlotState(extracting: true, progress: p)
                        }
                    }
                )
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            DispatchQueue.main.async {
                                ttsSlot = SlotState(error: "解压失败: \(error.localizedDescription)")
                            }
                        }
                    },
                    receiveValue: {
                        DispatchQueue.main.async {
                            ttsTarOk = ModelManager.checkTtsExtracted()
                            ttsSlot = SlotState()
                        }
                    }
                )
                _ = cancellable

            case .vocoder:
                vocoderSlot = SlotState(extracting: true)
                let cancellable = ModelManager.copyVocoderFile(
                    sourceURL: url,
                    progress: { p in
                        DispatchQueue.main.async {
                            vocoderSlot = SlotState(extracting: true, progress: p)
                        }
                    }
                )
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            DispatchQueue.main.async {
                                vocoderSlot = SlotState(error: "复制失败: \(error.localizedDescription)")
                            }
                        }
                    },
                    receiveValue: {
                        DispatchQueue.main.async {
                            vocoderOk = ModelManager.checkVocoderReady()
                            vocoderSlot = SlotState()
                        }
                    }
                )
                _ = cancellable
            }

        case .failure(let error):
            let errorSlot = SlotState(error: "选择文件失败: \(error.localizedDescription)")
            switch slot {
            case .asr: asrSlot = errorSlot
            case .tts: ttsSlot = errorSlot
            case .vocoder: vocoderSlot = errorSlot
            }
        }
    }

    // MARK: - Download Handlers

    private func downloadAsr() {
        asrSlot = SlotState(extracting: true)
        let cancellable = ModelManager.downloadAndExtractAsr { p in
            DispatchQueue.main.async {
                asrSlot = SlotState(extracting: true, progress: p)
            }
        }
        .sink(
            receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    DispatchQueue.main.async {
                        asrSlot = SlotState(error: "下载失败: \(error.localizedDescription)")
                    }
                }
            },
            receiveValue: {
                DispatchQueue.main.async {
                    asrOk = ModelManager.checkAsrReady()
                    asrSlot = SlotState()
                }
            }
        )
        _ = cancellable
    }

    private func downloadTts() {
        ttsSlot = SlotState(extracting: true)
        let cancellable = ModelManager.downloadAndExtractTts { p in
            DispatchQueue.main.async {
                ttsSlot = SlotState(extracting: true, progress: p)
            }
        }
        .sink(
            receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    DispatchQueue.main.async {
                        ttsSlot = SlotState(error: "下载失败: \(error.localizedDescription)")
                    }
                }
            },
            receiveValue: {
                DispatchQueue.main.async {
                    ttsTarOk = ModelManager.checkTtsExtracted()
                    ttsSlot = SlotState()
                }
            }
        )
        _ = cancellable
    }

    private func downloadVocoder() {
        vocoderSlot = SlotState(extracting: true)
        let cancellable = ModelManager.downloadVocoder { p in
            DispatchQueue.main.async {
                vocoderSlot = SlotState(extracting: true, progress: p)
            }
        }
        .sink(
            receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    DispatchQueue.main.async {
                        vocoderSlot = SlotState(error: "下载失败: \(error.localizedDescription)")
                    }
                }
            },
            receiveValue: {
                DispatchQueue.main.async {
                    vocoderOk = ModelManager.checkVocoderReady()
                    vocoderSlot = SlotState()
                }
            }
        )
        _ = cancellable
    }
}
