package com.rd.siri.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

class AudioPlayer {

    companion object {
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var activeTrack: AudioTrack? = null
    private var isPlaying = false

    /**
     * Play PCM float audio. Creates a fresh AudioTrack per sentence — no buffer
     * reuse, so stale data from a previous sentence can never leak into playback.
     */
    suspend fun play(pcmFloats: FloatArray, sampleRate: Int = 22050) = withContext(Dispatchers.IO) {
        val shortSamples = ShortArray(pcmFloats.size) { i ->
            (pcmFloats[i] * Short.MAX_VALUE).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
        }

        val bufferSizeInBytes = maxOf(
            shortSamples.size * 2,
            AudioTrack.getMinBufferSize(sampleRate, CHANNEL_CONFIG, AUDIO_FORMAT)
        )

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AUDIO_FORMAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(CHANNEL_CONFIG)
                    .build()
            )
            .setBufferSizeInBytes(bufferSizeInBytes)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        activeTrack = track
        isPlaying = true

        try {
            track.write(shortSamples, 0, shortSamples.size)
            track.play()

            val durationMs = (shortSamples.size.toLong() * 1000) / sampleRate
            awaitPlaybackComplete(track, durationMs)
        } finally {
            isPlaying = false
            activeTrack = null
            track.release()
        }
    }

    /**
     * Wait for playback to complete, polling playState with short intervals.
     */
    private suspend fun awaitPlaybackComplete(track: AudioTrack, durationMs: Long) {
        val deadline = durationMs + 500
        var elapsed = 0L
        while (elapsed < deadline) {
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                return
            }
            val sleepMs = minOf(50L, deadline - elapsed).coerceAtLeast(10L)
            delay(sleepMs)
            elapsed += sleepMs
        }
        if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
            track.stop()
        }
    }

    fun stop() {
        isPlaying = false
        activeTrack?.apply {
            if (playState == AudioTrack.PLAYSTATE_PLAYING) {
                stop()
            }
        }
    }

    fun release() {
        isPlaying = false
        activeTrack?.release()
        activeTrack = null
    }
}
