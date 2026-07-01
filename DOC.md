# 安卓版 Siri 实现方案

## 一、需求概述

构建一款安卓智能语音助手，实现：
- **语音输入**：手机端离线 ASR（语音转文本）
- **智能对话**：文本提交至用户自行配置的大模型 API（兼容 OpenAI 接口）
- **语音播报**：手机端离线 TTS（文本转语音）
- **用户自助配置**：App 内提供设置界面，用户自行填写 API 地址、模型名称、API Key
- 全流程：说话 → 转为文字 → 发给用户配置的大模型 → 返回答案 → 语音播报

## 二、整体架构

```
┌────────────────────────────────────────────────────┐
│                   Android App                       │
│                                                    │
│  ┌──────────┐   ┌──────────┐   ┌──────────────┐   │
│  │ 语音录制  │   │ 音频播放  │   │  主界面 +    │   │
│  │ (AudioRec)│   │ (AudioTrk)│   │  对话历史    │   │
│  └────┬─────┘   └────▲─────┘   └──────┬───────┘   │
│       │              │                │           │
│  ┌────▼─────┐   ┌────┴─────┐         │           │
│  │ sherpa-  │   │ sherpa-  │         │           │
│  │ onnx ASR │   │ onnx TTS │         │           │
│  │ (离线)    │   │ (离线)    │         │           │
│  └────┬─────┘   └────▲─────┘         │           │
│       │              │                │           │
│       └──────┬───────┘                │           │
│              │                        │           │
│        ┌─────▼─────┐          ┌──────▼───────┐   │
│        │ 对话管理器  │          │  设置界面     │   │
│        │ (Session) │          │ (用户配置)    │   │
│        └─────┬─────┘          │ API URL      │   │
│              │                │ Model        │   │
│              │                │ API Key      │   │
│              │                └──────┬───────┘   │
│              │                       │           │
│        ┌─────▼───────┐              │           │
│        │ LLM 客户端   │◄─────────────┘           │
│        │ (动态配置)   │                          │
│        └─────┬───────┘                          │
└──────────────┼──────────────────────────────────┘
               │ HTTP POST (OpenAI 兼容协议)
               ▼
┌────────────────────────────────────────────────────┐
│          用户自行配置的大模型服务                      │
│  DeepSeek API / OpenAI API / Ollama / vLLM / ...   │
│  (任何兼容 OpenAI chat/completions 接口的服务)       │
└────────────────────────────────────────────────────┘
```

## 三、技术选型

### 3.1 语音识别（ASR）— 离线

| 方案 | 模型 | 优点 | 缺点 |
|------|------|------|------|
| **sherpa-onnx + SenseVoice** ✅ | SenseVoiceSmall | 中文效果好、延迟低、模型小（~40MB）、支持多语言 | 需要 JNI 集成 |
| Vosk | vosk-model-cn | 纯离线、多平台 | 中文识别率低于 SenseVoice |
| Whisper.cpp | tiny/medium | 通用性强 | 模型大、中文不如专用模型 |

**推荐**：**sherpa-onnx + SenseVoiceSmall**（k2-fsa 的 SenseVoice 模型专为中文优化，自带时间戳和情感识别，模型从 ModelScope 获取）

模型下载：
- SenseVoiceSmall: ModelScope `iic/SenseVoiceSmall` 或 `k2-fsa/sherpa-onnx` GitHub Releases (`asr-models` tag)
- 模型文件：`model.int8.onnx`、`tokens.txt`

### 3.2 语音合成（TTS）— 离线

| 方案 | 模型 | 优点 | 缺点 |
|------|------|------|------|
| **sherpa-onnx + Matcha-TTS** ✅ | matcha-icefall-zh | 自然度高、延迟低 | JNI 集成工作 |
| sherpa-onnx + VITS | vits-icefall-zh | 经典方案、成熟 | 质量不如 Matcha |
| MeloTTS | melo-zh | 中文支持好 | 仅 Python/ONNX 导出需额外工作 |

**推荐**：**sherpa-onnx + Matcha-TTS** 中文模型（同一框架，集成成本低）

模型下载：
- Matcha-TTS 中文: ModelScope 搜索 `matcha-tts` 或 `k2-fsa/sherpa-onnx` GitHub Releases (`tts-models` tag)
- 模型文件：`model.onnx`（acoustic model）、`vocos.onnx`（vocoder）、`tokens.txt`、`lexicon.txt`

**备选**：若 Matcha-TTS 效果不理想，可先用 sherpa-onnx 的 VITS 中文模型，成熟稳定。

### 3.3 大语言模型（LLM）— 用户自助配置

App 不做硬编码绑定，用户可在设置界面自行配置：

| 配置项 | 说明 | 示例值 |
|--------|------|--------|
| **API 地址** | 兼容 OpenAI `/v1/chat/completions` 的服务地址 | `https://api.deepseek.com/v1` |
| **模型名称** | 所调用的模型 ID | `deepseek-chat` |
| **API Key** | 用户自己的密钥 | `sk-xxx...` |

