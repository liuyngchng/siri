package com.rd.siri.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import com.rd.siri.model.AppState
import com.rd.siri.model.ChatMessage
import com.rd.siri.model.VoiceState
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// Design tokens
private val BubbleMaxWidthFraction = 0.80f
private val BubbleMaxWidthCap = 480.dp
private val BubbleCornerRadius = 18.dp
private val BubbleTextHPadding = 14.dp
private val BubbleTextVPadding = 11.dp
private val BubbleEdgeMinimum = 52.dp
private val SameSenderSpacing = 4.dp
private val DifferentSenderSpacing = 12.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel,
    setupReady: Boolean,
    onNavigateToSettings: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val messages by viewModel.chatSession.messages.collectAsState()
    val context = LocalContext.current
    val listState = rememberLazyListState()
    var showClearDialog by remember { mutableStateOf(false) }
    val configuration = LocalConfiguration.current
    val availableWidthDp = configuration.screenWidthDp.dp

    val activity = context as? android.app.Activity

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (!granted) { activity?.finish() }
    }

    LaunchedEffect(Unit) {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    LaunchedEffect(Unit) { viewModel.checkConfig() }

    // Scroll to bottom on new messages. Use instant scroll during streaming
    // (voiceState is Speaking/Thinking) to avoid animation jank from frequent
    // token-level updates; animate only when a new message is fully added.
    LaunchedEffect(messages.size, state.voiceState) {
        if (messages.isNotEmpty()) {
            val isStreaming = state.voiceState is VoiceState.Speaking
                || state.voiceState is VoiceState.Thinking
            if (isStreaming) {
                listState.scrollToItem(messages.size - 1)
            } else {
                listState.animateScrollToItem(messages.size - 1)
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("语音助手") },
                actions = {
                    if (messages.isNotEmpty()) {
                        IconButton(onClick = { showClearDialog = true }) {
                            Icon(Icons.Filled.Delete, contentDescription = "清除历史")
                        }
                    }
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = "设置")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            // Setup hint banner: only shown after loading completes and something is missing
            val showSetupHint = !setupReady && state.voiceState !is VoiceState.Loading
            if (showSetupHint) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.errorContainer,
                    tonalElevation = 0.dp
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Icon(
                            Icons.Filled.Warning,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.size(20.dp)
                        )
                        Text(
                            "请在设置中对app进行配置",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.weight(1f)
                        )
                        FilledTonalButton(
                            onClick = onNavigateToSettings,
                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                        ) {
                            Icon(
                                Icons.Filled.Settings,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp)
                            )
                            Spacer(Modifier.width(6.dp))
                            Text("设置", style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
            }

            if (messages.isEmpty()) {
                // Empty state — centered
                StatusCenter(
                    voiceState = state.voiceState,
                    modifier = Modifier.weight(1f)
                )
            } else {
                // Chat messages
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                    state = listState,
                    contentPadding = PaddingValues(
                        start = 16.dp,
                        end = 16.dp,
                        top = 4.dp,
                        bottom = 16.dp
                    )
                ) {
                    itemsIndexed(messages) { index, msg ->
                        // Date separator
                        if (shouldShowDateSeparator(index, messages)) {
                            DateSeparator(timestamp = msg.timestamp)
                        }

                        MessageBubble(
                            message = msg,
                            availableWidth = availableWidthDp,
                            onLongPress = { viewModel.speakText(msg.content) },
                            isFirst = index == 0,
                            isCloseToPrevious = isCloseToPrevious(index, messages)
                        )
                    }

                    // Partial ASR text
                    if (state.partialAsrText.isNotBlank()) {
                        item {
                            MessageBubble(
                                message = ChatMessage(
                                    role = ChatMessage.Role.USER,
                                    content = state.partialAsrText + "…"
                                ),
                                availableWidth = availableWidthDp,
                                isFirst = false,
                                isCloseToPrevious = messages.lastOrNull()?.role == ChatMessage.Role.USER
                            )
                        }
                    }

                    // Thinking indicator
                    if (state.voiceState is VoiceState.Thinking) {
                        item { ThinkingIndicator() }
                    }
                }
            }

            // ---- Input Mode State ----
            var isVoiceMode by remember { mutableStateOf(false) }
            var textDraft by remember { mutableStateOf("") }
            val focusManager = LocalFocusManager.current

            // ---- Input Bar ----
            val isTextFieldEnabled = when (state.voiceState) {
                is VoiceState.Listening, is VoiceState.Recognizing,
                is VoiceState.Thinking, is VoiceState.Speaking -> false
                else -> true
            }

            Surface(
                modifier = Modifier.fillMaxWidth(),
                shadowElevation = 6.dp,
                color = MaterialTheme.colorScheme.surface
            ) {
                if (isVoiceMode) {
                    // ============================================================
                    // Voice Mode: keyboard toggle + press-and-hold mic button
                    // ============================================================
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = { isVoiceMode = false }) {
                            Icon(
                                Icons.Filled.Keyboard,
                                contentDescription = "切换到文字输入",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }

                        Box(modifier = Modifier.weight(1f)) {
                            MicButton(
                                voiceState = state.voiceState,
                                enabled = state.enginesReady,
                                onPressStart = {
                                    viewModel.checkConfig()
                                    viewModel.startListening()
                                },
                                onPressEnd = {
                                    if (state.voiceState is VoiceState.Listening) {
                                        viewModel.stopListening()
                                    }
                                },
                                onPressCancel = { viewModel.cancelListening() }
                            )
                        }

                        // Invisible spacer to balance the keyboard button
                        Spacer(modifier = Modifier.width(48.dp))
                    }
                } else {
                    // ============================================================
                    // Text Mode: text field + send/mic button
                    // ============================================================
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        OutlinedTextField(
                            value = textDraft,
                            onValueChange = { textDraft = it },
                            placeholder = { Text("输入消息…") },
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                            enabled = isTextFieldEnabled,
                            shape = RoundedCornerShape(24.dp)
                        )

                        val trimmed = textDraft.trim()
                        if (trimmed.isNotEmpty()) {
                            // Send button
                            IconButton(
                                onClick = {
                                    viewModel.sendTextMessage(trimmed)
                                    textDraft = ""
                                },
                                enabled = state.enginesReady && isTextFieldEnabled,
                                modifier = Modifier
                                    .size(40.dp)
                                    .background(
                                        MaterialTheme.colorScheme.primary,
                                        CircleShape
                                    )
                            ) {
                                Icon(
                                    Icons.Filled.Send,
                                    contentDescription = "发送消息",
                                    tint = MaterialTheme.colorScheme.onPrimary,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                        } else {
                            // Mic toggle — switch to voice mode
                            IconButton(
                                onClick = {
                                    focusManager.clearFocus()
                                    isVoiceMode = true
                                },
                                enabled = state.enginesReady
                            ) {
                                Icon(
                                    Icons.Filled.Mic,
                                    contentDescription = "切换到语音输入",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))
        }
    }

    // Clear history confirmation dialog
    if (showClearDialog) {
        AlertDialog(
            onDismissRequest = { showClearDialog = false },
            title = { Text("清除历史") },
            text = { Text("确定要清除所有对话记录吗？此操作不可撤销。") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.clearHistory()
                    showClearDialog = false
                }) { Text("确定") }
            },
            dismissButton = {
                TextButton(onClick = { showClearDialog = false }) { Text("取消") }
            }
        )
    }
}

// MARK: - Status Center (empty state)

@Composable
private fun StatusCenter(voiceState: VoiceState, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier.fillMaxWidth(),
        contentAlignment = Alignment.Center
    ) {
        when (voiceState) {
            is VoiceState.Loading -> LoadingState(voiceState.message)
            is VoiceState.Error -> ErrorState(voiceState.message)
            is VoiceState.Idle -> IdleState()
            else -> { /* other states handled by chat content */ }
        }
    }
}

