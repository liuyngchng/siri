# Siri - 离线语音助手（Android + iOS）

基于 **sherpa-onnx** 离线引擎 + 用户自助配置大模型 API 的智能语音助手，支持 Android 和 iOS 双平台。

## 工作流程

说话 → sherpa-onnx ASR（离线） → 用户配置的大模型 API → sherpa-onnx TTS（离线） → 播报

## 项目结构

```
siri/
├── README.md
├── DOC.md                         # 详细设计文档
├── download-models.sh             # 模型下载脚本（两端共用）
├── app/                           # Android 端
│   ├── build.gradle.kts
│   └── src/main/
│       ├── java/com/rd/siri/
│       │   ├── audio/             # 录音 / 播放 / 前台服务
│       │   ├── asr/               # sherpa-onnx ASR 封装
│       │   ├── tts/               # sherpa-onnx TTS 封装
│       │   ├── chat/              # LLM 客户端
│       │   ├── config/            # 配置存储（EncryptedSharedPreferences）
│       │   ├── model/             # 模型管理 & 数据模型
│       │   └── ui/                # Compose 界面
│       ├── cpp/                   # JNI 桥接 C 源码
│       └── jniLibs/               # 预编译 .so（从 GitHub Releases 获取）
└── ios/                           # iOS 端
    ├── download-frameworks.sh     # Framework 下载脚本
    ├── SiriApp/
    │   ├── ASR/                   # sherpa-onnx ASR 封装（SenseVoice）
    │   ├── TTS/                   # sherpa-onnx TTS 封装（Matcha-TTS）
    │   ├── Audio/                 # 录音 / 播放 / 音频会话管理
    │   ├── Chat/                  # LLM 客户端 + 对话管理
    │   ├── Config/                # 配置存储（Keychain）
    │   ├── Helpers/               # 模型管理 / tar.bz2 解压 / Keychain
    │   ├── Models/                # 数据模型
    │   ├── ViewModels/            # MVVM ViewModel
    │   └── Views/                 # SwiftUI 界面
    ├── Frameworks/                # 预编译 xcframework（不提交 git）
    └── SiriApp.xcodeproj/
```

---

## Android

### 编译与打包概览

整个项目的文件分为三种来源，需要区分清楚：

#### 1. 预编译 .so（需提前下载，打包进 APK）