**兼容的大模型服务（任选）**：

| 服务 | 默认 API 地址 | 特点 |
|------|-------------|------|
| DeepSeek | `https://api.deepseek.com/v1` | 中文强、价格低、注册送额度 |
| OpenAI | `https://api.openai.com/v1` | GPT-4o 系列、生态最成熟 |
| Ollama (本地) | `http://192.168.x.x:11434/v1` | 完全离线、免费、需自备 GPU |
| vLLM (自建) | `http://your-server:8000/v1` | 企业级部署、高吞吐 |
| 阿里百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | 通义千问、国内合规 |
| 硅基流动 | `https://api.siliconflow.cn/v1` | 多模型聚合、国内可访问 |

**存储方案**：使用 Android **EncryptedSharedPreferences** 加密存储，Key 不出设备。

### 3.4 通信协议

- **请求**：HTTP POST（JSON），OpenAI 兼容格式
- **流式返回**：SSE（Server-Sent Events），减少首字延迟，体验更流畅
- App 根据用户配置的 URL 动态构建请求，不写死后端地址

## 四、Android 端实现方案

### 4.0 构建配置与 Android 12 兼容性

#### 4.0.1 Gradle 配置

```kotlin
// app/build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.rd.siri"
    compileSdk = 33

    defaultConfig {
        applicationId = "com.rd.siri"
        minSdk = 31
        targetSdk = 33
        versionCode = 1
        versionName = "1.0.0"

        // CMake 编译 JNI 桥接代码
        externalNativeBuild {
            cmake {
                cppFlags("-O3", "-DNDEBUG")
                cFlags("-O3", "-DNDEBUG")
            }
        }
    }

    // CMake 构建入口
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildFeatures { compose = true }

    composeOptions { kotlinCompilerExtensionVersion = "1.5.3" }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions { jvmTarget = "11" }

    // APK 按 ABI 分拆
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a")
            isUniversalApk = false
        }
    }
}

dependencies {
    // Compose
    implementation("androidx.compose.ui:ui:1.3.3")
    implementation("androidx.compose.material3:material3:1.0.1")
    implementation("androidx.compose.material:material-icons-extended:1.3.1")
    implementation("androidx.compose.ui:ui-tooling-preview:1.3.3")
    implementation("androidx.activity:activity-compose:1.6.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.5.1")

    // Security (加密存储)
    implementation("androidx.security:security-crypto:1.1.0-alpha05")

    // Archive extraction (tar)
    implementation("org.apache.commons:commons-compress:1.25.0")

    // Network
    implementation("com.squareup.okhttp3:okhttp:4.11.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.6.4")

    // Core
    implementation("androidx.core:core-ktx:1.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.5.1")
}
```

#### 4.0.2 AndroidManifest 关键声明

```xml
<!-- AndroidManifest.xml -->
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- 权限 -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />

    <application
        android:name=".SiriApp"
        android:allowBackup="false"
        android:label="Siri"
        android:supportsRtl="true"
        android:theme="@style/Theme.Material3.DayNight.NoActionBar">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTask"
            android:configChanges="orientation|screenSize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".audio.VoiceService"
            android:exported="false"
            android:foregroundServiceType="microphone" />
    </application>
</manifest>
```

#### 4.0.3 Android 12 关键适配清单

| 适配项 | Android 12 变更 | 本 App 处理方式 |
|--------|----------------|----------------|
| **组件导出** | Activity/Service/Receiver 含 `intent-filter` 必须显式声明 `android:exported` | 全部显式声明（见 Manifest） |
| **PendingIntent** | 创建时必须指定 `FLAG_IMMUTABLE` 或 `FLAG_MUTABLE` | 如有通知/快捷方式等场景，强制指定可变性标志 |
| **前台服务** | 后台启动前台服务受限，需 `foregroundServiceType="microphone"` | 收音期间走前台服务，类型声明为 `microphone` |
| **录音权限** | `RECORD_AUDIO` 运行时权限，无变化，Android 12 无新限制 | 标准 `ActivityCompat.requestPermissions` 流程 |
| **Material You** | 支持动态取色（Monet），Material3 原生适配 | 使用 `material3` 主题，动态颜色作为视觉亮点 |
| **隐私指示器** | 状态栏显示麦克风调用绿点（系统强制的隐私保护） | 无需处理，系统自动管理 |
| **后台应用限制** | 后台应用无法启动 Activity，需通知 trampoline | App 在活跃使用场景下运行，不受影响 |
| **精确闹钟** | `SCHEDULE_EXACT_ALARM` 权限需用户手动在设置中授予 | 本 App 无需使用 |
| **蓝牙权限** | Android 12 新增 `BLUETOOTH_CONNECT` / `BLUETOOTH_SCAN` 运行时权限 | 如后续接入蓝牙耳机 VAD，需适配 |
| **WebView** | 默认 `SameSite=Lax`，跨域 Cookie 行为变化 | App 不使用 WebView，无影响 |
| **网络安全性** | 默认不允许明文 HTTP（`cleartextTrafficPermitted="false"`） | 直连 HTTPS 服务，无需改动；本地 Ollama 需在 `network_security_config.xml` 配置放行指定 IP |
| **备份排除** | 模型文件不应包含在 Android 自动备份中 | `android:allowBackup="false"`，模型在 `filesDir/models/` 下由用户上传 |

