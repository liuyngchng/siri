# Siri - 安卓离线语音助手

基于 **sherpa-onnx** 离线引擎 + 用户自助配置大模型 API 的安卓智能语音助手。

## 工作流程

说话 → sherpa-onnx ASR（离线） → 用户配置的大模型 API → sherpa-onnx TTS（离线） → 播报

## 项目结构

```
siri/
├── app/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── java/com/rd/siri/
│       │   ├── MainActivity.kt
│       │   ├── SiriApp.kt
│       │   ├── audio/            # 录音 / 播放 / 前台服务
│       │   │   ├── AudioRecorder.kt
│       │   │   ├── AudioPlayer.kt
│       │   │   └── VoiceService.kt
│       │   ├── asr/
│       │   │   └── SherpaAsrEngine.kt    # sherpa-onnx ASR 封装（离线 SenseVoice）
│       │   ├── tts/
│       │   │   └── SherpaTtsEngine.kt    # sherpa-onnx TTS 封装（离线 Matcha-TTS）
│       │   ├── chat/
│       │   │   ├── ChatSession.kt        # 对话管理
│       │   │   └── LlmClient.kt          # LLM API 客户端（动态配置）
│       │   ├── config/
│       │   │   ├── LlmConfig.kt
│       │   │   ├── ConfigRepository.kt   # EncryptedSharedPreferences 加密存储
│       │   │   └── ConfigViewModel.kt
│       │   ├── model/
│       │   │   ├── AppState.kt
│       │   │   ├── ChatMessage.kt
│       │   │   └── ModelManager.kt       # 模型文件检查与 tar 解压
│       │   └── ui/
│       │       ├── MainScreen.kt         # 主界面
│       │       ├── MainViewModel.kt
│       │       ├── SettingsScreen.kt     # 大模型配置界面
│       │       ├── ModelSetupScreen.kt   # 模型文件上传界面
│       │       └── theme/
│       ├── cpp/                          # JNI 桥接 C 源码
│       │   ├── CMakeLists.txt
│       │   ├── sherpa_onnx_jni.c
│       │   └── include/sherpa-onnx/c-api/
│       └── jniLibs/                      # sherpa-onnx 预编译 .so
│           ├── arm64-v8a/
│           │   ├── libsherpa-onnx-c-api.so
│           │   └── libonnxruntime.so
│           └── armeabi-v7a/
│               ├── libsherpa-onnx-c-api.so
│               └── libonnxruntime.so
├── download-models.sh                    # 模型下载脚本
├── DOC.md
└── README.md
```

## 快速开始

### 1. 构建 APK

```bash
./gradlew assembleDebug
```

原生库（jniLibs 下的 .so + CMake 编译的 JNI 桥接）会自动打包进 APK。

### 2. 准备模型文件

模型文件不打包进 APK（体积 ~370MB），而是在 app 内从手机上传。

```bash
# 用下载脚本获取模型（下载到本地，不会自动集成到 APK）
chmod +x download-models.sh
./download-models.sh
```

脚本会自动解压 `.tar.bz2` → `.tar`。将得到的三个文件传到手机上：
- `sherpa-onnx-sense-voice-...tar`（ASR）
- `matcha-icefall-zh-baker.tar`（TTS）
- `vocos-22khz-univ.onnx`（Vocoder）

### 3. 安装运行

```bash
adb install app/build/outputs/apk/debug/app-arm64-v8a-debug.apk
```

首次启动会显示**模型设置界面**，依次选择 ASR 的 `.tar`、TTS 的 `.tar`，以及 vocoder 的 `.onnx` 文件。App 会自动解压到私有存储目录，解压完成后点"开始使用"进入主界面。

## 模型文件说明

### ASR - 语音识别

SenseVoiceSmall int8 量化版（~158 MB 压缩），解压后包含：
- `model.int8.onnx` — 识别模型
- `tokens.txt` — 词表

### TTS - 语音合成

Matcha-TTS 中文版（~88 MB 压缩）+ vocos 声码器（~52 MB），解压后包含：
- `model.onnx` — 声学模型（tar 内为 `model-steps-3.onnx`，自动重命名）
- `vocos.onnx` — 声码器（单独上传 `vocos-22khz-univ.onnx`，自动重命名）
- `tokens.txt` — 词表
- `lexicon.txt` — 词典

## 大模型配置

App 内置设置界面，用户自行填写三项信息：

| 配置项 | 示例值 | 说明 |
|--------|--------|------|
| API 地址 | `https://api.deepseek.com/v1` | 兼容 OpenAI `/v1/chat/completions` 接口 |
| 模型名称 | `deepseek-chat` | 模型 ID |
| API Key | `sk-xxx...` | 用户自己的密钥 |

支持 DeepSeek / OpenAI / Ollama / vLLM / 硅基流动 等所有兼容接口。

## 系统要求

- Android 12 (API 31) 或更高
- arm64-v8a 或 armeabi-v7a 架构
- 麦克风权限
- 存储空间 ~400MB（解压后的模型文件）
