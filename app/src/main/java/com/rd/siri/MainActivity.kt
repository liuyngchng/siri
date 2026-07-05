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
import com.rd.siri.model.ModelManager
import com.rd.siri.ui.MainScreen
import com.rd.siri.ui.MainViewModel
import com.rd.siri.ui.ModelSetupScreen
import com.rd.siri.ui.SettingsHubScreen
import com.rd.siri.ui.SettingsScreen
import com.rd.siri.ui.theme.SiriTheme

private enum class SettingsSubScreen { LLM_CONFIG, MODEL_SETUP }

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
                var modelsReady by remember {
                    mutableStateOf(ModelManager.checkAllReady(this@MainActivity))
                }
                val config by configViewModel.config.collectAsState()
                var setupComplete by remember { mutableStateOf(config != null) }

                if (!modelsReady) {
                    // First-run wizard step 1: download voice models
                    ModelSetupScreen(
                        onReady = { modelsReady = true }
                    )
                } else if (!setupComplete) {
                    // First-run wizard step 2: configure LLM API
                    SettingsScreen(
                        viewModel = configViewModel,
                        onBack = { setupComplete = true }
                    )
                } else if (showSettings) {
                    // Post-setup: settings hub with sub-navigation
                    when (settingsSubScreen) {
                        null -> SettingsHubScreen(
                            onNavigateToLlmConfig = { settingsSubScreen = SettingsSubScreen.LLM_CONFIG },
                            onNavigateToModelSetup = { settingsSubScreen = SettingsSubScreen.MODEL_SETUP },
                            onDismiss = { showSettings = false }
                        )
                        SettingsSubScreen.LLM_CONFIG -> SettingsScreen(
                            viewModel = configViewModel,
                            onBack = { settingsSubScreen = null }
                        )
                        SettingsSubScreen.MODEL_SETUP -> ModelSetupScreen(
                            onBack = { settingsSubScreen = null }
                        )
                    }
                } else {
                    MainScreen(
                        viewModel = mainViewModel,
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