#### 4.0.4 本地 HTTP 放行（Ollama 场景）

当用户配置的 API 地址为本地 Ollama（`http://192.168.x.x:11434/v1`）时，Android 默认禁止明文流量，需配置 `network_security_config.xml`：

```xml
<!-- res/xml/network_security_config.xml -->
<network-security-config>
    <!-- 默认走 HTTPS -->
    <base-config cleartextTrafficPermitted="false" />

    <!-- 允许用户指定的 IP 走明文（照顾本地 Ollama 场景） -->
    <!-- 注意：无法预知用户 IP，改为全局放行在 debug 构建中启用 -->
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">192.168.1.2</domain>
    </domain-config>
</network-security-config>
```

> **建议**：Release 构建默认仅 HTTPS；debug 构建全局放行 `cleartextTrafficPermitted="true"`，方便本地开发调试。

#### 4.0.5 模型文件存储

模型不打包进 APK，用户首次启动时在 ModelSetupScreen 界面从手机上传 `.tar` 文件，App 自动解压到内部存储私有目录：

```kotlin
// ModelManager.kt
object ModelManager {
    const val ASR_MODEL_DIR = "models/asr"   // → filesDir/models/asr/
    const val TTS_MODEL_DIR = "models/tts"   // → filesDir/models/tts/

    // 检查模型是否就绪
    fun checkAsrReady(context: Context): Boolean =
        listOf("model.int8.onnx", "tokens.txt").all {
            File(modelsDir(context), "$ASR_MODEL_DIR/$it").exists()
        }

    fun checkTtsReady(context: Context): Boolean =
        listOf("model.onnx", "vocos.onnx", "tokens.txt", "lexicon.txt").all {
            File(modelsDir(context), "$TTS_MODEL_DIR/$it").exists()
        }

    // 检查 TTS tar 是否已解压（用于判断是否需要 vocoder）
    fun checkTtsExtracted(context: Context): Boolean

    // 从 tar 文件解压模型（--strip-components=1，自动重命名已知文件）
    fun extractTar(context: Context, uri: Uri, destSubDir: String,
                   onProgress: (Float) -> Unit): Result<Unit>

    // 复制 vocoder 文件到 TTS 模型目录（vocos-22khz-univ.onnx → vocos.onnx）
    fun copyVocoder(context: Context, uri: Uri, onProgress: (Float) -> Unit): Result<Unit>
}
```

解压时自动重命名已知文件（如 `model-steps-3.onnx` → `model.onnx`），避免文件名不匹配。

### 4.1 项目结构

```
app/
├── build.gradle.kts
├── src/main/
│   ├── AndroidManifest.xml
│   ├── java/com/rd/siri/
│   │   ├── MainActivity.kt          # 主 Activity，导航分发
│   │   ├── SiriApp.kt               # Application，统一加载 .so
│   │   ├── audio/
│   │   │   ├── AudioRecorder.kt     # 音频录制（AudioRecord）
│   │   │   ├── AudioPlayer.kt       # 音频播放（AudioTrack）
│   │   │   └── VoiceService.kt      # Android 12 前台服务（后台收音）
│   │   ├── asr/
│   │   │   └── SherpaAsrEngine.kt   # sherpa-onnx ASR 封装（external fun → JNI）
│   │   ├── tts/
│   │   │   └── SherpaTtsEngine.kt   # sherpa-onnx TTS 封装（external fun → JNI）
│   │   ├── chat/
│   │   │   ├── ChatSession.kt       # 对话管理（历史上下文）
│   │   │   └── LlmClient.kt         # 通用 LLM API 客户端（动态配置）
│   │   ├── config/
│   │   │   ├── LlmConfig.kt         # 配置数据类
│   │   │   ├── ConfigRepository.kt  # 配置读写（EncryptedSharedPreferences）
│   │   │   └── ConfigViewModel.kt   # 设置界面 ViewModel
│   │   ├── model/
│   │   │   ├── ChatMessage.kt       # 消息数据类
│   │   │   ├── AppState.kt          # UI 状态管理
│   │   │   └── ModelManager.kt      # 模型文件检查与 tar 解压
│   │   └── ui/
│   │       ├── MainScreen.kt        # 主界面 Composable
│   │       ├── MainViewModel.kt     # 主界面 ViewModel
│   │       ├── SettingsScreen.kt    # 大模型配置界面
│   │       ├── ModelSetupScreen.kt  # 模型文件上传界面
│   │       └── theme/               # Material3 主题
│   ├── cpp/                         # JNI 桥接 C 源码
│   │   ├── CMakeLists.txt           # CMake 构建配置
│   │   ├── sherpa_onnx_jni.c        # JNI 桥接实现（~310 行）
│   │   └── include/sherpa-onnx/c-api/
│   │       └── c-api.h              # sherpa-onnx C API 头文件
│   └── jniLibs/                     # sherpa-onnx 预编译 .so
│       ├── arm64-v8a/
│       │   ├── libsherpa-onnx-c-api.so
│       │   └── libonnxruntime.so
│       └── armeabi-v7a/
│           ├── libsherpa-onnx-c-api.so
│           └── libonnxruntime.so
```

