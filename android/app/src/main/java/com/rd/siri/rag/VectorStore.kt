package com.rd.siri.rag

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 本地轻量向量存储 + 余弦相似度搜索。
 *
 * 从 assets/rag/ 加载预处理好的 chunks.json（元数据）和 vectors.bin（float32 向量矩阵）。
 * 向量已由 embedding API 归一化，余弦相似度 = 点积。
 */
class VectorStore(context: Context, assetPath: String = "rag") {

    companion object {
        private const val TAG = "SiriApp"
    }

    data class SearchResult(
        val file: String,
        val title: String,
        val content: String,
        val score: Float,
        val docIndex: Int = -1
    )

    data class Stats(
        val numChunks: Int,
        val dim: Int,
        val loaded: Boolean = false
    )

    private var vectors: FloatArray = floatArrayOf()  // flattened: [v0_dim0, v0_dim1, ..., v1_dim0, ...]
    private var metadata: List<ChunkMeta> = emptyList()
    private var dim: Int = 0

    var stats: Stats = Stats(0, 0)
        private set

    data class ChunkMeta(val file: String, val title: String, val content: String)

    /** 根据文档索引获取元数据 */
    fun metadataOrNull(docIndex: Int): ChunkMeta? =
        metadata.getOrNull(docIndex)

    /** 通过 SearchResult 获取文档索引（HybridSearcher RRF 融合用） */
    fun docIndexOf(result: SearchResult): Int = result.docIndex

    /** 加载 assets/rag/chunks.json + vectors.bin。若向量文件不存在则返回 false。 */
    suspend fun load(): Boolean = withContext(Dispatchers.IO) {
        try {
            val ctx = context.applicationContext
            val chunksPath = "$assetPath/chunks.json"
            val vectorsPath = "$assetPath/vectors.bin"

            // 检查向量文件是否存在
            val assetsList = ctx.assets.list(assetPath) ?: emptyArray()
            if (!assetsList.contains("vectors.bin")) {
                Log.w(TAG, "VectorStore: vectors.bin not found in assets/$assetPath/, RAG disabled")
                return@withContext false
            }

            // 加载元数据
            val jsonStr = ctx.assets.open(chunksPath).bufferedReader().use { it.readText() }
            val arr = JSONArray(jsonStr)
            val metaList = mutableListOf<ChunkMeta>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                metaList.add(
                    ChunkMeta(
                        file = obj.getString("file"),
                        title = obj.getString("title"),
                        content = obj.getString("content")
                    )
                )
            }
            metadata = metaList

            // 加载向量
            val inputStream = ctx.assets.open(vectorsPath)
            val dataStream = DataInputStream(inputStream)
            val numVectors = dataStream.readInt()  // little-endian? DataInputStream is big-endian!
            val dimRaw = dataStream.readInt()

            // vectors.bin is written as little-endian <ii; read manually
            dataStream.close()
            inputStream.close()

            // Re-read with correct byte order
            val bytes = ctx.assets.open(vectorsPath).readBytes()
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val numVectorsLE = buf.int
            val dimLE = buf.int
            dim = dimLE

            if (numVectorsLE != metadata.size) {
                Log.w(TAG, "VectorStore: vector count ($numVectorsLE) != metadata count (${metadata.size})")
            }

            val totalFloats = numVectorsLE * dimLE
            vectors = FloatArray(totalFloats)
            for (i in 0 until totalFloats) {
                vectors[i] = buf.float
            }

            stats = Stats(numVectorsLE, dimLE, loaded = true)
            Log.i(TAG, "VectorStore: loaded ${numVectorsLE} vectors, dim=$dimLE, " +
                    "${"%.1f".format(bytes.size / 1024.0)} KB")

            true
        } catch (e: Exception) {
            Log.e(TAG, "VectorStore: failed to load assets", e)
            false
        }
    }

    /**
     * 余弦相似度搜索（向量已归一化，点积 = 余弦相似度）。
     * 返回 topK 个结果，按相似度降序排列。
     */
    fun search(queryVector: FloatArray, topK: Int = 3): List<SearchResult> {
        if (vectors.isEmpty() || queryVector.size != dim) {
            Log.w(TAG, "VectorStore: search failed — not loaded or dim mismatch (query=${queryVector.size}, store=$dim)")
            return emptyList()
        }

        val n = metadata.size
        // 计算每个向量的点积
        val scores = FloatArray(n)
        for (i in 0 until n) {
            var dot = 0f
            val offset = i * dim
            for (j in 0 until dim) {
                dot += vectors[offset + j] * queryVector[j]
            }
            scores[i] = dot
        }

        // 找 topK（部分排序或全排序；n 通常 < 5000，全排足够快）
        val indices = scores.indices.sortedByDescending { scores[it] }.take(topK)

        return indices.map { idx ->
            val meta = metadata[idx]
            SearchResult(
                file = meta.file,
                title = meta.title,
                content = meta.content,
                score = scores[idx],
                docIndex = idx
            )
        }
    }
}
