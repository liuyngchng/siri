//
//  SettingsScreen.swift
//  SiriApp
//
//  LLM API configuration form.
//  iOS 14 native style: Form + Section
//

import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var viewModel: ConfigViewModel
    var onBack: () -> Void

    @State private var apiUrl: String = ""
    @State private var model: String = ""
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false

    var body: some View {
        NavigationView {
            Form {
                // MARK: - API 配置
                Section(header: Text("API 配置"),
                        footer: Text("兼容 OpenAI chat/completions 接口")) {
                    HStack {
                        Text("地址")
                        Spacer()
                        TextField("https://api.deepseek.com/v1", text: $apiUrl)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: apiUrl) { _ in viewModel.resetTestResult() }
                    }

                    HStack {
                        Text("模型")
                        Spacer()
                        TextField("deepseek-v4-flash", text: $model)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: model) { _ in viewModel.resetTestResult() }
                    }

                    HStack {
                        Text("密钥")
                        Spacer()
                        if showKey {
                            TextField("sk-...", text: $apiKey)
                                .multilineTextAlignment(.trailing)
                        } else {
                            SecureField("sk-...", text: $apiKey)
                                .multilineTextAlignment(.trailing)
                        }
                        Button(action: { showKey.toggle() }) {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                    }
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: apiKey) { _ in viewModel.resetTestResult() }
                }

                // MARK: - 快捷预设
                if !LlmPreset.all.isEmpty {
                    Section(header: Text("快捷预设")) {
                        ForEach(LlmPreset.all) { preset in
                            Button(action: {
                                apiUrl = preset.apiUrl
                                model = preset.model
                                viewModel.resetTestResult()
                            }) {
                                HStack {
                                    Text(preset.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(preset.model)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                // MARK: - 连接测试结果
                Section {
                    switch viewModel.testResult {
                    case .testing:
                        HStack {
                            ProgressView()
                            Text("正在测试连接...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    case .success(let msg):
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(msg)
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                    case .failure(let msg):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("连接失败")
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                            }
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .idle:
                        EmptyView()
                    }
                }

                // MARK: - 操作
                Section {
                    Button(action: {
                        viewModel.testConnection(apiUrl, model, apiKey)
                    }) {
                        Label("测试连接", systemImage: "network")
                    }
                    .disabled(apiUrl.isEmpty || apiKey.isEmpty)

                    Button(action: {
                        viewModel.clearConfig()
                        apiUrl = ""
                        model = ""
                        apiKey = ""
                    }) {
                        Label("清空配置", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("大模型配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("返回")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        viewModel.saveConfig(apiUrl, model, apiKey)
                    }
                    .disabled(apiUrl.isEmpty || apiKey.isEmpty)
                }
            }
            .onAppear {
                if let config = viewModel.config {
                    apiUrl = config.apiUrl
                    model = config.model
                    apiKey = config.apiKey
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
