package com.rd.siri.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.rd.siri.model.AppState
import com.rd.siri.model.ChatMessage
import com.rd.siri.model.VoiceState
import com.rd.siri.ui.theme.SiriTheme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: MainViewModel,
    onNavigateToSettings: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val messages by viewModel.chatSession.messages.collectAsState()
    val context = LocalContext.current
    val listState = rememberLazyListState()
    var showClearDialog by remember { mutableStateOf(false) }

    val activity = context as? android.app.Activity

    // Permission launcher
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (!granted) {
            activity?.finish()
        }
    }

    // Request microphone permission on startup
    LaunchedEffect(Unit) {
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    // Re-check config on screen entry (e.g. returning from settings)
    LaunchedEffect(Unit) {
        viewModel.checkConfig()
    }

    // Auto-scroll to bottom on new messages
    LaunchedEffect(messages.size, state.assistantReply) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Siri") },
                actions = {
                    // Clear history button
                    if (messages.isNotEmpty()) {
                        IconButton(onClick = { showClearDialog = true }) {
                            Icon(Icons.Filled.Delete, contentDescription = "清除历史", modifier = Modifier.size(36.dp))
                        }
                    }
                    // Settings button
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Filled.Settings, contentDescription = "设置", modifier = Modifier.size(36.dp))
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
            // Conversation area
            LazyColumn(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                state = listState,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(vertical = 16.dp)
            ) {
                // Center status (loading / idle / error when no messages)
                if (messages.isEmpty()) {
                    item {
                        StatusCenter(state.voiceState)
                    }
                }

                // Chat messages
                items(messages) { msg ->
                    MessageBubble(msg, onLongPress = { viewModel.speakText(msg.content) })
                }

                // Partial ASR text while listening
                if (state.partialAsrText.isNotBlank()) {
                    item {
                        MessageBubble(
                            ChatMessage(
                                role = ChatMessage.Role.USER,
                                content = state.partialAsrText + "…"
                            )
                        )
                    }
                }

                // Thinking indicator
                if (state.voiceState is VoiceState.Thinking) {
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(8.dp),
                            contentAlignment = Alignment.CenterStart
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                PulseRing(size = 16.dp, strokeWidth = 2.dp)
                                Text(
                                    "思考中…",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            }

            // Microphone button area
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
                onPressCancel = {
                    viewModel.cancelListening()
                },
                onStopSpeaking = {
                    viewModel.stopSpeaking()
                }
            )

            Spacer(modifier = Modifier.height(32.dp))
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
                }) {
                    Text("确定")
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearDialog = false }) {
                    Text("取消")
                }
            }
        )
    }
}

@Composable
private fun MessageBubble(message: ChatMessage, onLongPress: (() -> Unit)? = null) {
    val isUser = message.role == ChatMessage.Role.USER

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
    ) {
        Surface(
            shape = RoundedCornerShape(
                topStart = 16.dp,
                topEnd = 16.dp,
                bottomStart = if (isUser) 16.dp else 4.dp,
                bottomEnd = if (isUser) 4.dp else 16.dp
            ),
            color = if (isUser) MaterialTheme.colorScheme.primaryContainer
            else MaterialTheme.colorScheme.surfaceVariant,
            tonalElevation = if (isUser) 0.dp else 2.dp
        ) {
            Text(
                text = message.content,
                modifier = Modifier.padding(12.dp)
                    .then(
                        if (onLongPress != null) {
                            Modifier.pointerInput(message.content) {
                                detectTapGestures(onLongPress = { onLongPress() })
                            }
                        } else Modifier
                    ),
                style = MaterialTheme.typography.bodyLarge,
                color = if (isUser) MaterialTheme.colorScheme.onPrimaryContainer
                else MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = if (isUser) TextAlign.End else TextAlign.Start
            )
        }
    }
}