@Composable
private fun IdleState() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.widthIn(max = 280.dp)
    ) {
        Icon(
            Icons.Filled.Mic,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(64.dp)
        )
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(
                "语音助手",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onBackground
            )
            Text(
                "按住按钮开始说话",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}

@Composable
private fun LoadingState(message: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        CircularProgressIndicator(modifier = Modifier.size(48.dp))
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
    }
}

@Composable
private fun ErrorState(message: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.padding(horizontal = 32.dp)
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.size(48.dp)
        )
        Text(
            message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center
        )
    }
}

// MARK: - Date Separator

@Composable
private fun DateSeparator(timestamp: Long) {
    val fmt = remember { SimpleDateFormat("yyyy年M月d日", Locale.getDefault()) }
    Text(
        text = fmt.format(Date(timestamp)),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
    )
}

private fun shouldShowDateSeparator(index: Int, messages: List<ChatMessage>): Boolean {
    if (index == 0) return false
    val current = messages[index]
    val previous = messages[index - 1]
    val cal = Calendar.getInstance()
    cal.timeInMillis = current.timestamp
    val currentDay = cal.get(Calendar.DAY_OF_YEAR)
    cal.timeInMillis = previous.timestamp
    val previousDay = cal.get(Calendar.DAY_OF_YEAR)
    return currentDay != previousDay
}

private fun isCloseToPrevious(index: Int, messages: List<ChatMessage>): Boolean {
    if (index == 0) return false
    val current = messages[index]
    val previous = messages[index - 1]
    val sameRole = current.role == previous.role
    val closeInTime = (current.timestamp - previous.timestamp) < 120_000L // 2 min
    return sameRole && closeInTime
}

// MARK: - Message Bubble

