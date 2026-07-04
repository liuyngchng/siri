//
//  ModelSetupScreen.swift
//  SiriApp
//
//  First-launch screen: download or import model files.
//  Three slots: ASR (tar), TTS (tar), Vocoder (onnx).
//  User can tap all 3 — operations queue and run sequentially.
//  iOS 14 native style: List + InsetGroupedListStyle
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

private let pickerLog = Logger(subsystem: "com.siri.app", category: "FilePicker")

// MARK: - Model File Picker

private struct ModelFilePicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let onPick: (URL, @escaping () -> Void) -> Void
    let onError: ((String) -> Void)?

    init(allowedContentTypes: [UTType], onPick: @escaping (URL, @escaping () -> Void) -> Void, onError: ((String) -> Void)? = nil) {
        self.allowedContentTypes = allowedContentTypes
        self.onPick = onPick
        self.onError = onError
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: false — dismiss immediately and let us handle the copy in the
        // background so large SMB files don't hang the picker with no progress.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiView: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onError: onError)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL, @escaping () -> Void) -> Void
        let onError: ((String) -> Void)?
        init(onPick: @escaping (URL, @escaping () -> Void) -> Void, onError: ((String) -> Void)?) {
            self.onPick = onPick; self.onError = onError
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            pickerLog.info("didPickDocuments: count=\(urls.count)")
            guard let url = urls.first else {
                pickerLog.error("Empty URL array from document picker")
                onError?("无法读取所选文件。"); return
            }
            pickerLog.debug("Selected URL: \(url.absoluteString)")
            pickerLog.debug("Path: \(url.path), isFileURL: \(url.isFileURL)")

            // Check file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                pickerLog.info("File size: \(size) bytes (\(size / 1024 / 1024) MB)")
            } else {
                pickerLog.warning("Cannot read file attributes for \(url.path) — file may be on remote volume")
            }

            let secured = url.startAccessingSecurityScopedResource()
            pickerLog.debug("startAccessingSecurityScopedResource → \(secured)")
            if !secured {
                pickerLog.error("Security-scoped access denied for \(url.path)")
                onError?("无法访问所选文件。请在文件 App 中将该文件复制到'我的 iPhone'，再重新导入。"); return
            }
            onPick(url) { url.stopAccessingSecurityScopedResource() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            pickerLog.info("Document picker cancelled by user")
        }
    }
}

// MARK: - Sheet Target

enum ModelSheetTarget: Identifiable {
    case asr, tts, vocoder
    var id: Int {
        switch self {
        case .asr: return 0
        case .tts: return 1
        case .vocoder: return 2
        }
    }
}

// MARK: - Screen

struct ModelSetupScreen: View {
    let onReady: () -> Void

    @StateObject private var modelManager = ModelManager()

    @State private var sheetTarget: ModelSheetTarget? = nil
    @State private var errorMessage: String? = nil

    /// Derived from modelManager state — always reflects current reality,
    /// avoids the @State + onChange sync gap that can miss updates.
    private var asrOk: Bool {
        if case .completed = modelManager.asrState { return true }
        return ModelManager.checkAsrReady()
    }
    private var ttsTarOk: Bool {
        if case .completed = modelManager.ttsState { return true }
        return ModelManager.checkTtsExtracted()
    }
    private var vocoderOk: Bool {
        if case .completed = modelManager.vocoderState { return true }
        return ModelManager.checkVocoderReady()
    }

    private var ttsOk: Bool { ttsTarOk && vocoderOk }
    private var allReady: Bool { asrOk && ttsOk }

