package com.rd.siri.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.rd.siri.model.ModelManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelSetupScreen(onReady: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val asrReady = ModelManager.checkAsrReady(context)
    val ttsTarReady = ModelManager.checkTtsExtracted(context)
    val vocoderReady = ModelManager.checkVocoderReady(context)

    var asrOk by remember { mutableStateOf(asrReady) }
    var ttsTarOk by remember { mutableStateOf(ttsTarReady) }
    var vocoderOk by remember { mutableStateOf(vocoderReady) }
    var isExtracting by remember { mutableStateOf(false) }
    var progress by remember { mutableStateOf(0f) }
    var statusText by remember { mutableStateOf("") }
    var errorText by remember { mutableStateOf<String?>(null) }

    val ttsOk = ttsTarOk && vocoderOk
    val allReady = asrOk && ttsOk

    // ---- ASR picker ----
    val asrPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            scope.launch {
                isExtracting = true
                errorText = null
                statusText = "正在解压 ASR 模型..."
                progress = 0f
                val result = withContext(Dispatchers.IO) {
                    ModelManager.extractTar(context, it, ModelManager.ASR_MODEL_DIR) { p ->
                        progress = p
                    }
                }
                result.fold(
                    onSuccess = {
                        asrOk = ModelManager.checkAsrReady(context)
                        statusText = "ASR 模型就绪"
                    },
                    onFailure = { e ->
                        errorText = "解压失败: ${e.message}"
                    }
                )
                isExtracting = false
            }
        }
    }

    // ---- TTS tar picker ----
    val ttsPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            scope.launch {
                isExtracting = true
                errorText = null
                statusText = "正在解压 TTS 模型..."
                progress = 0f
                val result = withContext(Dispatchers.IO) {
                    ModelManager.extractTar(context, it, ModelManager.TTS_MODEL_DIR) { p ->
                        progress = p
                    }
                }
                result.fold(
                    onSuccess = {
                        ttsTarOk = ModelManager.checkTtsExtracted(context)
                        statusText = "TTS 模型就绪"
                    },
                    onFailure = { e ->
                        errorText = "解压失败: ${e.message}"
                    }
                )
                isExtracting = false
            }
        }
    }

    // ---- Vocoder picker ----
    val vocoderPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            scope.launch {
                isExtracting = true
                errorText = null
                statusText = "正在复制 vocoder..."
                progress = 0f
                val result = withContext(Dispatchers.IO) {
                    ModelManager.copyVocoder(context, it) { p -> progress = p }
                }
                result.fold(
                    onSuccess = {
                        vocoderOk = ModelManager.checkVocoderReady(context)
                        statusText = "Vocoder 就绪"
                    },
                    onFailure = { e ->
                        errorText = "复制失败: ${e.message}"
                    }
                )
                isExtracting = false
            }
        }
    }

    // ---- Download handlers ----
    fun downloadAsr() {
        scope.launch {
            isExtracting = true
            errorText = null
            statusText = "正在下载 ASR 模型..."
            progress = 0f
            val result = withContext(Dispatchers.IO) {
                ModelManager.downloadAndExtractAsr(context) { p -> progress = p }
            }
            result.fold(
                onSuccess = {
                    asrOk = ModelManager.checkAsrReady(context)
                    statusText = "ASR 模型就绪"
                },
                onFailure = { e ->
                    errorText = "下载失败: ${e.message}"
                }
            )
            isExtracting = false
        }
    }

    fun downloadTts() {
        scope.launch {
            isExtracting = true
            errorText = null
            statusText = "正在下载 TTS 模型..."
            progress = 0f
            val result = withContext(Dispatchers.IO) {
                ModelManager.downloadAndExtractTts(context) { p -> progress = p }
            }
            result.fold(
                onSuccess = {
                    ttsTarOk = ModelManager.checkTtsExtracted(context)
                    statusText = "TTS 模型就绪"
                },
                onFailure = { e ->
                    errorText = "下载失败: ${e.message}"
                }
            )
            isExtracting = false
        }
    }

    fun downloadVocoder() {
        scope.launch {
            isExtracting = true
            errorText = null
            statusText = "正在下载 vocoder..."
            progress = 0f
            val result = withContext(Dispatchers.IO) {
                ModelManager.downloadVocoder(context) { p -> progress = p }
            }
            result.fold(
                onSuccess = {
                    vocoderOk = ModelManager.checkVocoderReady(context)
                    statusText = "Vocoder 就绪"
                },
                onFailure = { e ->
                    errorText = "下载失败: ${e.message}"
                }
            )
            isExtracting = false
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("模型设置") })
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            Text(
                "首次使用需要导入模型文件。\n可选择下载或从本地导入。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // Native lib status
            Card(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = Color(0xFF4CAF50),
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Column {
                        Text("sherpa-onnx 引擎", style = MaterialTheme.typography.titleSmall)
                        Text("已内置于 APK", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            // ASR model slot
            ModelSlotCard(
                label = "ASR 语音识别模型",
                description = "SenseVoiceSmall int8 量化版，~158 MB",
                isReady = asrOk,
                isExtracting = isExtracting,
                onSelect = { asrPicker.launch(arrayOf("application/x-tar", "application/octet-stream")) },
                onDownload = { downloadAsr() }
            )

            // TTS model slot
            ModelSlotCard(
                label = "TTS 语音合成模型",
                description = "Matcha-TTS 中文，~72 MB",
                isReady = ttsTarOk,
                isExtracting = isExtracting,
                onSelect = { ttsPicker.launch(arrayOf("application/x-tar", "application/octet-stream")) },
                onDownload = { downloadTts() }
            )

            // Vocoder slot
            ModelSlotCard(
                label = "Vocoder 声码器",
                description = "通用声码器，~51 MB",
                isReady = vocoderOk,
                isExtracting = isExtracting,
                onSelect = { vocoderPicker.launch(arrayOf("application/octet-stream", "*/*")) },
                onDownload = { downloadVocoder() }
            )

            // Progress
            if (isExtracting) {
                Column(horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth()) {
                    Text(statusText, style = MaterialTheme.typography.bodySmall)
                    Spacer(modifier = Modifier.height(8.dp))
                    LinearProgressIndicator(
                        progress = progress,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            // Error
            errorText?.let {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        it,
                        modifier = Modifier.padding(12.dp),
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }

            Spacer(modifier = Modifier.weight(1f))

            // Start button
            Button(
                onClick = onReady,
                modifier = Modifier.fillMaxWidth(),
                enabled = allReady && !isExtracting
            ) {
                Text("下一步")
            }
        }
    }
}

@Composable
private fun ModelSlotCard(
    label: String,
    description: String,
    isReady: Boolean,
    isExtracting: Boolean,
    onSelect: () -> Unit,
    onDownload: (() -> Unit)? = null
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                if (isReady) Icons.Filled.CheckCircle else Icons.Filled.Warning,
                contentDescription = null,
                tint = if (isReady) Color(0xFF4CAF50) else Color(0xFFFF9800),
                modifier = Modifier.size(24.dp)
            )
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(label, style = MaterialTheme.typography.titleSmall)
                Text(
                    description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(modifier = Modifier.width(8.dp))
            if (!isReady) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (onDownload != null) {
                        Button(
                            onClick = onDownload,
                            enabled = !isExtracting,
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                        ) {
                            Text("下载", style = MaterialTheme.typography.labelMedium)
                        }
                    }
                    OutlinedButton(
                        onClick = onSelect,
                        enabled = !isExtracting,
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                    ) {
                        Text("上传", style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
    }
}