### 4.2 核心数据结构

```kotlin
// ChatMessage.kt
data class ChatMessage(
    val role: String,        // "user" | "assistant"
    val content: String,
    val timestamp: Long = System.currentTimeMillis()
)

// AppState.kt
sealed class VoiceState {
    object Idle : VoiceState()
    object Listening : VoiceState()      // 正在收音
    object Recognizing : VoiceState()    // ASR 识别中
    object Thinking : VoiceState()       // 等待 DeepSeek 回复
    object Speaking : VoiceState()       // 正在播报
    data class Error(val msg: String) : VoiceState()
}
```

### 4.3 sherpa-onnx JNI 集成

采用**预编译 .so + CMake JNI 桥接**方案：

**架构**：
```
Kotlin (external fun) → CMake 编译的 JNI 桥接 (sherpa_onnx_jni.c)
                      → 预编译 libsherpa-onnx-c-api.so
                      → 预编译 libonnxruntime.so
```

**JNI 桥接** (`app/src/main/cpp/sherpa_onnx_jni.c`)：
- ASR 使用 `SherpaOnnxOfflineRecognizer`（离线识别，缓冲采样后批量解码）
- TTS 使用 `SherpaOnnxOfflineTts`（Matcha 模型：acoustic_model + vocoder + tokens + lexicon）
- 包含 `RecognizerState` 和 `TtsState` 结构体管理 C 端状态

**CMake 构建** (`app/src/main/cpp/CMakeLists.txt`)：
- 链接预编译的 `libsherpa-onnx-c-api.so` 和 `libonnxruntime.so`
- 编译 `sherpa_onnx_jni.c` 输出 `libsherpa_onnx_jni.so`

**.so 加载顺序** (在 `SiriApp.onCreate` 中)：
```kotlin
System.loadLibrary("onnxruntime")       // 底层推理引擎
System.loadLibrary("sherpa-onnx-c-api") // sherpa-onnx C API
System.loadLibrary("sherpa_onnx_jni")   // 自定义 JNI 桥接
```

**Kotlin 侧** (`SherpaAsrEngine.kt`)：
```kotlin
class SherpaAsrEngine(private val context: Context) {
    // 模型从 context.filesDir/models/asr/ 加载（用户上传）
    fun initialize(): Boolean
    fun acceptWaveform(samples: FloatArray)
    fun getPendingText(): String      // 离线识别无部分结果，始终返回 ""
    fun inputFinished(): String       // 解码所有缓冲样本，返回最终文本
    fun destroy()
    val isReady: Boolean

    private external fun nativeCreateRecognizer(modelPath: String, tokensPath: String): Long
    private external fun nativeAcceptWaveform(ptr: Long, samples: FloatArray)
    private external fun nativeGetText(ptr: Long): String
    private external fun nativeInputFinished(ptr: Long): String
    private external fun nativeDestroyRecognizer(ptr: Long)
}
```

**Kotlin 侧** (`SherpaTtsEngine.kt`)：
```kotlin
class SherpaTtsEngine(private val context: Context) {
    // 模型从 context.filesDir/models/tts/ 加载（用户上传）
    fun initialize(): Boolean
    fun synthesize(text: String, speed: Float = 1.0f): FloatArray?
    fun getSampleRate(): Int           // 默认 22050
    fun destroy()
    val isReady: Boolean

    private external fun nativeCreateTts(
        acousticModelPath: String, vocoderPath: String,
        tokensPath: String, lexiconPath: String
    ): Long
    private external fun nativeSynthesize(ptr: Long, text: String, speed: Float): FloatArray
    private external fun nativeGetSampleRate(ptr: Long): Int
    private external fun nativeDestroyTts(ptr: Long)
}
```

### 4.4 模型上传与解压

#### ModelManager