    private var anyProcessing: Bool {
        if case .queued = modelManager.asrState { return true }
        if case .downloading = modelManager.asrState { return true }
        if case .importing = modelManager.asrState { return true }
        if case .extracting = modelManager.asrState { return true }
        if case .queued = modelManager.ttsState { return true }
        if case .downloading = modelManager.ttsState { return true }
        if case .importing = modelManager.ttsState { return true }
        if case .extracting = modelManager.ttsState { return true }
        if case .queued = modelManager.vocoderState { return true }
        if case .downloading = modelManager.vocoderState { return true }
        if case .importing = modelManager.vocoderState { return true }
        if case .extracting = modelManager.vocoderState { return true }
        return false
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0.3, green: 0.69, blue: 0.31))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("sherpa-onnx 引擎")
                            Text("已内置于 App")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("ASR 模型")) {
                    slotRow(label: "SenseVoice", subtitle: "语音识别 · int8 量化",
                            isReady: asrOk, state: modelManager.asrState,
                            onDownload: { modelManager.downloadAsrModel() },
                            onImport: { sheetTarget = .asr })
                }

                Section(header: Text("TTS 模型")) {
                    slotRow(label: "Matcha-icefall", subtitle: "语音合成 · 中文",
                            isReady: ttsTarOk, state: modelManager.ttsState,
                            onDownload: { modelManager.downloadTtsModel() },
                            onImport: { sheetTarget = .tts })
                }

                Section(header: Text("Vocoder")) {
                    slotRow(label: "Vocos", subtitle: "22kHz · ONNX 格式",
                            isReady: vocoderOk, state: modelManager.vocoderState,
                            onDownload: { modelManager.downloadVocoder() },
                            onImport: { sheetTarget = .vocoder })
                }

                Section(footer: Text("模型文件较大，建议在 Wi-Fi 环境下下载。也可通过文件 App 导入已下载的模型文件。")) {
                    EmptyView()
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("模型设置")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("下一步", action: onReady)
                        .disabled(!allReady || anyProcessing)
                }
            }
            .sheet(item: $sheetTarget) { makeFilePicker(for: $0) }
            .alert(isPresented: Binding<Bool>(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Alert(title: Text("导入失败"), message: Text(errorMessage ?? ""), dismissButton: .default(Text("好")))
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Slot Row

    @ViewBuilder
    private func slotRow(
        label: String, subtitle: String,
        isReady: Bool, state: ModelDownloadState,
        onDownload: @escaping () -> Void,
        onImport: @escaping () -> Void
    ) -> some View {
        if isReady {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(red: 0.3, green: 0.69, blue: 0.31)).font(.body)
                Text(label)
                Spacer()
                Text("已就绪").font(.caption).foregroundColor(.secondary)
            }
        } else {
            slotNotReadyRow(label: label, subtitle: subtitle, state: state,
                            onDownload: onDownload, onImport: onImport)
        }
    }

    @ViewBuilder
    private func slotNotReadyRow(
        label: String, subtitle: String, state: ModelDownloadState,
        onDownload: @escaping () -> Void,
        onImport: @escaping () -> Void
    ) -> some View {
        switch state {
        case .queued:
            HStack {
                Image(systemName: "clock").foregroundColor(.orange).font(.body)
                Text(label)
                Spacer()
                Text("排队中...").font(.caption).foregroundColor(.orange)
            }

        case .downloading(let p):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("下载中...").font(.subheadline)
                    Spacer()
                    Text("\(Int(p * 100))%")
                        .font(.system(.caption, design: .monospaced)).foregroundColor(.blue)
                }
                ProgressView(value: max(p, 0.05)).progressViewStyle(LinearProgressViewStyle())
            }

        case .importing:
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("导入中...").font(.subheadline)
                Spacer()
            }

        case .extracting(let p):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text("解压中...").font(.subheadline)
                    Spacer()
                    Text("\(Int(p * 100))%")
                        .font(.system(.caption, design: .monospaced)).foregroundColor(.blue)
                }
                ProgressView(value: max(p, 0.05)).progressViewStyle(LinearProgressViewStyle())
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(label).font(.body)
                    Spacer()
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Text(msg).font(.caption).foregroundColor(.red)
                Divider()
                HStack(spacing: 12) {
                    Button(action: onDownload) { Label("重新下载", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderless).font(.subheadline)
                    Spacer()
                    Button(action: onImport) { Label("重新上传", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderless).font(.subheadline)
                }
            }

        default:
            // idle or completed-but-not-verified: show action buttons
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(label).font(.body)
                    Spacer()
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Divider()
                HStack(spacing: 12) {
                    Button(action: onDownload) { Label("下载", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderless).font(.subheadline)
                    Spacer()
                    Button(action: onImport) { Label("上传", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderless).font(.subheadline)
                }
            }
        }
    }

    // MARK: - File Picker

    @ViewBuilder
    private func makeFilePicker(for target: ModelSheetTarget) -> some View {
        switch target {
        case .asr, .tts:
            ModelFilePicker(
                allowedContentTypes: [
                    UTType(tag: "bz2", tagClass: .filenameExtension, conformingTo: .data) ?? .data,
                    UTType(tag: "tar", tagClass: .filenameExtension, conformingTo: .data) ?? .data,
                    UTType(tag: "tar.bz2", tagClass: .filenameExtension, conformingTo: .data) ?? .data,
                ],
                onPick: { url, cleanup in
                    pickerLog.info("ASR/TTS import picked: \(url.lastPathComponent)")
                    switch target {
                    case .asr:
                        pickerLog.info("→ importAsrModel")
                        modelManager.importAsrModel(from: url, cleanup: cleanup)
                    case .tts:
                        pickerLog.info("→ importTtsModel")
                        modelManager.importTtsModel(from: url, cleanup: cleanup)
                    default: break
                    }
                    sheetTarget = nil
                },
                onError: { errorMessage = $0 }
            )
        case .vocoder:
            ModelFilePicker(
                allowedContentTypes: [
                    UTType(tag: "onnx", tagClass: .filenameExtension, conformingTo: .data) ?? .item,
                ],
                onPick: { url, cleanup in
                    pickerLog.info("Vocoder import picked: \(url.lastPathComponent)")
                    pickerLog.info("→ importVocoder")
                    modelManager.importVocoder(from: url, cleanup: cleanup)
                    sheetTarget = nil
                },
                onError: { errorMessage = $0 }
            )
        }
    }
}
