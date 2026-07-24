package com.rd.siri.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rd.siri.rag.HybridSearcher
import com.rd.siri.rag.KeywordSearcher
import com.rd.siri.rag.VectorStore
import kotlinx.coroutines.launch
import android.util.Log

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RagSearchScreen(
    hybridSearcher: HybridSearcher,
    vectorStore: VectorStore,
    keywordSearcher: KeywordSearcher,
    onBack: () -> Unit
) {
    var queryText by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<HybridSearcher.HybridResult>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    val isRagReady = vectorStore.stats.loaded && keywordSearcher.loaded
    val ragStats = if (vectorStore.stats.loaded && keywordSearcher.loaded) {
        "已加载 ${vectorStore.stats.numChunks} 个文本块，维度 ${vectorStore.stats.dim}"
    } else {
        "知识库未就绪（资源文件未打包）"
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("知识库检索") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "返回")
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
            // Status bar
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f))
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(if (isRagReady) androidx.compose.ui.graphics.Color.Green else androidx.compose.ui.graphics.Color(0xFFFF9800))
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    ragStats,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Search input
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = queryText,
                    onValueChange = { queryText = it },
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("输入检索关键词…") },
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                FilledIconButton(
                    onClick = {
                        val q = queryText.trim()
                        if (q.isEmpty()) return@FilledIconButton
                        if (!isRagReady) {
                            statusMessage = "知识库未加载"
                            return@FilledIconButton
                        }
                        scope.launch {
                            isLoading = true
                            statusMessage = "检索中…"
                            results = emptyList()
                            try {
                                val r = hybridSearcher.search(q, topK = 5)
                                results = r
                                statusMessage = if (r.isEmpty()) "未找到匹配的知识库条目" else "找到 ${r.size} 条结果"
                            } catch (e: Exception) {
                                Log.e("SiriApp", "RAG search failed", e)
                                statusMessage = "检索失败: ${e.message}"
                            }
                            isLoading = false
                        }
                    },
                    enabled = queryText.isNotBlank() && !isLoading,
                    shape = CircleShape
                ) {
                    Icon(Icons.Filled.Search, contentDescription = "搜索")
                }
            }

            // Results
            if (isLoading) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else if (results.isEmpty() && statusMessage.isNotEmpty()) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(statusMessage, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    itemsIndexed(results) { idx, item ->
                        ResultCard(rank = idx + 1, result = item)
                    }
                }
            }
        }
    }
}

@Composable
private fun ResultCard(rank: Int, result: HybridSearcher.HybridResult) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
        )
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            // Title & RRF score
            Row(verticalAlignment = Alignment.Top) {
                Text(
                    "#$rank",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(end = 6.dp)
                )
                Text(
                    result.title,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    "RRF %.4f".format(result.score),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Spacer(modifier = Modifier.height(4.dp))

            // Score breakdown
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                result.vectorScore?.let {
                    ScoreBadge(label = "向量", score = it, color = 0xFF2196F3.toInt())
                }
                result.keywordScore?.let {
                    ScoreBadge(label = "BM25", score = it, color = 0xFF4CAF50.toInt())
                }
            }

            Spacer(modifier = Modifier.height(6.dp))

            // Content preview
            Text(
                result.content,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 6,
                modifier = Modifier
                    .background(
                        MaterialTheme.colorScheme.surface,
                        RoundedCornerShape(6.dp)
                    )
                    .padding(8.dp)
            )

            // Source file
            Text(
                result.file,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier.padding(top = 4.dp)
            )
        }
    }
}

@Composable
private fun ScoreBadge(label: String, score: Float, color: Int) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(androidx.compose.ui.graphics.Color(color))
        )
        Spacer(modifier = Modifier.width(4.dp))
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.width(2.dp))
        Text("%.4f".format(score), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