```kotlin
// model/ModelManager.kt
object ModelManager {
    const val ASR_MODEL_DIR = "models/asr"
    const val TTS_MODEL_DIR = "models/tts"

    fun checkAllReady(context: Context): Boolean =
        checkAsrReady(context) && checkTtsReady(context)

    fun checkAsrReady(context: Context): Boolean =
        listOf("model.int8.onnx", "tokens.txt").all {
            File(modelsDir(context), "$ASR_MODEL_DIR/$it").exists()
        }

    fun checkTtsReady(context: Context): Boolean =
        listOf("model.onnx", "vocos.onnx", "tokens.txt", "lexicon.txt").all {
            File(modelsDir(context), "$TTS_MODEL_DIR/$it").exists()
        }

    // 从 tar 文件解压（--strip-components=1），带进度回调
    fun extractTar(context: Context, uri: Uri, destSubDir: String,
                   onProgress: (Float) -> Unit): Result<Unit>
}
```

#### ModelSetupScreen

首次启动时，若模型文件未就绪则显示上传界面：

- **ASR 模型卡片**：选择 SenseVoice `.tar` 文件 → 解压到 `filesDir/models/asr/`
- **TTS 模型卡片**：选择 Matcha-TTS `.tar` 文件 → 解压到 `filesDir/models/tts/`，自动重命名 `model-steps-3.onnx` → `model.onnx`
- **Vocoder 卡片**（TTS tar 解压后自动显示）：选择 `vocos-22khz-univ.onnx` → 复制为 `vocos.onnx`
- **进度条**：解压过程中显示实时进度（基于已读字节/文件总大小）
- **错误显示**：解压失败时显示错误信息
- **"开始使用"按钮**：两种模型都就绪后可用

使用 `ActivityResultContracts.OpenDocument` 文件选择器，过滤 `application/x-tar` 和 `application/octet-stream` MIME 类型。解压使用 Apache Commons Compress 的 `TarArchiveInputStream`。

#### 导航逻辑 (MainActivity)

```kotlin
var modelsReady by remember {
    mutableStateOf(ModelManager.checkAllReady(context))
}

if (!modelsReady) {
    ModelSetupScreen(onReady = { modelsReady = true })
} else if (showSettings) {
    SettingsScreen(...)
} else {
    MainScreen(...)
}
```

后续启动时 `checkAllReady` 返回 true，直接进入主界面。

### 4.5 工作流程

```
0. [首次] ModelSetupScreen 上传 ASR/TTS tar 文件，app 解压到 filesDir/models/

1. 用户点击/长按麦克风按钮
   │
   ├── [1a] 检查 RECORD_AUDIO 权限（首次弹系统对话框）
   │        Android 12 在权限对话框中有"仅本次" / "使用时允许"选项
   │
   └── [1b] AppState -> Listening
        │   启用前台服务 VoiceService（foregroundServiceType="microphone"）
        │   状态栏通知："正在语音聆听中..."
        │   Android 12 隐私指示器：右上角自动显示绿色麦克风图标 🟢
        │
2. AudioRecorder 开始录制（16kHz, 单声道, PCM, AudioSource.VOICE_RECOGNITION）
   └── 实时传入 sherpa-onnx ASR（流式识别）

3. 用户松手 / 检测到静音 2 秒
   └── AppState -> Recognizing
   └── 停止前台服务，撤销状态栏通知
   └── 调用 recognizer.inputFinished() 取最终文本

4. 将用户文本加入 ChatSession 对话历史
   └── AppState -> Thinking

5. LlmClient 使用用户配置的 API 发送请求
   └── POST {apiUrl}/chat/completions （OpenAI 兼容格式）
   └── 支持 stream: true 实现 SSE 流式返回
   └── 将回复加入对话历史

6. 收到完整回复后
   └── AppState -> Speaking

7. SherpaTtsEngine 将文本合成语音
   └── 返回 PCM 音频数据（采样率 22050Hz）
   └── AudioPlayer（AudioTrack）播放

8. 播放完毕
   └── AppState -> Idle
```

#### Android 12 前台服务实现要点

```kotlin
// audio/VoiceService.kt
@RequiresApi(Build.VERSION_CODES.S)
class VoiceService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("语音聆听中...")
            .setSmallIcon(R.drawable.ic_mic)
            .setOngoing(true)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

        // Android 12: foregroundServiceType 必须在 manifest 声明 + startForeground 匹配
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        return START_NOT_STICKY
    }

    // ...
}
```

```xml
<!-- Android 12: 前台服务类型必须在 manifest 中提前声明 -->
<service
    android:name=".audio.VoiceService"
    android:exported="false"
    android:foregroundServiceType="microphone" />
```

### 4.6 通用 LLM 客户端（动态配置）