以下 .so 文件来自 [sherpa-onnx Android 预编译包](https://github.com/k2-fsa/sherpa-onnx/releases)，放在 `app/src/main/jniLibs/<abi>/` 目录下，**构建时自动打包进 APK**：

| 文件 | 大小（arm64） | 作用 |
|------|-------------|------|
| `libonnxruntime.so` | ~25 MB | ONNX Runtime 推理引擎底层库 |
| `libsherpa-onnx-c-api.so` | ~4 MB | sherpa-onnx C API 封装 |

需要覆盖 `arm64-v8a` 和 `armeabi-v7a` 两个架构。项目已内置这两个文件（提交在 git 中），**如果你 clone 了本项目则无需额外下载**。

#### 2. CMake 编译产物（构建时自动编译，打包进 APK）

以下 .so 由 CMake 在 `./gradlew assembleDebug` 时自动编译，源码在本仓库 `app/src/main/cpp/` 下：

| 文件 | 源码 | 作用 |
|------|------|------|
| `libsherpa_onnx_jni.so` | `cpp/sherpa_onnx_jni.c` | JNI 桥接层，连接 Kotlin 与 sherpa-onnx C API |

CMake 编译时链接上述预编译的 `libsherpa-onnx-c-api.so` 和 `libonnxruntime.so`。产物同样自动打包进 APK。

**编译链路**：
```
cpp/sherpa_onnx_jni.c  ──CMake编译──▶  libsherpa_onnx_jni.so
                                        │ 链接
                    libsherpa-onnx-c-api.so  (jniLibs, 预编译)
                    libonnxruntime.so        (jniLibs, 预编译)
```

**运行时加载顺序**（`SiriApp.kt`）：
```kotlin
System.loadLibrary("onnxruntime")        // 1. 推理引擎
System.loadLibrary("sherpa-onnx-c-api")  // 2. sherpa-onnx API
System.loadLibrary("sherpa_onnx_jni")    // 3. JNI 桥接
```

#### 3. 模型文件（用户从手机上传，不打包进 APK）

ASR/TTS 模型文件体积约 280MB，**不打包进 APK**。用户首次启动 App 时通过 `ModelSetupScreen` 界面从手机选择文件上传，App 自动解压到私有存储目录。

| 文件 | 大小 | 用途 |
|------|------|------|
| `sherpa-onnx-sense-voice-*.tar` | ~158 MB | ASR 语音识别模型（SenseVoiceSmall int8） |
| `matcha-icefall-zh-baker.tar` | ~72 MB | TTS 声学模型（Matcha-TTS 中文） |
| `vocos-22khz-univ.onnx` | ~51 MB | TTS 声码器（Vocos） |

使用 `download-models.sh` 一键下载这三个文件，然后传到手机上。

#### APK 打包总结

```
APK 内包含:
  ├── classes.dex              (Kotlin/Java 编译产物)
  ├── lib/arm64-v8a/
  │   ├── libonnxruntime.so        (预编译，jniLibs)
  │   ├── libsherpa-onnx-c-api.so  (预编译，jniLibs)
  │   └── libsherpa_onnx_jni.so    (CMake 编译)
  ├── lib/armeabi-v7a/
  │   └── ...（同上）
  └── res/...                  (Android 资源)

APK 不包含:
  ├── ASR 模型 (.tar)           (运行时用户上传)
  ├── TTS 模型 (.tar)           (运行时用户上传)
  └── Vocoder (.onnx)           (运行时用户上传)
```

### Android 快速开始

#### 0. 前置条件

- Android Studio 或命令行 Gradle 环境
- Android SDK 33，NDK（CMake 编译 JNI 桥接用）
- 如果 clone 了本项目，预编译的 `libonnxruntime.so` 和 `libsherpa-onnx-c-api.so` 已在 `jniLibs/` 中，无需额外下载

#### 1. 构建 APK

```bash
./gradlew assembleDebug
```

构建过程：
1. CMake 编译 `cpp/sherpa_onnx_jni.c` → `libsherpa_onnx_jni.so`（JNI 桥接）
2. Gradle 编译 Kotlin/Java 源码
3. 所有 .so（jniLibs 预编译 + CMake 编译产物）自动打包进 APK

APK 按 ABI 拆分，产物在 `app/build/outputs/apk/debug/`：
- `app-arm64-v8a-debug.apk`
- `app-armeabi-v7a-debug.apk`

#### 2. 准备模型文件

模型文件**不打包进 APK**（体积约 280MB），在 App 首次启动时从手机上传。

```bash
# 下载模型到本地
chmod +x download-models.sh
./download-models.sh
```

脚本从 GitHub Releases 下载并解压，得到三个文件。将它们传到手机上（USB / adb push / 微信文件传输等任意方式）：
- `sherpa-onnx-sense-voice-...tar`（ASR 识别模型）
- `matcha-icefall-zh-baker.tar`（TTS 声学模型）
- `vocos-22khz-univ.onnx`（TTS 声码器）

也可以跳过手动传输，直接在 App 内点击各模型 slot 的"下载"按钮，App 会自动下载并解压。

#### 3. 安装运行

```bash
adb install app/build/outputs/apk/debug/app-arm64-v8a-debug.apk
```

首次启动会显示**模型设置界面**，每个模型 slot 提供两种导入方式：
- **下载**：App 直接从 GitHub Releases 下载并自动解压
- **选择文件**：从手机本地选择已下载的模型文件上传

解压完成后点"开始使用"进入主界面。

---

## iOS

### 架构说明

iOS 端使用 **SwiftUI + sherpa-onnx C API**：

- sherpa-onnx C API 通过 **bridging header**（`SiriApp-Bridging-Header.h`）直接调用，无需 JNI 桥接层
- 预编译的 `onnxruntime.xcframework` 和 `sherpa-onnx.xcframework` 放在 `ios/Frameworks/`，**不提交到 git**
- tar.bz2 模型解压使用系统 **libbz2** + 自研 `TarBz2Extractor`（纯 Swift stream 解析）
- API Key 使用 **Keychain** 加密存储（对标 Android EncryptedSharedPreferences）

| 组件 | Android 实现 | iOS 实现 |
|------|-------------|---------|
| 推理引擎 | `libonnxruntime.so` (jniLibs) | `onnxruntime.xcframework` |
| sherpa-onnx API | `libsherpa-onnx-c-api.so` + JNI 桥接 | `sherpa-onnx.xcframework` + bridging header |
| 模型解压 | Apache Commons Compress | libbz2 + TarBz2Extractor |
| 密钥存储 | EncryptedSharedPreferences | Keychain |

### iOS 快速开始

#### 0. 前置条件

- Xcode（macOS）
- iOS 14.0+ 部署目标

#### 1. 下载 Framework

两个预编译 xcframework（约 190 MB 解压后）需要从 GitHub Releases 下载：

```bash
chmod +x ios/download-frameworks.sh
./ios/download-frameworks.sh
```

脚本会从 [sherpa-onnx Releases](https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.3/sherpa-onnx-v1.13.3-ios.tar.bz2) 下载 `sherpa-onnx-v1.13.3-ios.tar.bz2`（~42 MB），解压后自动安装到 `ios/Frameworks/`。

#### 2. 打开项目编译

用 Xcode 打开 `ios/SiriApp.xcodeproj`，选择 iOS 模拟器或真机，直接 Build & Run。

#### 3. 准备模型文件

模型文件与 Android 端完全相同，使用同一个下载脚本：

```bash
./download-models.sh
```

将得到的文件传到 iPhone 上，或直接在 App 的模型设置界面点击"下载"按钮，App 会自动从 GitHub Releases 下载并解压。

---

## 模型文件说明

### ASR - 语音识别

SenseVoiceSmall int8 量化版（~158 MB 压缩），解压后包含：
- `model.int8.onnx` — 识别模型
- `tokens.txt` — 词表

下载：[sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09.tar.bz2)

### TTS - 语音合成

Matcha-TTS 中文版（~88 MB 压缩）+ vocos 声码器（~52 MB），解压后包含：
- `model.onnx` — 声学模型（tar 内为 `model-steps-3.onnx`，自动重命名）
- `vocos.onnx` — 声码器（单独上传 `vocos-22khz-univ.onnx`，自动重命名）
- `tokens.txt` — 词表
- `lexicon.txt` — 词典

下载：[matcha-icefall-zh-baker.tar.bz2](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/matcha-icefall-zh-baker.tar.bz2)

### Vocoder - 声码器

下载：[vocos-22khz-univ.onnx](https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-22khz-univ.onnx)

---

## 大模型配置

App 内置设置界面，用户自行填写三项信息：

| 配置项 | 示例值 | 说明 |
|--------|--------|------|
| API 地址 | `https://api.deepseek.com/v1` | 兼容 OpenAI `/v1/chat/completions` 接口 |
| 模型名称 | `deepseek-chat` | 模型 ID |
| API Key | `sk-xxx...` | 用户自己的密钥 |

支持 DeepSeek / OpenAI / Ollama / vLLM / 硅基流动 等所有兼容接口。

---

## 系统要求

| 平台 | 系统版本 | 架构 |
|------|---------|------|
| Android | 12 (API 31) 或更高 | arm64-v8a / armeabi-v7a |
| iOS | 14.0 或更高 | arm64（iPhone / iPad） |

**通用要求**：麦克风权限、存储空间 ~400MB（解压后的模型文件）。
