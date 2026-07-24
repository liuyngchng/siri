package com.rd.siri

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModelProvider
import com.rd.siri.config.ConfigViewModel
import com.rd.siri.ui.MainScreen
import com.rd.siri.ui.MainViewModel
import com.rd.siri.ui.ModelSetupScreen
import com.rd.siri.ui.RagSearchScreen
import com.rd.siri.ui.SettingsHubScreen
import com.rd.siri.ui.SettingsScreen
import com.rd.siri.ui.theme.SiriTheme

private enum class SettingsSubScreen { LLM_CONFIG, MODEL_SETUP, RAG_SEARCH }

class MainActivity : ComponentActivity() {

    companion object {
        private const val TAG = "SiriApp"
    }

    private val mainViewModel: MainViewModel by viewModels {
        Log.d(TAG, "creating MainViewModel via factory")
        ViewModelProvider.AndroidViewModelFactory.getInstance(application)
    }

    private val configViewModel: ConfigViewModel by viewModels {
        ViewModelProvider.AndroidViewModelFactory.getInstance(application)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "MainActivity onCreate start")

        setContent {
            Log.d(TAG, "setContent composing")
            SiriTheme {
                var showSettings by remember { mutableStateOf(false) }
                var settingsSubScreen by remember { mutableStateOf<SettingsSubScreen?>(null) }
                val config by configViewModel.config.collectAsState()
                val appState by mainViewModel.state.collectAsState()

                val setupReady = appState.enginesReady && config != null

                if (showSettings) {
                    when (settingsSubScreen) {
                        null -> SettingsHubScreen(
                            onNavigateToLlmConfig = { settingsSubScreen = SettingsSubScreen.LLM_CONFIG },
                            onNavigateToModelSetup = { settingsSubScreen = SettingsSubScreen.MODEL_SETUP },
                            onNavigateToRagSearch = { settingsSubScreen = SettingsSubScreen.RAG_SEARCH },
                            onDismiss = {
                                showSettings = false
                                mainViewModel.checkConfig()
                            },
                            ttsEnabled = appState.ttsEnabled,
                            onToggleTts = { enable ->
                                mainViewModel.toggleTts(enable)
                            }
                        )
                        SettingsSubScreen.LLM_CONFIG -> SettingsScreen(
                            viewModel = configViewModel,
                            onBack = { settingsSubScreen = null }
                        )
                        SettingsSubScreen.MODEL_SETUP -> ModelSetupScreen(
                            onBack = { settingsSubScreen = null }
                        )
                        SettingsSubScreen.RAG_SEARCH -> RagSearchScreen(
                            hybridSearcher = mainViewModel.hybridSearcher,
                            vectorStore = mainViewModel.vectorStore,
                            keywordSearcher = mainViewModel.keywordSearcher,
                            onBack = { settingsSubScreen = null }
                        )
                    }
                } else {
                    MainScreen(
                        viewModel = mainViewModel,
                        setupReady = setupReady,
                        onNavigateToSettings = {
                            showSettings = true
                            settingsSubScreen = null
                        }
                    )
                }
            }
        }
        Log.i(TAG, "MainActivity onCreate done")
    }
}
