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
        /** Max buffer: 30 seconds of audio at 48kHz (worst case). */
        private const val MAX_BUFFER_SECONDS = 30
    }

    private var audioTrack: AudioTrack? = null
    private var currentSampleRate: Int = 0
    private var isPlaying = false

    /**
     * Play PCM float audio. Reuses the underlying AudioTrack across calls
     * to avoid per-sentence creation overhead.
     */
    suspend fun play(pcmFloats: FloatArray, sampleRate: Int = 22050) = withContext(Dispatchers.IO) {
        val shortSamples = ShortArray(pcmFloats.size) { i ->
            (pcmFloats[i] * Short.MAX_VALUE).toInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
        }

        val bufferSizeInBytes = shortSamples.size * 2
        val track = obtainTrack(sampleRate, bufferSizeInBytes)

        isPlaying = true

        try {
            // Write all samples (MODE_STATIC: overwrites internal buffer from position 0)
            track.write(shortSamples, 0, shortSamples.size)
            track.play()

            // Wait for playback to finish — poll playState so we stop
            // as soon as the audio is done instead of using a fixed delay.
            val durationMs = (shortSamples.size.toLong() * 1000) / sampleRate
            awaitPlaybackComplete(track, durationMs)
        } finally {
            isPlaying = false
            // Don't release — keep AudioTrack for next sentence
        }
    }

    /**
     * Get or create an AudioTrack that can hold at least [minBufferBytes].
     * Reuses the existing track when the sample rate matches and the
     * buffer is large enough.
     */
    private fun obtainTrack(sampleRate: Int, minBufferBytes: Int): AudioTrack {
        val existing = audioTrack
        if (existing != null &&
            existing.sampleRate == sampleRate &&
            existing.state == AudioTrack.STATE_INITIALIZED
        ) {
            // Check current buffer capacity (2 bytes per PCM16 sample)
            val currentCap = existing.bufferSizeInFrames * 2
            if (currentCap >= minBufferBytes) {
                // Reuse — just stop whatever was playing
                if (existing.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    existing.stop()
                }
                return existing
            }
            // Buffer too small, release and recreate below
            existing.release()
            audioTrack = null
        }

        existing?.release()

        // Allocate with generous headroom so we rarely need to recreate.
        val bufferSize = maxOf(minBufferBytes, sampleRate * 2 * MAX_BUFFER_SECONDS)

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
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        currentSampleRate = sampleRate
        audioTrack = track
        return track
    }

    /**
     * Wait for playback to complete, polling playState with short intervals.
     * This is more responsive than a fixed delay — playback continues to
     * the next sentence as soon as the current one finishes.
     */
    private suspend fun awaitPlaybackComplete(track: AudioTrack, durationMs: Long) {
        val deadline = durationMs + 200  // reasonable upper bound
        var elapsed = 0L
        while (elapsed < deadline) {
            if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                return  // finished early
            }
            val sleepMs = minOf(50L, deadline - elapsed).coerceAtLeast(10L)
            delay(sleepMs)
            elapsed += sleepMs
        }
        // Timed out — force stop
        if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
            track.stop()
        }
    }

    fun stop() {
        isPlaying = false
        audioTrack?.apply {
            if (playState == AudioTrack.PLAYSTATE_PLAYING) {
                stop()
            }
        }
    }

    /**
     * Fully release audio resources. Call when the player is no longer needed.
     */
    fun release() {
        isPlaying = false
        audioTrack?.release()
        audioTrack = null
    }
}
