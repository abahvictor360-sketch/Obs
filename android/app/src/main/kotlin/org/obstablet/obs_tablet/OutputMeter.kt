package org.obstablet.obs_tablet

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.HandlerThread
import kotlin.math.pow

/**
 * Level of the sound the tablet is playing (video sources, other apps), for
 * the mixer meters of Media Sources and Audio Output Capture. Uses the
 * Visualizer on the output mix (session 0); devices that don't allow it just
 * show no level.
 */
class OutputMeter(private val onLevel: (Float, Float) -> Unit) {
    private var visualizer: Visualizer? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    @Volatile private var running = false

    fun start(): Boolean {
        if (running) return true
        val v = try {
            Visualizer(0).apply {
                measurementMode = Visualizer.MEASUREMENT_MODE_PEAK_RMS
                enabled = true
            }
        } catch (_: Throwable) {
            return false
        }
        visualizer = v
        running = true
        val t = HandlerThread("obs-output-meter").also { it.start() }
        thread = t
        val h = Handler(t.looper)
        handler = h
        val m = Visualizer.MeasurementPeakRms()
        val tick = object : Runnable {
            override fun run() {
                if (!running) return
                try {
                    if (v.getMeasurementPeakRms(m) == Visualizer.SUCCESS) {
                        onLevel(fromMillibel(m.mRms), fromMillibel(m.mPeak))
                    }
                } catch (_: Throwable) {}
                h.postDelayed(this, 50)
            }
        }
        h.post(tick)
        return true
    }

    fun stop() {
        running = false
        handler?.removeCallbacksAndMessages(null)
        thread?.quitSafely()
        thread = null
        handler = null
        try {
            visualizer?.enabled = false
            visualizer?.release()
        } catch (_: Throwable) {}
        visualizer = null
        onLevel(0f, 0f)
    }

    /** -9600 mB is silence. */
    private fun fromMillibel(mb: Int): Float = if (mb <= -9600) 0f else 10f.pow(mb / 2000f).coerceIn(0f, 1f)
}
