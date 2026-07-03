package com.rd.siri.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

class AudioPlayer {

    companion object {
        const val CHANNEL_CONFIG = AudioFormat.CHANNEL_OUT_MONO
        const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var audioTrack: AudioTrack? = null
    private var isPlaying = false

    suspend fun play(pcmFloats: FloatArray, sampleRate: Int = 22050) = withContext(Dispatchers.IO) {
        val shortSamples = ShortArray(pcmFloats.size) { i ->
            (pcmFloats[i] * Short.MAX_VALUE).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
        }

        // Use MODE_STATIC since we have the full audio buffer upfront.
        // Buffer size must hold all samples (2 bytes per short).
        val bufferSizeInBytes = shortSamples.size * 2

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

        audioTrack = track
        isPlaying = true

        try {
            track.write(shortSamples, 0, shortSamples.size)
            track.play()
            // Wait for playback to complete (samples / sampleRate = seconds)
            val durationMs = (shortSamples.size.toLong() * 1000) / sampleRate
            delay(durationMs + 100)
            if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                track.stop()
            }
        } finally {
            isPlaying = false
            // release() is safe to call multiple times; stop() may not be
            track.release()
            audioTrack = null
        }
    }

    fun stop() {
        isPlaying = false
        audioTrack?.apply {
            if (playState == AudioTrack.PLAYSTATE_PLAYING) {
                stop()
            }
            release()
        }
        audioTrack = null
    }
}
