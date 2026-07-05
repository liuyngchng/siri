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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
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

    LaunchedEffect(messages.size, state.assistantReply) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("语音助手")
                        if (state.wakeWordEnabled) {
                            Text(
                                "语音唤醒中",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary
                            )
                        }
                    }
                },
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

            // Mic button bar
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
                onPressCancel = { viewModel.cancelListening() },
                onStopSpeaking = { viewModel.finishSpeaking() }
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
                "按住麦克风按钮开始说话",
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
        PulseRing(size = 48.dp, strokeWidth = 3.dp)
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

@OptIn(ExperimentalAnimationApi::class)
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

    // Entrance animation
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }

    val bottomSpacing = if (isCloseToPrevious) SameSenderSpacing else DifferentSenderSpacing
    val topSpacing = if (isFirst) 8.dp else 0.dp

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = topSpacing, bottom = bottomSpacing),
        contentAlignment = if (isUser) Alignment.CenterEnd else Alignment.CenterStart
    ) {
        AnimatedVisibility(
            visible = appeared,
            enter = fadeIn(animationSpec = spring(dampingRatio = 0.85f)) +
                scaleIn(initialScale = 0.92f, animationSpec = spring(dampingRatio = 0.85f))
        ) {
            Surface(
                shape = RoundedCornerShape(BubbleCornerRadius),
                color = if (isUser) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.surfaceVariant,
                tonalElevation = if (isUser) 0.dp else 1.dp,
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
}

// MARK: - Thinking Indicator

@Composable
private fun ThinkingIndicator() {
    val infiniteTransition = rememberInfiniteTransition()
    val dotCount = 3

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
        tonalElevation = 1.dp,
        modifier = Modifier.padding(bottom = 8.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            PulseRing(size = 14.dp, strokeWidth = 2.dp)

            Text(
                "思考中",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // Animated dots
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                for (i in 0 until dotCount) {
                    val alpha by infiniteTransition.animateFloat(
                        initialValue = if (i == 0) 1f else 0.25f,
                        targetValue = if (i == 0) 0.25f else 1f,
                        animationSpec = infiniteRepeatable(
                            animation = tween(400, delayMillis = i * 150),
                            repeatMode = RepeatMode.Restart
                        )
                    )
                    Box(
                        modifier = Modifier
                            .size(4.dp)
                            .clip(CircleShape)
                            .background(
                                MaterialTheme.colorScheme.onSurfaceVariant
                                    .copy(alpha = alpha)
                            )
                    )
                }
            }
        }
    }
}

// MARK: - Mic Button

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

    // Toggle mode: track whether recording was started by tap (vs hold)
    var isToggleMode by remember { mutableStateOf(false) }
    LaunchedEffect(voiceState) {
        if (voiceState is VoiceState.Idle) isToggleMode = false
    }

    val statusHint = when {
        isToggleMode && isListening -> "轻点停止"
        isListening -> "松手停止"
        isProcessing -> "轻点取消"
        isSpeaking -> "轻点停止播报"
        else -> ""
    }

    val buttonBg = when {
        isSpeaking -> MaterialTheme.colorScheme.error
        isProcessing -> Color(0xFFFFA500)
        isActive -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.surfaceVariant
    }

    val iconTint = when {
        isSpeaking -> MaterialTheme.colorScheme.onError
        isProcessing -> Color.White
        isActive -> MaterialTheme.colorScheme.onPrimary
        else -> MaterialTheme.colorScheme.primary
    }

    val showPulse = isActive || isSpeaking
    val pulseColor = when {
        isSpeaking -> MaterialTheme.colorScheme.error
        isProcessing -> Color(0xFFFFA500)
        else -> MaterialTheme.colorScheme.primary
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        // Status hint
        Box(
            modifier = Modifier
                .background(
                    if (statusHint.isNotEmpty())
                        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)
                    else Color.Transparent,
                    RoundedCornerShape(50)
                )
                .padding(horizontal = 14.dp, vertical = 6.dp)
        ) {
            Text(
                text = statusHint,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
            )
        }

        // Button with pulse ring
        Box(contentAlignment = Alignment.Center) {
            if (showPulse) {
                PulseRing(
                    color = pulseColor,
                    size = 108.dp,
                    strokeWidth = 3.dp
                )
            }

            FilledIconButton(
                enabled = enabled,
                onClick = {
                    if (isSpeaking) {
                        currentOnStopSpeaking()
                    }
                },
                modifier = Modifier
                    .size(72.dp)
                    .clip(CircleShape)
                    .shadow(
                        elevation = if (isActive || isSpeaking) 0.dp else 4.dp,
                        shape = CircleShape
                    )
                    .pointerInput(enabled) {
                        if (!enabled) return@pointerInput
                        awaitPointerEventScope {
                            while (true) {
                                awaitFirstDown(requireUnconsumed = false)
                                val downTime = System.currentTimeMillis()
                                val state = currentVoiceState
                                val wasIdleWhenPressed = state is VoiceState.Idle

                                // Tap to cancel processing/speaking
                                if (state is VoiceState.Recognizing || state is VoiceState.Thinking) {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    currentOnPressCancel()
                                    waitForUpOrCancellation()
                                    continue
                                }
                                if (state is VoiceState.Speaking) {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    currentOnStopSpeaking()
                                    waitForUpOrCancellation()
                                    continue
                                }

                                if (state is VoiceState.Idle) {
                                    currentOnPressStart()
                                }
                                waitForUpOrCancellation()
                                if (currentVoiceState is VoiceState.Listening) {
                                    val duration = System.currentTimeMillis() - downTime
                                    if (duration < 300 && wasIdleWhenPressed) {
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
                    containerColor = buttonBg
                )
            ) {
                Icon(
                    imageVector = when {
                        isActive || isSpeaking -> Icons.Filled.Stop
                        else -> Icons.Filled.Mic
                    },
                    contentDescription = when {
                        isListening -> "松开发送"
                        isSpeaking -> "停止播报"
                        else -> "按住说话"
                    },
                    modifier = Modifier.size(28.dp),
                    tint = iconTint
                )
            }
        }
    }
}

// MARK: - Pulse Ring (with color override)

@Composable
private fun PulseRing(
    size: Dp,
    strokeWidth: Dp,
    color: Color = MaterialTheme.colorScheme.primary
) {
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

    Canvas(modifier = Modifier.size(size)) {
        drawCircle(
            color = color.copy(alpha = alpha),
            radius = size.toPx() / 2,
            style = Stroke(width = strokeWidth.toPx() * scale)
        )
    }
}
