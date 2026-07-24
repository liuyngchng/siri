package com.rd.siri.rag

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import kotlin.math.ln

/**
 * BM25 关键词检索器。
 * 从 assets 加载预构建的 bm25_index.json，在 Android 端执行纯本地 BM25 打分。
 */
class KeywordSearcher(private val context: Context, private val assetPath: String = "rag") {

    companion object {
        private const val TAG = "SiriApp"
    }

    data class KeywordResult(
        val docIndex: Int,
        val score: Float
    )

    private var numDocs: Int = 0
    private var avgdl: Double = 0.0
    private var k1: Double = 1.2
    private var b: Double = 0.75
    private var docLengths: IntArray = IntArray(0)

    // term -> list of [doc_idx, tf] pairs; use flat int array for compact storage
    private var termIndex: MutableMap<String, PostingList> = mutableMapOf()

    var loaded: Boolean = false
        private set

    /**
     * Posting list stored as flat int array: [doc_idx, tf, doc_idx, tf, ...]
     * df = size / 2
     */
    private class PostingList(val idfs: Double, val postings: IntArray)

    suspend fun load(): Boolean = withContext(Dispatchers.IO) {
        try {
            val ctx = context.applicationContext
            val assetsList = ctx.assets.list(assetPath) ?: emptyArray()
            if (!assetsList.contains("bm25_index.json")) {
                Log.w(TAG, "KeywordSearcher: bm25_index.json not found, BM25 disabled")
                return@withContext false
            }

            val jsonStr: String = ctx.assets.open("$assetPath/bm25_index.json")
                .bufferedReader().use { it.readText() }
            val obj = JSONObject(jsonStr)

            numDocs = obj.getInt("num_docs")
            avgdl = obj.getDouble("avgdl")
            k1 = obj.optDouble("k1", 1.2)
            b = obj.optDouble("b", 0.75)

            val dlArr = obj.getJSONArray("doc_lengths")
            docLengths = IntArray(dlArr.length())
            for (i in 0 until dlArr.length()) {
                docLengths[i] = dlArr.getInt(i)
            }

            val termsObj = obj.getJSONObject("terms")
            // Pre-compute IDF for each term
            val keys = termsObj.keys()
            var totalPostingEntries = 0
            while (keys.hasNext()) {
                val term = keys.next()
                val postingArr = termsObj.getJSONArray(term)
                val df = postingArr.length()
                val idf = computeIDF(numDocs, df)
                val postings = IntArray(df * 2)
                for (i in 0 until df) {
                    val pair = postingArr.getJSONArray(i)
                    postings[i * 2] = pair.getInt(0)       // doc_idx
                    postings[i * 2 + 1] = pair.getInt(1)    // tf
                    totalPostingEntries++
                }
                termIndex[term] = PostingList(idf, postings)
            }

            loaded = true
            Log.i(TAG, "KeywordSearcher: loaded ${termIndex.size} terms, " +
                    "$totalPostingEntries posting entries, avgdl=$avgdl")
            true
        } catch (e: Exception) {
            Log.e(TAG, "KeywordSearcher: failed to load", e)
            false
        }
    }

    /** BM25 IDF */
    private fun computeIDF(N: Int, df: Int): Double =
        ln(((N - df + 0.5) / (df + 0.5)) + 1.0)

    /**
     * 对查询进行分词 + BM25 打分，返回所有命中文档的分数，按分数降序排列。
     */
    fun search(query: String, topK: Int = 3): List<KeywordResult> {
        if (!loaded) return emptyList()

        val queryTokens = tokenize(query)
        if (queryTokens.isEmpty()) return emptyList()

        // Accumulate scores in a map: doc_idx -> score
        val docScores = mutableMapOf<Int, Float>()

        for (term in queryTokens) {
            val posting = termIndex[term] ?: continue
            val idf = posting.idfs
            val postings = posting.postings
            var p = 0
            while (p < postings.size) {
                val docIdx = postings[p]
                val tf = postings[p + 1]
                val dl = if (docIdx < docLengths.size) docLengths[docIdx].toDouble() else avgdl

                // BM25 TF component
                val tfScore = (tf * (k1 + 1.0)) / (tf + k1 * (1.0 - b + b * dl / avgdl))
                val score = idf * tfScore

                docScores[docIdx] = docScores.getOrDefault(docIdx, 0f) + score.toFloat()
                p += 2
            }
        }

        return docScores.entries
            .sortedByDescending { it.value }
            .take(topK)
            .map { KeywordResult(it.key, it.value) }
    }

    // ---- Tokenization (mirrors Python tokenize()) ----

    private fun tokenize(text: String): List<String> {
        val unigrams = mutableListOf<String>()
        var i = 0
        while (i < text.length) {
            val ch = text[i]
            if (ch.isWhitespace()) {
                i++
                continue
            }
            if (ch.isAsciiLetterOrDigit()) {
                val sb = StringBuilder()
                while (i < text.length && text[i].isAsciiLetterOrDigit()) {
                    sb.append(text[i].lowercaseChar())
                    i++
                }
                unigrams.add(sb.toString())
            } else if (ch in '一'..'鿿' || ch in '㐀'..'䶿') {
                // CJK Unified / Extension-A
                unigrams.add(ch.toString())
                i++
            } else {
                i++  // punctuation etc.
            }
        }

        // Add bigrams
        val tokens = mutableListOf<String>()
        tokens.addAll(unigrams)
        for (j in 0 until unigrams.size - 1) {
            tokens.add(unigrams[j] + unigrams[j + 1])
        }
        return tokens
    }

    private fun Char.isAsciiLetterOrDigit(): Boolean =
        this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
}