```kotlin
// config/LlmConfig.kt
data class LlmConfig(
    val apiUrl: String,       // 例如 "https://api.deepseek.com/v1"
    val model: String,        // 例如 "deepseek-chat"
    val apiKey: String        // 例如 "sk-xxx..."
)

// chat/LlmClient.kt
class LlmClient(private val configRepository: ConfigRepository) {
    
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()
    
    suspend fun chat(messages: List<ChatMessage>): Result<String> {
        val config = configRepository.getConfig()
        if (config == null) {
            return Result.failure(Exception("请先在设置中配置 API 信息"))
        }
        
        val systemPrompt = JSONObject().apply {
            put("role", "system")
            put("content", "你是安卓语音助手，请用简洁的口语化中文回答，回答控制在 100 字以内。")
        }
        
        val msgs = JSONArray().apply {
            put(systemPrompt)
            messages.forEach { msg ->
                put(JSONObject().apply {
                    put("role", msg.role)
                    put("content", msg.content)
                })
            }
        }
        
        val body = JSONObject().apply {
            put("model", config.model)
            put("messages", msgs)
            put("stream", false)
            put("max_tokens", 512)
            put("temperature", 0.7)
        }
        
        val request = Request.Builder()
            .url("${config.apiUrl}/chat/completions")
            .addHeader("Authorization", "Bearer ${config.apiKey}")
            .addHeader("Content-Type", "application/json")
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .build()
        
        return withContext(Dispatchers.IO) {
            try {
                val response = client.newCall(request).execute()
                val json = JSONObject(response.body?.string() ?: "")
                val content = json.getJSONArray("choices")
                    .getJSONObject(0)
                    .getJSONObject("message")
                    .getString("content")
                Result.success(content)
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }
}
```

### 4.7 用户配置界面

#### 4.7.1 配置存储（加密）

```kotlin
// config/ConfigRepository.kt
class ConfigRepository(context: Context) {
    
    private val prefs = EncryptedSharedPreferences.create(
        "llm_config",
        MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC),
        context,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )
    
    fun getConfig(): LlmConfig? {
        val url = prefs.getString("api_url", null) ?: return null
        val model = prefs.getString("model", null) ?: return null
        val key = prefs.getString("api_key", null) ?: return null
        return LlmConfig(url, model, key)
    }
    
    fun saveConfig(config: LlmConfig) {
        prefs.edit()
            .putString("api_url", config.apiUrl)
            .putString("model", config.model)
            .putString("api_key", config.apiKey)
            .apply()
    }
    
    fun clearConfig() {
        prefs.edit().clear().apply()
    }
    
    val hasConfig: Boolean get() = getConfig() != null
}
```

#### 4.7.2 设置界面 UI

```kotlin
// ui/SettingsScreen.kt
@Composable
fun SettingsScreen(
    viewModel: ConfigViewModel,
    onBack: () -> Unit
) {
    var apiUrl by remember { mutableStateOf("") }
    var model by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var showKey by remember { mutableStateOf(false) }
    
    // 加载已有配置
    LaunchedEffect(Unit) {
        viewModel.currentConfig?.let {
            apiUrl = it.apiUrl
            model = it.model
            apiKey = it.apiKey
        }
    }
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("大模型配置") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, "返回")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // API 地址
            OutlinedTextField(
                value = apiUrl,
                onValueChange = { apiUrl = it },
                label = { Text("API 地址") },
                placeholder = { Text("https://api.deepseek.com/v1") },
                supportingText = { Text("兼容 OpenAI 接口的地址") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true
            )
            
            // 模型名称
            OutlinedTextField(
                value = model,
                onValueChange = { model = it },
                label = { Text("模型名称") },
                placeholder = { Text("deepseek-chat") },
                supportingText = { Text("如 deepseek-chat, gpt-4o, qwen-plus 等") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true
            )
            
            // API Key
            OutlinedTextField(
                value = apiKey,
                onValueChange = { apiKey = it },
                label = { Text("API Key") },
                placeholder = { Text("sk-...") },
                supportingText = { Text("密钥将加密存储在设备本地") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                visualTransformation = if (showKey) VisualTransformation.None 
                                       else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { showKey = !showKey }) {
                        Icon(
                            if (showKey) Icons.Filled.VisibilityOff 
                            else Icons.Filled.Visibility,
                            contentDescription = if (showKey) "隐藏" else "显示"
                        )
                    }
                }
            )
            
            // 快捷预设
            Text("快捷预设", style = MaterialTheme.typography.titleSmall)
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(LLM_PRESETS) { preset ->
                    SuggestionChip(
                        onClick = {
                            apiUrl = preset.apiUrl
                            model = preset.model
                        },
                        label = { Text(preset.name) }
                    )
                }
            }
            
            Spacer(modifier = Modifier.weight(1f))
            
            // 保存 / 测试 / 清空
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedButton(
                    onClick = { viewModel.clearConfig(); apiUrl = ""; model = ""; apiKey = "" },
                    modifier = Modifier.weight(1f)
                ) { Text("清空") }
                
                OutlinedButton(
                    onClick = { viewModel.testConnection(apiUrl, model, apiKey) },
                    modifier = Modifier.weight(1f)
                ) { Text("测试连接") }
                
                Button(
                    onClick = { viewModel.saveConfig(apiUrl, model, apiKey) },
                    modifier = Modifier.weight(1f)
                ) { Text("保存") }
            }
        }
    }
}

// 内置预设
data class LlmPreset(val name: String, val apiUrl: String, val model: String)

val LLM_PRESETS = listOf(
    LlmPreset("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"),
    LlmPreset("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"),
    LlmPreset("硅基流动", "https://api.siliconflow.cn/v1", "deepseek-ai/DeepSeek-V3"),
)
```

