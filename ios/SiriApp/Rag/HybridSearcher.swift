//
//  HybridSearcher.swift
//  SiriApp
//
//  混合检索器：向量语义检索 + BM25 关键词检索 → RRF 融合排序。
//
//  Ported from Android: HybridSearcher.kt
//

import Foundation
import Combine
import os.log

class HybridSearcher {

    private let log = OSLog(subsystem: "dev.richard.voicechat", category: "HybridSearcher")

    private let vectorStore: VectorStore
    private let keywordSearcher: KeywordSearcher
    private let embedClient: EmbeddingClient

    private static let rrfK: Double = 60

    /// 混合检索结果
    struct HybridResult {
        let file: String
        let title: String
        let content: String
        let score: Float          // RRF fused score (higher = better)
        let vectorScore: Float?
        let keywordScore: Float?
    }

    init(vectorStore: VectorStore, keywordSearcher: KeywordSearcher, embedClient: EmbeddingClient) {
        self.vectorStore = vectorStore
        self.keywordSearcher = keywordSearcher
        self.embedClient = embedClient
    }

    // MARK: - Search

    /// 执行混合检索。
    /// 1. 调用 Embedding API 获取查询向量
    /// 2. VectorStore 余弦搜索 (topK=10，给 RRF 足够的候选)
    /// 3. KeywordSearcher BM25 搜索 (topK=10)
    /// 4. RRF 融合排序，返回 topK 结果
    func search(query: String, topK: Int = 3) async -> [HybridResult] {
        // 向量检索
        var vectorResults: [VectorStore.SearchResult] = []
        if #available(iOS 15.0, *) {
            if let queryVec = await embedClient.embed(query) {
                vectorResults = vectorStore.search(queryVector: queryVec, topK: 10)
            } else {
                os_log(.error, log: log, "HybridSearcher: embedding failed, falling back to keyword only")
            }
        } else {
            // iOS 14: use Combine-based embedding
            let queryVec: [Float]? = await withCheckedContinuation { continuation in
                var cancellable: AnyCancellable?
                cancellable = embedClient.embedPublisher(query).sink { vec in
                    continuation.resume(returning: vec)
                    _ = cancellable  // retain
                }
            }
            if let vec = queryVec {
                vectorResults = vectorStore.search(queryVector: vec, topK: 10)
            }
        }

        // 关键词检索
        let keywordResults = keywordSearcher.search(query: query, topK: 10)

        os_log(.debug, log: log,
               "HybridSearcher: vector=%{public}d results, keyword=%{public}d results",
               vectorResults.count, keywordResults.count)

        if vectorResults.isEmpty && keywordResults.isEmpty {
            return []
        }

        // RRF 融合
        var rrfScores: [Int: Double] = [:]         // doc_idx -> RRF score
        var vectorScoreMap: [Int: Float] = [:]
        var keywordScoreMap: [Int: Float] = [:]

        // 向量结果贡献 RRF score (rank 从 1 开始)
        for (rank, result) in vectorResults.enumerated() {
            let docIdx = result.docIndex
            guard docIdx >= 0 else { continue }
            rrfScores[docIdx] = (rrfScores[docIdx] ?? 0) + 1.0 / (Self.rrfK + Double(rank) + 1)
            vectorScoreMap[docIdx] = result.score
        }

        // 关键词结果贡献 RRF score
        for (rank, result) in keywordResults.enumerated() {
            let docIdx = result.docIndex
            rrfScores[docIdx] = (rrfScores[docIdx] ?? 0) + 1.0 / (Self.rrfK + Double(rank) + 1)
            keywordScoreMap[docIdx] = result.score
        }

        // 按 RRF 分数降序取 topK
        return rrfScores
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .compactMap { (docIdx, rrf) -> HybridResult? in
                guard let meta = vectorStore.metadataOrNull(docIndex: docIdx) else { return nil }
                return HybridResult(
                    file: meta.file,
                    title: meta.title,
                    content: meta.content,
                    score: Float(rrf),
                    vectorScore: vectorScoreMap[docIdx],
                    keywordScore: keywordScoreMap[docIdx]
                )
            }
    }
}