@OptIn(ExperimentalAnimationApi::class)
@Composable
private fun StatusCenter(voiceState: VoiceState) {
    AnimatedContent(
        targetState = voiceState,
        transitionSpec = {
            ContentTransform(fadeIn(), fadeOut())
        }
    ) { state ->
        val text = when (state) {
            is VoiceState.Loading -> state.message
            is VoiceState.Idle -> "按住麦克风开始说话"
            is VoiceState.Error -> state.message
            else -> ""
        }

        val color = when (state) {
            is VoiceState.Error -> MaterialTheme.colorScheme.error
            else -> MaterialTheme.colorScheme.onSurfaceVariant
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 120.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            if (state is VoiceState.Loading) {
                PulseRing(size = 48.dp, strokeWidth = 3.dp)
            }
            if (text.isNotBlank()) {
                Text(
                    text = text,
                    style = MaterialTheme.typography.titleMedium,
                    color = color,
                    textAlign = TextAlign.Center
                )
            }
        }
    }
}

@Composable
private fun MicButton(
    voiceState: VoiceState,
    enabled: Boolean,
    onPressStart: () -> Unit,
    onPressEnd: () -> Unit,
    onPressCancel: () -> Unit,
    onStopSpeaking: () -> Unit
) {
    val currentVoiceState by rememberUpdatedState(voiceState)
    val currentOnPressStart by rememberUpdatedState(onPressStart)
    val currentOnPressEnd by rememberUpdatedState(onPressEnd)
    val currentOnPressCancel by rememberUpdatedState(onPressCancel)
    val currentOnStopSpeaking by rememberUpdatedState(onStopSpeaking)

    val haptic = LocalHapticFeedback.current
    val isListening = voiceState is VoiceState.Listening
    val isProcessing = voiceState is VoiceState.Recognizing
        || voiceState is VoiceState.Thinking
    val isSpeaking = voiceState is VoiceState.Speaking
    val isActive = isListening || isProcessing

    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = Alignment.Center
    ) {
        FilledIconButton(
            enabled = enabled,
            onClick = {
                if (isSpeaking) {
                    currentOnStopSpeaking()
                }
            },
            modifier = Modifier
                .size(108.dp)
                .clip(CircleShape)
                .pointerInput(enabled) {
                    if (!enabled) return@pointerInput
                    awaitPointerEventScope {
                        while (true) {
                            awaitFirstDown(requireUnconsumed = false)
                            val downTime = System.currentTimeMillis()
                            val state = currentVoiceState
                            if (state is VoiceState.Idle) {
                                currentOnPressStart()
                            }
                            waitForUpOrCancellation()
                            if (currentVoiceState is VoiceState.Listening) {
                                val duration = System.currentTimeMillis() - downTime
                                if (duration < 300) {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    currentOnPressCancel()
                                } else {
                                    currentOnPressEnd()
                                }
                            }
                        }
                    }
                },
            colors = IconButtonDefaults.filledIconButtonColors(
                containerColor = when {
                    isSpeaking -> MaterialTheme.colorScheme.error
                    isActive -> MaterialTheme.colorScheme.primary
                    else -> MaterialTheme.colorScheme.primaryContainer
                }
            )
        ) {
            Icon(
                imageVector = when {
                    isActive -> Icons.Filled.Stop
                    isSpeaking -> Icons.Filled.Stop
                    else -> Icons.Filled.Mic
                },
                contentDescription = when {
                    isListening -> "松开发送"
                    isSpeaking -> "停止播报"
                    else -> "按住说话"
                },
                modifier = Modifier.size(72.dp),
                tint = when {
                    isSpeaking -> MaterialTheme.colorScheme.onError
                    isActive -> MaterialTheme.colorScheme.onPrimary
                    else -> MaterialTheme.colorScheme.onPrimaryContainer
                }
            )
        }
    }
}

@Composable
private fun PulseRing(size: Dp, strokeWidth: Dp) {
    val infiniteTransition = rememberInfiniteTransition()
    val scale by infiniteTransition.animateFloat(
        initialValue = 0.7f,
        targetValue = 1.3f,
        animationSpec = infiniteRepeatable(
            animation = tween(800, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        )
    )
    val alpha by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 0.15f,
        animationSpec = infiniteRepeatable(
            animation = tween(800, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        )
    )
    val ringColor = MaterialTheme.colorScheme.primary

    Canvas(modifier = Modifier.size(size)) {
        drawCircle(
            color = ringColor.copy(alpha = alpha),
            radius = size.toPx() / 2,
            style = Stroke(
                width = strokeWidth.toPx() * scale
            )
        )
    }
}