#### 4.7.3 配置界面效果示意

```
┌──────────────────────────────────┐
│  ← 大模型配置                     │
│                                  │
│  API 地址                        │
│  ┌──────────────────────────┐   │
│  │ https://api.deepseek.com │   │
│  └──────────────────────────┘   │
│  兼容 OpenAI 接口的地址           │
│                                  │
│  模型名称                        │
│  ┌──────────────────────────┐   │
│  │ deepseek-chat            │   │
│  └──────────────────────────┘   │
│  如 deepseek-chat, gpt-4o 等    │
│                                  │
│  API Key                        │
│  ┌──────────────────────────┐   │
│  │ ********                  │👁│   │
│  └──────────────────────────┘   │
│  密钥将加密存储在设备本地          │
│                                  │
│  快捷预设                        │
│  [DeepSeek] [OpenAI] [硅基流动]  │
│                                  │
│                                  │
│  [清空]  [测试连接]  [保存]       │
└──────────────────────────────────┘
```

#### 4.7.4 配置校验逻辑

```kotlin
// config/ConfigViewModel.kt
class ConfigViewModel(application: Application) : AndroidViewModel(application) {
    
    private val repository = ConfigRepository(application)
    val currentConfig: LlmConfig? get() = repository.getConfig()
    
    private val _testResult = MutableLiveData<ResultState>()
    val testResult: LiveData<ResultState> = _testResult
    
    fun saveConfig(apiUrl: String, model: String, apiKey: String) {
        // 基础校验
        val url = apiUrl.trim().trimEnd('/')
        if (url.isBlank() || model.isBlank() || apiKey.isBlank()) {
            _testResult.value = ResultState.Error("所有字段不能为空")
            return
        }
        if (!url.startsWith("http")) {
            _testResult.value = ResultState.Error("API 地址必须以 http 开头")
            return
        }
        
        repository.saveConfig(LlmConfig(url, model.trim(), apiKey.trim()))
        _testResult.value = ResultState.Success("已保存")
    }
    
    fun testConnection(apiUrl: String, model: String, apiKey: String) {
        viewModelScope.launch {
            _testResult.value = ResultState.Loading
            try {
                // 发送一个最小请求测试连通性
                val client = OkHttpClient()
                val body = JSONObject().apply {
                    put("model", model)
                    put("messages", JSONArray().apply {
                        put(JSONObject().apply {
                            put("role", "user")
                            put("content", "hi")
                        })
                    })
                    put("max_tokens", 1)
                }
                val request = Request.Builder()
                    .url("${apiUrl.trimEnd('/')}/chat/completions")
                    .addHeader("Authorization", "Bearer $apiKey")
                    .post(body.toString().toRequestBody("application/json".toMediaType()))
                    .build()
                
                withContext(Dispatchers.IO) {
                    client.newCall(request).execute()
                }
                _testResult.value = ResultState.Success("连接成功！")
            } catch (e: Exception) {
                _testResult.value = ResultState.Error("连接失败: ${e.message}")
            }
        }
    }
    
    fun clearConfig() {
        repository.clearConfig()
    }
}
```

## 五、服务端（可选，非必需）

由于用户在 App 内直接配置 API Key，**服务端不是必须的**。以下场景才需要自建服务端：

### 场景一：不想让普通用户去注册 DeepSeek

做代理服务器，App 默认指向你的服务器，服务器转发到 DeepSeek（你统一付费或做配额控制）。

### 场景二：需要额外服务

```
Android App ──HTTP──▶ 自建服务 ──HTTP──▶ 用户配置的大模型
                        │
                        ├── 对话历史云端同步
                        ├── 用量统计
                        ├── 内容安全过滤
                        └── 多模型路由
```

### 极简代理实现（Python / FastAPI）

```python
# server.py
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class ChatRequest(BaseModel):
    api_url: str          # 用户配置的 API 地址
    api_key: str          # 用户配置的 Key
    model: str            # 模型名
    messages: list[dict]  # 对话
    stream: bool = False
    max_tokens: int = 512
    temperature: float = 0.7

@app.post("/api/chat")
async def chat(req: ChatRequest):
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            f"{req.api_url}/chat/completions",
            headers={
                "Authorization": f"Bearer {req.api_key}",
                "Content-Type": "application/json"
            },
            json={
                "model": req.model,
                "messages": [{"role": "system", "content": "你是语音助手，请用简洁口语化中文回答。"}] + req.messages,
                "stream": req.stream,
                "max_tokens": req.max_tokens,
                "temperature": req.temperature,
            }
        )
        return resp.json()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
```

