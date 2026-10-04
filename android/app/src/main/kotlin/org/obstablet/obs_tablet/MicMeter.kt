package org.obstablet.obs_tablet

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Listens to the microphone while nothing is being streamed or recorded so
 * the mixer meter moves like OBS's. Nothing is encoded or stored; the
 * [AudioEncoder] takes over the microphone (and the meter) when an output
 * starts.
 */
class MicMeter(private val onLevel: (Float, Float) -> Unit) {
    @Volatile var gain = 1.0f
    @Volatile private var running = false
    private var thread: Thread? = null

    @SuppressLint("MissingPermission") // checked by ObsEncoderPlugin before start()
    private fun open(rate: Int, channels: Int): AudioRecord? {
        val mask = if (channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val minBuf = AudioRecord.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        val record = try {
            AudioRecord(MediaRecorder.AudioSource.CAMCORDER, rate, mask, AudioFormat.ENCODING_PCM_16BIT, max(minBuf, 4096 * channels))
        } catch (_: Exception) {
            return null
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return null
        }
        AudioRouting.attach(record) // USB / Bluetooth / chosen microphone
        MicProcessing.attach(record) // Noise Suppression filter
        return try {
            record.startRecording()
            record
        } catch (_: Exception) {
            MicProcessing.detach(record)
            record.release()
            null
        }
    }

    private fun close(record: AudioRecord) {
        try { record.stop() } catch (_: Exception) {}
        MicProcessing.detach(record)
        record.release()
    }

    fun start() {
        if (running) return
        val rate = 44100
        val channels = if (MicProcessing.wantsStereo) 2 else 1
        val record = open(rate, channels) ?: return
        running = true
        thread = Thread({ loop(record, rate, channels) }, "obs-mic-meter").also { it.start() }
    }

    private fun loop(first: AudioRecord, rate: Int, firstChannels: Int) {
        var record = first
        var channels = firstChannels
        // ~50 ms per reading, the same rate as the encoder's levels.
        val frames = rate / 20
        val buf = ShortArray(frames * 2)
        val bus = FloatArray(frames)
        val media = ShortArray(frames)
        val micBus = MicBus(rate) { id, r, p -> MicProcessing.onInputLevel?.invoke(id, r, p) }
        try {
            while (running) {
                if (MicProcessing.wantsStereo != (channels == 2)) {
                    close(record)
                    channels = if (MicProcessing.wantsStereo) 2 else 1
                    record = open(rate, channels) ?: break
                }
                var got = 0
                while (got < frames * channels && running) {
                    val n = record.read(buf, got, frames * channels - got)
                    if (n < 0) break
                    got += n
                }
                if (got < frames * channels) {
                    if (!running) break
                    continue
                }
                // Advance Media Sources so their meters move while nothing is
                // encoded (their audio isn't part of the mic level).
                MediaAudioMixer.mixInto(media, frames, 1, mix = false)
                micBus.mix(buf, frames, channels, bus) // each mic: channel, filters, fader
                var sum = 0.0
                var peak = 0f
                for (f in 0 until frames) {
                    val a = minOf(abs(bus[f]), 1f)
                    sum += (a * a).toDouble()
                    if (a > peak) peak = a
                }
                onLevel(sqrt(sum / frames).toFloat(), peak)
            }
        } finally {
            close(record)
        }
    }

    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        onLevel(0f, 0f)
    }
}