@Composable
private fun MessageBubble(
    message: ChatMessage,
    availableWidth: Dp,
    onLongPress: (() -> Unit)? = null,
    isFirst: Boolean = false,
    isCloseToPrevious: Boolean = false
) {
    val isUser = message.role == ChatMessage.Role.USER
    val bubbleMaxWidth = minOf(availableWidth * BubbleMaxWidthFraction, BubbleMaxWidthCap)

    val bottomSpacing = if (isCloseToPrevious) SameSenderSpacing else DifferentSenderSpacing
    val topSpacing = if (isFirst) 8.dp else 0.dp

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = topSpacing, bottom = bottomSpacing),
        contentAlignment = if (isUser) Alignment.CenterEnd else Alignment.CenterStart
    ) {
        Surface(
            shape = RoundedCornerShape(BubbleCornerRadius),
            color = if (isUser) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.surfaceVariant,
            modifier = Modifier
                .widthIn(max = bubbleMaxWidth)
                .then(
                    if (onLongPress != null) {
                        Modifier.pointerInput(message.content) {
                            detectTapGestures(onLongPress = { onLongPress() })
                        }
                    } else Modifier
                )
        ) {
            Text(
                text = message.content,
                modifier = Modifier.padding(
                    horizontal = BubbleTextHPadding,
                    vertical = BubbleTextVPadding
                ),
                style = MaterialTheme.typography.bodyLarge,
                color = if (isUser) MaterialTheme.colorScheme.onPrimary
                else MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = if (isUser) TextAlign.End else TextAlign.Start
            )
        }
    }
}

// MARK: - Thinking Indicator

@Composable
private fun ThinkingIndicator() {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.padding(bottom = 8.dp)
    ) {
        Text(
            "思考中…",
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// MARK: - Press-to-Speak Button
//
// A voice input button following Android press-and-hold UX best practices:
// - Idle: large pill button with "按住说话" label, press & hold to start recording
// - Recording: same pill, filled primary color, "松开结束" label + pulse ring
// - Release: auto-chains through ASR → LLM → TTS
// - Swipe away from button while holding: cancels recording
// - Processing/Speaking: compact round icon button to cancel or stop

@Composable
private fun MicButton(
    voiceState: VoiceState,
    enabled: Boolean,
    onPressStart: () -> Unit,
    onPressEnd: () -> Unit,
    onPressCancel: () -> Unit
) {
    val haptic = LocalHapticFeedback.current
    var isPressed by remember { mutableStateOf(false) }

    // Keep a stable reference so the pointerInput coroutine always sees the latest state
    val currentVoiceState by rememberUpdatedState(voiceState)

    val isIdle = voiceState is VoiceState.Idle
        || voiceState is VoiceState.Error
        || voiceState is VoiceState.Loading
    val isListening = voiceState is VoiceState.Listening
    val isProcessing = voiceState is VoiceState.Recognizing
        || voiceState is VoiceState.Thinking
    val isSpeaking = voiceState is VoiceState.Speaking

    // ---- Visual state ----
    val buttonBg = when {
        !enabled -> MaterialTheme.colorScheme.surfaceVariant
        isPressed || isListening -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.surfaceVariant
    }

    val contentColor = when {
        !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
        isPressed || isListening -> MaterialTheme.colorScheme.onPrimary
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (!enabled) Modifier.alpha(0.5f) else Modifier),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Box(contentAlignment = Alignment.Center) {
            if (isIdle || isListening || isPressed || isProcessing || isSpeaking) {
                // ============================================================
                // Press-and-Hold Voice Button (idle / recording states)
                // ============================================================
                val pressLabel = when {
                    isPressed || isListening -> "松开结束"
                    else -> "按住说话"
                }
                val contentDesc = when {
                    isPressed || isListening -> "松开结束录音"
                    else -> "按住开始录音"
                }

                Box(
                    modifier = Modifier
                        .shadow(
                            elevation = if (isPressed || isListening) 0.dp else 4.dp,
                            shape = RoundedCornerShape(16.dp),
                            clip = false
                        )
                        .background(buttonBg, RoundedCornerShape(16.dp))
                        .then(
                            if (enabled) {
                                // Pointer-input kept alive as long as the button is
                                // enabled, so the gesture survives the Idle→Listening
                                // transition triggered by onPressStart().
                                Modifier.pointerInput(enabled) {
                                    detectTapGestures(
                                        onPress = {
                                            val vs = currentVoiceState

                                            isPressed = true
                                            haptic.performHapticFeedback(
                                                HapticFeedbackType.LongPress
                                            )

                                            // If any pipeline is in progress, cancel it first
                                            if (vs !is VoiceState.Idle
                                                && vs !is VoiceState.Error
                                                && vs !is VoiceState.Loading
                                            ) {
                                                onPressCancel()
                                            }

                                            // Start recording
                                            onPressStart()

                                            val released = try {
                                                tryAwaitRelease()
                                            } catch (_: CancellationException) {
                                                false
                                            } finally {
                                                isPressed = false
                                            }

                                            if (released) onPressEnd()
                                            else onPressCancel()
                                        }
                                    )
                                }
                            } else Modifier
                        )
                        .padding(horizontal = 40.dp, vertical = 16.dp)
                        .semantics { contentDescription = contentDesc },
                    contentAlignment = Alignment.Center
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            Icons.Filled.Mic,
                            contentDescription = null,
                            tint = contentColor,
                            modifier = Modifier.size(24.dp)
                        )
                        Text(
                            text = pressLabel,
                            color = contentColor,
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }
            }
        }
    }
}
