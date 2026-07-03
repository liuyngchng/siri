//
//  SettingsScreen.swift
//  SiriApp
//
//  LLM API configuration form with presets.
//  Ported from Android: SettingsScreen.kt
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // API URL
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API 地址").font(.caption).foregroundColor(.secondary)
                        TextField("https://api.deepseek.com/v1", text: $apiUrl)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: apiUrl) { _ in viewModel.resetTestResult() }
                        Text("兼容 OpenAI chat/completions 接口")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Model name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模型名称").font(.caption).foregroundColor(.secondary)
                        TextField("deepseek-v4-flash", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: model) { _ in viewModel.resetTestResult() }
                        Text("如 deepseek-v4-flash, gpt-4o-mini, qwen-plus 等")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // API Key
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key").font(.caption).foregroundColor(.secondary)
                        HStack {
                            if showKey {
                                TextField("sk-...", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("sk-...", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(action: { showKey.toggle() }) {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: apiKey) { _ in viewModel.resetTestResult() }
                        Text("密钥将加密存储在设备本地")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Quick presets
                    Text("快捷预设")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LlmPreset.all) { preset in
                                Button(action: {
                                    apiUrl = preset.apiUrl
                                    model = preset.model
                                    viewModel.resetTestResult()
                                }) {
                                    Text(preset.name)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(.systemGray5))
                                        .cornerRadius(16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Test result
                    switch viewModel.testResult {
                    case .testing:
                        ProgressView("正在测试连接...")
                            .font(.caption)
                    case .success(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.green)
                    case .failure(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.red)
                    case .idle:
                        EmptyView()
                    }

                    Spacer(minLength: 24)

                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: {
                            viewModel.clearConfig()
                            apiUrl = ""
                            model = ""
                            apiKey = ""
                        }) {
                            Text("清空")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BorderedButtonStyle())

                        Button(action: {
                            viewModel.testConnection(apiUrl, model, apiKey)
                        }) {
                            Text("测试连接")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BorderedButtonStyle())

                        Button(action: {
                            viewModel.saveConfig(apiUrl, model, apiKey)
                        }) {
                            Text("保存")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BorderedProminentButtonStyle())
                    }
                }
                .padding(16)
            }
            .navigationTitle("大模型配置")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        HStack {
                            Image(systemName: "chevron.left")
                            Text("返回")
                        }
                    }
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
