//
//  KeywordSearcher.swift
//  SiriApp
//
//  BM25 关键词检索器。
//  从 Bundle 加载预构建的 bm25_index.json，执行纯本地 BM25 打分。
//
//  Ported from Android: KeywordSearcher.kt
//

import Foundation
import os.log

class KeywordSearcher {

    private let log = OSLog(subsystem: "dev.richard.voicechat", category: "KeywordSearcher")

    struct KeywordResult {
        let docIndex: Int
        let score: Float
    }

    // MARK: - BM25 Index Data

    private var numDocs: Int = 0
    private var avgdl: Double = 0.0
    private var k1: Double = 1.2
    private var b: Double = 0.75
    private var docLengths: [Int] = []

    /// term -> PostingList (flat array: [doc_idx, tf, doc_idx, tf, ...])
    private var termIndex: [String: PostingList] = [:]

    private(set) var loaded: Bool = false

    private struct PostingList {
        let idf: Double
        let postings: [Int]  // flat: [doc_idx, tf, ...]; df = count / 2
    }

    // MARK: - Asset Loading

    /// 从 Bundle 加载 bm25_index.json
    func load() -> Bool {
        let bm25URL = Bundle.main.url(forResource: "bm25_index", withExtension: "json", subdirectory: "rag")
            ?? Bundle.main.url(forResource: "bm25_index", withExtension: "json")

        guard let url = bm25URL else {
            os_log(.error, log: log, "KeywordSearcher: bm25_index.json not found, BM25 disabled")
            return false
        }

        do {
            let jsonData = try Data(contentsOf: url)
            let obj = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

            numDocs = obj["num_docs"] as! Int
            avgdl = obj["avgdl"] as! Double
            k1 = (obj["k1"] as? Double) ?? 1.2
            b = (obj["b"] as? Double) ?? 0.75

            let dlArr = obj["doc_lengths"] as! [Int]
            docLengths = dlArr

            let termsObj = obj["terms"] as! [String: [[Int]]]
            var totalPostingEntries = 0
            for (term, postingArr) in termsObj {
                let df = postingArr.count
                let idf = computeIDF(N: numDocs, df: df)
                var postings: [Int] = []
                postings.reserveCapacity(df * 2)
                for pair in postingArr {
                    postings.append(pair[0])   // doc_idx
                    postings.append(pair[1])   // tf
                    totalPostingEntries += 1
                }
                termIndex[term] = PostingList(idf: idf, postings: postings)
            }

            loaded = true
            os_log(.info, log: log,
                   "KeywordSearcher: loaded %{public}d terms, %{public}d posting entries, avgdl=%.2f",
                   termIndex.count, totalPostingEntries, avgdl)
            return true
        } catch {
            os_log(.error, log: log, "KeywordSearcher: failed to load: %{public}@",
                   error.localizedDescription)
            return false
        }
    }

    // MARK: - BM25 Scoring

    /// BM25 IDF: ln((N - df + 0.5) / (df + 0.5) + 1.0)
    private func computeIDF(N: Int, df: Int) -> Double {
        return Darwin.log(((Double(N) - Double(df) + 0.5) / (Double(df) + 0.5)) + 1.0)
    }

    /// 对查询进行分词 + BM25 打分，返回所有命中文档的分数，按分数降序排列。
    func search(query: String, topK: Int = 3) -> [KeywordResult] {
        guard loaded else { return [] }

        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var docScores: [Int: Float] = [:]

        for term in queryTokens {
            guard let posting = termIndex[term] else { continue }
            let idf = posting.idf
            let postings = posting.postings
            var p = 0
            while p < postings.count {
                let docIdx = postings[p]
                let tf = postings[p + 1]
                let dl = docIdx < docLengths.count ? Double(docLengths[docIdx]) : avgdl

                // BM25 TF component
                let tfScore = (Double(tf) * (k1 + 1.0)) / (Double(tf) + k1 * (1.0 - b + b * dl / avgdl))
                let score = Float(idf * tfScore)

                docScores[docIdx] = (docScores[docIdx] ?? 0) + score
                p += 2
            }
        }

        return docScores
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .map { KeywordResult(docIndex: $0.key, score: $0.value) }
    }

    // MARK: - Tokenization (mirrors Python tokenize() and Android Kotlin)

    private func tokenize(_ text: String) -> [String] {
        var unigrams: [String] = []
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace {
                i = text.index(after: i)
                continue
            }
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                var word = ""
                while i < text.endIndex,
                      let c = text[i] as Character?,
                      c.isASCII && (c.isLetter || c.isNumber) {
                    word.append(c.lowercased())
                    i = text.index(after: i)
                }
                unigrams.append(word)
            } else if isCJK(ch) {
                unigrams.append(String(ch))
                i = text.index(after: i)
            } else {
                // Punctuation etc.
                i = text.index(after: i)
            }
        }

        // Add bigrams
        var tokens: [String] = []
        tokens.append(contentsOf: unigrams)
        for j in 0..<(unigrams.count > 1 ? unigrams.count - 1 : 0) {
            tokens.append(unigrams[j] + unigrams[j + 1])
        }
        return tokens
    }

    /// Check if character is in CJK Unified Ideographs or Extension-A range
    private func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }
}
