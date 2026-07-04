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
import com.rd.siri.ui.SettingsScreen
import com.rd.siri.ui.theme.SiriTheme

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
                var modelsReady by remember {
                    mutableStateOf(ModelManager.checkAllReady(this@MainActivity))
                }
                val config by configViewModel.config.collectAsState()
                var setupComplete by remember { mutableStateOf(config != null) }

                if (!modelsReady) {
                    ModelSetupScreen(
                        onReady = { modelsReady = true }
                    )
                } else if (!setupComplete) {
                    SettingsScreen(
                        viewModel = configViewModel,
                        onBack = { setupComplete = true }
                    )
                } else if (showSettings) {
                    SettingsScreen(
                        viewModel = configViewModel,
                        onBack = { showSettings = false }
                    )
                } else {
                    MainScreen(
                        viewModel = mainViewModel,
                        onNavigateToSettings = { showSettings = true }
                    )
                }
            }
        }
        Log.i(TAG, "MainActivity onCreate done")
    }
}
