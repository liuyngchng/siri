//
//  ModelManager.swift
//  SiriApp
//
//  Model file management: check, download, extract.
//  Ported from Android: ModelManager.kt
//

import Foundation
import Combine

enum ModelManager {
    static let asrModelDir = "models/asr"
    static let ttsModelDir = "models/tts"

    private static let asrRequired = ["model.int8.onnx", "tokens.txt"]
    private static let ttsRequired = ["model.onnx", "vocos.onnx", "tokens.txt", "lexicon.txt"]

    private static let asrDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2"
    )!
    private static let ttsDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2"
    )!
    private static let vocoderDownloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx"
    )!

    // MARK: - Paths

    static func documentsDir() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func modelsDir() -> URL {
        documentsDir().appendingPathComponent("models")
    }

    static func asrModelDirURL() -> URL {
        modelsDir().appendingPathComponent(asrModelDir)
    }

    static func ttsModelDirURL() -> URL {
        modelsDir().appendingPathComponent(ttsModelDir)
    }

    // MARK: - Ready Checks

    static func checkAllReady() -> Bool {
        checkAsrReady() && checkTtsReady()
    }

    static func checkAsrReady() -> Bool {
        let dir = asrModelDirURL()
        return asrRequired.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    static func checkTtsReady() -> Bool {
        let dir = ttsModelDirURL()
        return ttsRequired.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Check if TTS tar has been extracted (at least tokens + lexicon exist)
    static func checkTtsExtracted() -> Bool {
        let dir = ttsModelDirURL()
        return ["tokens.txt", "lexicon.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    static func checkVocoderReady() -> Bool {
        FileManager.default.fileExists(
            atPath: ttsModelDirURL().appendingPathComponent("vocos.onnx").path
        )
    }

    // MARK: - File Import (from document picker)

    /// Extract tar from a local file URL (from document picker)
    static func extractTarFile(
        sourceURL: URL,
        destSubDir: String,
        progress: @escaping (Float) -> Void
    ) -> AnyPublisher<Void, Error> {
        Future { promise in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let destDir = modelsDir().appendingPathComponent(destSubDir)
                    try TarBz2Extractor.extract(
                        sourceURL: sourceURL,
                        destinationDir: destDir,
                        progress: progress
                    )
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }

    /// Copy vocoder file to TTS model directory
    static func copyVocoderFile(
        sourceURL: URL,
        progress: @escaping (Float) -> Void
    ) -> AnyPublisher<Void, Error> {
        Future { promise in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let destDir = ttsModelDirURL()
                    try FileManager.default.createDirectory(
                        at: destDir,
                        withIntermediateDirectories: true
                    )
                    let destFile = destDir.appendingPathComponent("vocos.onnx")

                    let fileData = try Data(contentsOf: sourceURL)
                    let totalSize = fileData.count

                    // Copy in chunks for progress reporting
                    let chunkSize = 65536
                    try FileManager.default.removeItemIfExists(at: destFile)
                    FileManager.default.createFile(atPath: destFile.path, contents: nil)
                    let fh = try FileHandle(forWritingTo: destFile)
                    defer { try? fh.close() }

                    for offset in stride(from: 0, to: fileData.count, by: chunkSize) {
                        let end = min(offset + chunkSize, fileData.count)
                        let chunk = fileData[offset..<end]
                        try fh.write(contentsOf: chunk)
                        progress(Float(end) / Float(totalSize))
                    }

                    try fh.close()
                    progress(1.0)
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }

    // MARK: - Download from GitHub Releases

    static func downloadAndExtractAsr(
        progress: @escaping (Float) -> Void
    ) -> AnyPublisher<Void, Error> {
        Future { promise in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("asr_model.tar.bz2")
                    try? FileManager.default.removeItemIfExists(at: tmpFile)

                    // Download
                    try downloadFile(from: asrDownloadURL, to: tmpFile) { p in
                        progress(p * 0.5)
                    }

                    // Extract
                    let destDir = asrModelDirURL()
                    try TarBz2Extractor.extract(
                        sourceURL: tmpFile,
                        destinationDir: destDir,
                        progress: { p in
                            progress(0.5 + p * 0.5)
                        }
                    )

                    try? FileManager.default.removeItemIfExists(at: tmpFile)
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }

    static func downloadAndExtractTts(
        progress: @escaping (Float) -> Void
    ) -> AnyPublisher<Void, Error> {
        Future { promise in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("tts_model.tar.bz2")
                    try? FileManager.default.removeItemIfExists(at: tmpFile)

                    // Download
                    try downloadFile(from: ttsDownloadURL, to: tmpFile) { p in
                        progress(p * 0.5)
                    }

                    // Extract
                    let destDir = ttsModelDirURL()
                    try TarBz2Extractor.extract(
                        sourceURL: tmpFile,
                        destinationDir: destDir,
                        progress: { p in
                            progress(0.5 + p * 0.5)
                        }
                    )

                    try? FileManager.default.removeItemIfExists(at: tmpFile)
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }

    static func downloadVocoder(
        progress: @escaping (Float) -> Void
    ) -> AnyPublisher<Void, Error> {
        Future { promise in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("vocos-22khz-univ.onnx")
                    try? FileManager.default.removeItemIfExists(at: tmpFile)

                    // Download
                    try downloadFile(from: vocoderDownloadURL, to: tmpFile) { p in
                        progress(p * 0.9)
                    }

                    // Copy to TTS dir
                    let destDir = ttsModelDirURL()
                    try FileManager.default.createDirectory(
                        at: destDir, withIntermediateDirectories: true
                    )
                    let destFile = destDir.appendingPathComponent("vocos.onnx")
                    try? FileManager.default.removeItemIfExists(at: destFile)
                    try FileManager.default.copyItem(at: tmpFile, to: destFile)
                    try? FileManager.default.removeItemIfExists(at: tmpFile)

                    progress(1.0)
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }.eraseToAnyPublisher()
    }

    // MARK: - Private Download

    private static func downloadFile(
        from url: URL,
        to dest: URL,
        progress: @escaping (Float) -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        let session = URLSession(configuration: .default)

        let task = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                downloadError = error
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data = data else {
                downloadError = NSError(
                    domain: "ModelManager",
                    code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    userInfo: [NSLocalizedDescriptionKey: "下载失败"]
                )
                return
            }

            do {
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let totalSize = data.count
                let chunkSize = 65536
                try? FileManager.default.removeItem(at: dest)
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                let fh = try FileHandle(forWritingTo: dest)
                defer { try? fh.close() }

                for offset in stride(from: 0, to: totalSize, by: chunkSize) {
                    let end = min(offset + chunkSize, totalSize)
                    let chunk = data[offset..<end]
                    try fh.write(contentsOf: chunk)
                    progress(Float(end) / Float(totalSize))
                }
                try fh.close()
            } catch {
                downloadError = error
            }
        }

        task.resume()
        semaphore.wait()

        if let error = downloadError {
            throw error
        }
    }
}

// MARK: - FileManager Helper

extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}