启动：`~/workspace/llm_venv/bin/python3 server.py`

## 六、开发路线图

### 第一阶段：核心链路跑通（已完成）

| 步骤 | 内容 | 状态 |
|------|------|------|
| 1 | 搭建 Android 项目，jniLibs + CMake JNI 桥接集成 | ✅ |
| 2 | 实现 ModelSetupScreen（用户上传 tar → 解压到 filesDir） | ✅ |
| 3 | 实现 AudioRecord 采集 + sherpa-onnx ASR 离线识别 | ✅ |
| 4 | 实现 LLM API 调用（通用客户端，支持动态配置） | ✅ |
| 5 | 集成 sherpa-onnx TTS + Matcha-TTS 离线合成 | ✅ |
| 6 | 串通全链路：ASR → LLM → TTS | 待验证 |

### 第二阶段：配置与体验

| 步骤 | 内容 | 状态 |
|------|------|------|
| 7 | 设置界面（API URL / Model / Key 配置 + 快捷预设） | ✅ |
| 8 | EncryptedSharedPreferences 加密存储 + 测试连接 | ✅ |
| 9 | 对话历史管理，多轮对话上下文 | ✅ |
| 10 | 流式 LLM 返回（SSE），边接收边显示 | 待实现 |
| 11 | VAD（静音检测），自动结束收音 | 待实现 |

### 第三阶段：工程化

| 步骤 | 内容 |
|------|------|
| 12 | 异常处理：网络断开、模型加载失败、API 配置错误等 |
| 13 | UI 优化：波形动效、状态动画、Material3 动态取色 |
| 14 | 性能优化：模型加载预热、内存管理 |
| 15 | 可选：搭建代理服务器（统一付费 / 内容过滤） |
| 16 | APK 签名与发布 |

## 七、风险与注意事项

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| sherpa-onnx JNI 集成复杂 | 开发延期 | 采用预编译 .so + CMake JNI 桥接，参考 voice_note 项目 |
| 模型过大（~230MB），APK 膨胀 | 下载转化差 | 模型不打包进 APK，用户上传 tar 文件到 app 私有目录 |
| ASR 识别率在嘈杂环境不足 | 用户体验差 | SenseVoice 自带降噪，再用 AudioRecord 的噪声抑制 |
| 用户配错 API 信息 | 功能不可用 | 设置界面提供"测试连接"按钮，一键验证配置有效性 |
| LLM 响应延迟 | 回复慢 | 使用 SSE 流式返回，首 token 即开始显示、收到完整句即开始 TTS |
| TTS 自然度不够 | 语音机械感 | Matcha-TTS 是目前最好的开源中文方案之一 |
| API Key 泄露风险 | 资金损失 | EncryptedSharedPreferences + Android Keystore 加密存储 |

## 八、关键资源

| 资源 | 地址 | 说明 |
|------|------|------|
| sherpa-onnx | https://github.com/k2-fsa/sherpa-onnx | 一站式 ASR/TTS 引擎，支持 Android |
| SenseVoice 模型 | ModelScope: `iic/SenseVoiceSmall` | 中文离线 ASR 模型 |
| Matcha-TTS 模型 | ModelScope 搜索 `matcha-tts` | 中文离线 TTS 模型 |
| DeepSeek API | https://platform.deepseek.com/api-docs | 大模型 API |
| OpenAI API | https://platform.openai.com/docs | OpenAI 兼容接口参考 |
| sherpa-onnx Android demo | sherpa-onnx/android/ 目录 | 官方 Android 示例工程 |
| Android 12 行为变更 | https://developer.android.com/about/versions/12/behavior-changes-12 | 官方兼容性文档 |
| Android 12 前台服务 | https://developer.android.com/about/versions/12/foreground-services | 前台服务限制 |
| EncryptedSharedPreferences | https://developer.android.com/reference/androidx/security/crypto/EncryptedSharedPreferences | 加密存储 |
| Material3 (Material You) | https://m3.material.io/ | Android 12 动态主题 |

## 九、API Key 安全

| 措施 | 说明 |
|------|------|
| **EncryptedSharedPreferences** | Key 以 AES-256 加密存储在设备本地，不硬编码、不上传 |
| **TLS 传输** | 所有请求走 HTTPS，Key 仅在 Authorization Header 中出现 |
| **不计入 git** | 用户自己的 Key 只存设备，不与代码仓库发生任何关系 |
| **可随时清除** | 设置界面提供清空按钮，一键抹掉配置 |
| **Android Keystore** | 加密主密钥由 Android Keystore 硬件支持，root 也难以提取 |

> DeepSeek 注册即送免费额度，开发测试基本够用。
> 如需面向不特定用户发布，可另外搭建代理服务器做统一鉴权和配额。

---

*文档更新日期：2026-06-30*
