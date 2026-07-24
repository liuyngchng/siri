//
//  RagSearchViewModel.swift
//  SiriApp
//
//  ViewModel for the RAG knowledge base search debug view.
//

import Foundation
import Combine

@MainActor
class RagSearchViewModel: ObservableObject {
    @Published var queryText: String = ""
    @Published var results: [RagSearchResultItem] = []
    @Published var isLoading: Bool = false
    @Published var statusMessage: String = ""

    private let hybridSearcher: HybridSearcher
    let vectorStore: VectorStore
    let keywordSearcher: KeywordSearcher

    struct RagSearchResultItem: Identifiable {
        let id = UUID()
        let rank: Int
        let title: String
        let content: String
        let file: String
        let rrfScore: Float
        let vectorScore: Float?
        let keywordScore: Float?
    }

    init(hybridSearcher: HybridSearcher, vectorStore: VectorStore, keywordSearcher: KeywordSearcher) {
        self.hybridSearcher = hybridSearcher
        self.vectorStore = vectorStore
        self.keywordSearcher = keywordSearcher
    }

    var isRagReady: Bool {
        vectorStore.stats.loaded && keywordSearcher.loaded
    }

    var ragStats: String {
        let vs = vectorStore.stats
        let ksLoaded = keywordSearcher.loaded
        if vs.loaded && ksLoaded {
            return "已加载 \(vs.numChunks) 个文本块，维度 \(vs.dim)"
        } else {
            return "知识库未就绪（终端资源文件未打包）"
        }
    }

    func search() async {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请输入检索关键词"
            return
        }
        guard isRagReady else {
            statusMessage = "知识库未加载，请确认 RagAssets 已添加到 Xcode 项目"
            return
        }

        isLoading = true
        statusMessage = "检索中…"
        results = []

        let hybridResults = await hybridSearcher.search(query: trimmed, topK: 5)

        results = hybridResults.enumerated().map { (idx, r) in
            RagSearchResultItem(
                rank: idx + 1,
                title: r.title,
                content: r.content,
                file: r.file,
                rrfScore: r.score,
                vectorScore: r.vectorScore,
                keywordScore: r.keywordScore
            )
        }

        isLoading = false
        if results.isEmpty {
            statusMessage = "未找到匹配的知识库条目"
        } else {
            statusMessage = "找到 \(results.count) 条结果"
        }
    }
}
