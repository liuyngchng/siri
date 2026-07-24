package com.rd.siri.rag

import android.util.Log

/**
 * 混合检索器：向量语义检索 + BM25 关键词检索 → RRF 融合排序。
 *
 * @param vectorStore   本地向量存储（需预加载 vectors.bin）
 * @param keywordSearcher BM25 关键词检索器（需预加载 bm25_index.json）
 * @param embedClient   在线 embedding API 客户端（查询时调用）
 */
class HybridSearcher(
    private val vectorStore: VectorStore,
    private val keywordSearcher: KeywordSearcher,
    private val embedClient: EmbeddingClient
) {

    companion object {
        private const val TAG = "SiriApp"
        private const val RRF_K = 60
    }

    /** 混合检索结果 — 与 VectorStore.SearchResult 格式对齐，多了 score 来源标记 */
    data class HybridResult(
        val file: String,
        val title: String,
        val content: String,
        val score: Float,        // RRF fused score (higher = better)
        val vectorScore: Float? = null,
        val keywordScore: Float? = null
    )

    /**
     * 执行混合检索。
     * 1. 调用 Embedding API 获取查询向量
     * 2. VectorStore 余弦搜索 (topK=10，给 RRF 足够的候选)
     * 3. KeywordSearcher BM25 搜索 (topK=10)
     * 4. RRF 融合排序，返回 topK 结果
     */
    suspend fun search(query: String, topK: Int = 3): List<HybridResult> {
        // 向量检索
        val queryVec = embedClient.embed(query)
        val vectorResults = if (queryVec != null) {
            vectorStore.search(queryVec, topK = 10)
        } else {
            Log.w(TAG, "HybridSearcher: embedding failed, falling back to keyword only")
            emptyList()
        }

        // 关键词检索
        val keywordResults = keywordSearcher.search(query, topK = 10)

        Log.d(TAG, "HybridSearcher: vector=${vectorResults.size} results, keyword=${keywordResults.size} results")

        if (vectorResults.isEmpty() && keywordResults.isEmpty()) return emptyList()

        // RRF 融合
        val rrfScores = mutableMapOf<Int, Double>()     // doc_idx -> RRF score
        val vectorScoreMap = mutableMapOf<Int, Float>()  // for debug/logging
        val keywordScoreMap = mutableMapOf<Int, Float>()

        // 向量结果贡献 RRF score（rank 从 1 开始）
        for ((rank, result) in vectorResults.withIndex()) {
            val docIdx = result.docIndex
            if (docIdx < 0) continue
            rrfScores[docIdx] = rrfScores.getOrDefault(docIdx, 0.0) + 1.0 / (RRF_K + rank + 1)
            vectorScoreMap[docIdx] = result.score
        }

        // 关键词结果贡献 RRF score
        for ((rank, result) in keywordResults.withIndex()) {
            val docIdx = result.docIndex
            rrfScores[docIdx] = rrfScores.getOrDefault(docIdx, 0.0) + 1.0 / (RRF_K + rank + 1)
            keywordScoreMap[docIdx] = result.score
        }

        // 按 RRF 分数降序取 topK
        return rrfScores.entries
            .sortedByDescending { it.value }
            .take(topK)
            .mapNotNull { (docIdx, rrf) ->
                val meta = vectorStore.metadataOrNull(docIdx) ?: return@mapNotNull null
                HybridResult(
                    file = meta.file,
                    title = meta.title,
                    content = meta.content,
                    score = rrf.toFloat(),
                    vectorScore = vectorScoreMap[docIdx],
                    keywordScore = keywordScoreMap[docIdx]
                )
            }
    }
}
