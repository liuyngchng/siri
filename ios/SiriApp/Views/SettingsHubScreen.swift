//
//  SettingsHubScreen.swift
//  SiriApp
//
//  Settings hub: master list with NavigationLinks to sub-pages.
//  Follows the iOS Settings.app pattern.
//

import SwiftUI

struct SettingsHubScreen: View {
    @ObservedObject var configVM: ConfigViewModel
    var onDismiss: () -> Void
    var ttsEnabled: Bool = true
    var onToggleTts: ((Bool) -> Void)? = nil
    var hybridSearcher: HybridSearcher? = nil
    var vectorStore: VectorStore? = nil
    var keywordSearcher: KeywordSearcher? = nil

    /// Build-time-based version string (executable modification date).
    private var appVersion: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let modDate = attrs[.modificationDate] as? Date
        else { return "unknown" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd.HHmm"
        return fmt.string(from: modDate)
    }

    var body: some View {
        NavigationView {
            List {
                // MARK: - 配置
                Section(header: Text("配置")) {
                    NavigationLink(destination:
                        SettingsContent(viewModel: configVM, onBack: nil)
                    ) {
                        Label {
                            Text("大模型 API")
                        } icon: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.blue)
                        }
                    }

                    if let hs = hybridSearcher,
                       let vs = vectorStore,
                       let ks = keywordSearcher {
                        NavigationLink(destination:
                            RagSearchView(
                                hybridSearcher: hs,
                                vectorStore: vs,
                                keywordSearcher: ks
                            )
                        ) {
                            Label {
                                Text("知识库检索")
                            } icon: {
                                Image(systemName: "text.magnifyingglass")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                }

                // MARK: - 模型
                Section(header: Text("模型")) {
                    NavigationLink(destination:
                        ModelSetupContent(onReady: nil)
                    ) {
                        Label {
                            Text("语音模型")
                        } icon: {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                }

                // MARK: - 交互
                Section(header: Text("交互")) {
                    HStack {
                        Label {
                            Text("语音播报")
                        } icon: {
                            Image(systemName: ttsEnabled
                                  ? "speaker.wave.2.fill"
                                  : "speaker.slash.fill")
                                .foregroundColor(ttsEnabled ? .blue : .secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding<Bool>(
                            get: { ttsEnabled },
                            set: { onToggleTts?($0) }
                        ))
                        .labelsHidden()
                    }
                }

                // MARK: - 关于
                Section(header: Text("关于")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成", action: onDismiss)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
