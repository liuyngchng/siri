//
//  RagSearchView.swift
//  SiriApp
//
//  RAG knowledge base search debug view.
//  Allows testing retrieval quality independently from LLM chat.
//

import SwiftUI

struct RagSearchView: View {
    @StateObject private var viewModel: RagSearchViewModel

    init(hybridSearcher: HybridSearcher, vectorStore: VectorStore, keywordSearcher: KeywordSearcher) {
        _viewModel = StateObject(wrappedValue: RagSearchViewModel(
            hybridSearcher: hybridSearcher,
            vectorStore: vectorStore,
            keywordSearcher: keywordSearcher
        ))
    }

    var body: some View {
        List {
            // MARK: - Search field
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("输入检索关键词…", text: $viewModel.queryText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !viewModel.queryText.isEmpty {
                        Button(action: { viewModel.queryText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // MARK: - Results or empty state
            if viewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("检索中…")
                        Spacer()
                    }
                    .padding(.vertical, 32)
                }
            } else if !viewModel.results.isEmpty {
                Section(header: Text("检索结果 (\(viewModel.results.count))")) {
                    ForEach(viewModel.results) { item in
                        resultCard(item)
                    }
                }
            } else if !viewModel.statusMessage.isEmpty {
                Section {
                    Text(viewModel.statusMessage)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                }
            }

            // MARK: - Footer: RAG status
            Section {
                // intentionally empty — footer below
            } footer: {
                HStack {
                    Circle()
                        .fill(viewModel.isRagReady ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(viewModel.ragStats)
                        .font(.caption2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("知识库检索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("搜索") {
                    Task { await viewModel.search() }
                }
                .disabled(viewModel.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || viewModel.isLoading)
            }
        }
    }

    // MARK: - Result Card

    private func resultCard(_ item: RagSearchViewModel.RagSearchResultItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title & rank
            HStack(alignment: .firstTextBaseline) {
                Text("#\(item.rank)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
            }

            // Scores
            HStack(spacing: 12) {
                Text(String(format: "RRF %.4f", item.rrfScore))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let vs = item.vectorScore {
                    scoreBadge(label: "向量", score: vs)
                }
                if let ks = item.keywordScore {
                    scoreBadge(label: "BM25", score: ks)
                }
            }

            // Content preview
            Text(item.content)
                .font(.caption)
                .lineLimit(6)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(6)

            // Source file
            Text(item.file)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func scoreBadge(label: String, score: Float) -> some View {
        Text("\(label) \(String(format: "%.4f", score))")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}
