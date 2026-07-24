//
//  VectorStore.swift
//  SiriApp
//
//  本地轻量向量存储 + 余弦相似度搜索。
//  从 Bundle 加载预处理好的 chunks.json（元数据）和 vectors.bin（float32 向量矩阵）。
//  向量已由 embedding API 归一化，余弦相似度 = 点积。
//
//  Ported from Android: VectorStore.kt
//

import Foundation
import os.log

class VectorStore {

    private let log = OSLog(subsystem: "dev.richard.voicechat", category: "VectorStore")

    struct SearchResult {
        let file: String
        let title: String
        let content: String
        let score: Float
        let docIndex: Int
    }

    struct Stats {
        let numChunks: Int
        let dim: Int
        let loaded: Bool
    }

    private var vectors: [Float] = []
    private var metadata: [ChunkMeta] = []
    private var dim: Int = 0

    private(set) var stats: Stats = Stats(numChunks: 0, dim: 0, loaded: false)

    struct ChunkMeta: Codable {
        let file: String
        let title: String
        let content: String
    }

    // MARK: - Asset Loading

    /// 从 Bundle 加载 chunks.json + vectors.bin。若向量文件不存在则返回 false。
    func load() -> Bool {
        // Try loading from "rag" subdirectory first (folder reference in Xcode)
        // then fall back to Bundle root (group reference)
        let chunksURL = Bundle.main.url(forResource: "chunks", withExtension: "json", subdirectory: "rag")
            ?? Bundle.main.url(forResource: "chunks", withExtension: "json")
        let vectorsURL = Bundle.main.url(forResource: "vectors", withExtension: "bin", subdirectory: "rag")
            ?? Bundle.main.url(forResource: "vectors", withExtension: "bin")

        guard let chunksURL = chunksURL else {
            os_log(.error, log: log, "VectorStore: chunks.json not found in Bundle")
            return false
        }
        guard let vectorsURL = vectorsURL else {
            os_log(.error, log: log, "VectorStore: vectors.bin not found in Bundle, RAG disabled")
            return false
        }

        do {
            // 加载元数据
            let jsonData = try Data(contentsOf: chunksURL)
            let decoder = JSONDecoder()
            let metaList = try decoder.decode([ChunkMeta].self, from: jsonData)
            metadata = metaList

            // 加载向量 (little-endian: <ii header + float32 data)
            let vecData = try Data(contentsOf: vectorsURL)
            let numVectors = vecData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
            let dimLE = vecData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self).littleEndian }
            dim = Int(dimLE)

            // 不一致时仍加载，但警告
            if metadata.count != numVectors {
                os_log(.error, log: log,
                       "VectorStore: vector count (%{public}d) != metadata count (%{public}d)",
                       numVectors, metadata.count)
            }

            // 读取 float32 数据
            let floatCount = Int(numVectors) * dim
            vectors = vecData.withUnsafeBytes { rawBuf -> [Float] in
                let floatPtr = rawBuf.baseAddress!.advanced(by: 8)
                    .assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
            }

            stats = Stats(numChunks: metadata.count, dim: dim, loaded: true)
            os_log(.info, log: log,
                   "VectorStore: loaded %{public}d vectors, dim=%{public}d, %.1f KB",
                   metadata.count, dim, Double(vecData.count) / 1024.0)

            return true
        } catch {
            os_log(.error, log: log, "VectorStore: failed to load assets: %{public}@",
                   error.localizedDescription)
            return false
        }
    }

    /// 根据文档索引获取元数据
    func metadataOrNull(docIndex: Int) -> ChunkMeta? {
        guard docIndex >= 0 && docIndex < metadata.count else { return nil }
        return metadata[docIndex]
    }

    // MARK: - Search

    /// 余弦相似度搜索（向量已在构建时归一化，点积 = 余弦相似度）。
    /// 返回 topK 个结果，按相似度降序排列。
    func search(queryVector: [Float], topK: Int = 3) -> [SearchResult] {
        guard !vectors.isEmpty, queryVector.count == dim else {
            os_log(.error, log: log,
                   "VectorStore: search failed — not loaded or dim mismatch (query=%{public}d, store=%{public}d)",
                   queryVector.count, dim)
            return []
        }

        let n = metadata.count
        // 计算每个向量的点积
        var scores = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var dot: Float = 0
            let offset = i * dim
            for j in 0..<dim {
                dot += vectors[offset + j] * queryVector[j]
            }
            scores[i] = dot
        }

        // 找 topK indices (全排序 — chunk 数通常 < 5000，足够快)
        let indexed = scores.enumerated().sorted { $0.element > $1.element }
        let topIndices = indexed.prefix(topK)

        return topIndices.map { (idx, score) in
            let meta = metadata[idx]
            return SearchResult(
                file: meta.file,
                title: meta.title,
                content: meta.content,
                score: score,
                docIndex: idx
            )
        }
    }
}
