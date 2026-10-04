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
    fun start() {
        if (running) return
        val rate = 44100
        val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER,
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuf, 4096),
            )
        } catch (_: Exception) {
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return
        }
        AudioRouting.attach(record) // USB / Bluetooth / chosen microphone
        MicProcessing.attach(record) // Noise Suppression filter
        try {
            record.startRecording()
        } catch (_: Exception) {
            record.release()
            return
        }
        running = true
        thread = Thread({ loop(record, rate) }, "obs-mic-meter").also { it.start() }
    }

    private fun loop(record: AudioRecord, rate: Int) {
        // ~50 ms per reading, the same rate as the encoder's levels.
        val buf = ShortArray(rate / 20)
        val processor = MicProcessor(rate)
        try {
            while (running) {
                val n = record.read(buf, 0, buf.size)
                if (n <= 0) {
                    if (n < 0) break
                    continue
                }
                // Advance Media Sources so their meters move while nothing is
                // encoded (their audio isn't mixed into the mic level).
                MediaAudioMixer.mixInto(buf, n, 1, mix = false)
                processor.process(buf, n, 1) // filters first, then the fader, like OBS
                val g = gain
                for (i in 0 until n) buf[i] = (buf[i] * g).toInt().coerceIn(-32768, 32767).toShort()
                var sum = 0.0
                var peak = 0f
                for (i in 0 until n) {
                    val f = abs(buf[i].toInt()) / 32768f
                    sum += (f * f).toDouble()
                    if (f > peak) peak = f
                }
                onLevel(sqrt(sum / n).toFloat(), peak)
            }
        } finally {
            try { record.stop() } catch (_: Exception) {}
            MicProcessing.detach(record)
            record.release()
        }
    }

    fun stop() {
        running = false
        thread?.join(500)
        thread = null
        onLevel(0f, 0f)
    }
}
