package com.rd.siri.config

import android.content.Context
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys

class ConfigRepository(context: Context) {

    companion object {
        private const val TAG = "SiriApp"
        private const val PREFS_NAME = "llm_config"
        private const val KEY_API_URL = "api_url"
        private const val KEY_MODEL = "model"
        private const val KEY_API_KEY = "api_key"
        private const val KEY_ENABLE_SEARCH = "enable_search"
    }

    private val prefs = run {
        Log.d(TAG, "ConfigRepository: creating EncryptedSharedPreferences")
        EncryptedSharedPreferences.create(
            PREFS_NAME,
            MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC),
            context,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun getConfig(): LlmConfig? {
        val url = prefs.getString(KEY_API_URL, null) ?: return null
        val model = prefs.getString(KEY_MODEL, null) ?: return null
        val key = prefs.getString(KEY_API_KEY, null) ?: return null
        val enableSearch = prefs.getBoolean(KEY_ENABLE_SEARCH, false)
        if (url.isBlank() || model.isBlank() || key.isBlank()) return null
        return LlmConfig(apiUrl = url, model = model, apiKey = key, enableSearch = enableSearch)
    }

    fun saveConfig(config: LlmConfig) {
        prefs.edit()
            .putString(KEY_API_URL, config.apiUrl.trimEnd('/'))
            .putString(KEY_MODEL, config.model.trim())
            .putString(KEY_API_KEY, config.apiKey.trim())
            .putBoolean(KEY_ENABLE_SEARCH, config.enableSearch)
            .apply()
    }

    fun clearConfig() {
        prefs.edit().clear().apply()
    }

    val hasConfig: Boolean
        get() = getConfig() != null
}
