package org.obstablet.obs_tablet

import android.media.AudioRecord
import android.media.audiofx.NoiseSuppressor
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * The microphones: one or more Mic/Aux sources, each taking a channel of the
 * audio device (both, input 1 / left, input 2 / right of a USB interface)
 * with its own filters (Noise Gate, Compressor, Limiter, Gain) and fader.
 * Noise Suppression applies to the device. Set from Dart with
 * "setMicProcessing"; applied to the stream, recordings, NDI and meters.
 */
object MicProcessing {
    sealed class Stage {
        data class Gate(val closeDb: Float, val openDb: Float, val attackMs: Float, val holdMs: Float, val releaseMs: Float) : Stage()
        data class Compressor(val ratio: Float, val thresholdDb: Float, val attackMs: Float, val releaseMs: Float, val outputDb: Float) : Stage()
        data class Gain(val db: Float) : Stage()
    }

    /** One Mic/Aux source: [channel] "mix", "left" or "right"; [gain] = fader × mute. */
    class Input(val id: String, val channel: String, val gain: Float, val chain: List<Stage>)

    @Volatile var inputs: List<Input> = listOf(Input("", "mix", 1f, emptyList()))
        private set
    @Volatile var noiseSuppression = false
        private set

    /** Each Mic/Aux source's level (id, rms, peak), for its mixer meter. */
    @Volatile var onInputLevel: ((String, Float, Float) -> Unit)? = null

    /** A source takes one side of a 2-input interface: record in stereo. */
    val wantsStereo: Boolean get() = inputs.any { it.channel != "mix" }

    private val suppressors = java.util.Collections.synchronizedMap(java.util.WeakHashMap<AudioRecord, NoiseSuppressor>())

    private fun parseChain(list: List<*>?): List<Stage> {
        fun f(m: Map<*, *>, k: String, def: Double) = ((m[k] as? Number)?.toDouble() ?: def).toFloat()
        return list.orEmpty().mapNotNull { raw ->
            val m = raw as? Map<*, *> ?: return@mapNotNull null
            when (m["type"]) {
                "gate" -> Stage.Gate(f(m, "closeDb", -32.0), f(m, "openDb", -26.0), f(m, "attackMs", 25.0),
                    f(m, "holdMs", 200.0), f(m, "releaseMs", 150.0))
                "compressor" -> Stage.Compressor(f(m, "ratio", 10.0), f(m, "thresholdDb", -18.0), f(m, "attackMs", 6.0),
                    f(m, "releaseMs", 60.0), f(m, "outputDb", 0.0))
                // A limiter is a compressor with an (almost) infinite ratio and instant attack.
                "limiter" -> Stage.Compressor(1000f, f(m, "thresholdDb", -6.0), 0f, f(m, "releaseMs", 60.0), 0f)
                "gain" -> Stage.Gain(f(m, "db", 0.0))
                else -> null
            }
        }
    }

    fun configure(args: Map<*, *>) {
        val list = args["inputs"] as? List<*>
        inputs = if (list != null) {
            list.mapNotNull { raw ->
                val m = raw as? Map<*, *> ?: return@mapNotNull null
                Input(
                    id = m["id"] as? String ?: "",
                    channel = m["channel"] as? String ?: "mix",
                    gain = (m["gain"] as? Number)?.toFloat() ?: 1f,
                    chain = parseChain(m["chain"] as? List<*>),
                )
            }
        } else {
            // Older single-mic form: {chain}.
            listOf(Input("", "mix", inputs.firstOrNull()?.gain ?: 1f, parseChain(args["chain"] as? List<*>)))
        }
        noiseSuppression = args["noiseSuppression"] == true
        synchronized(suppressors) { suppressors.values.forEach { setEnabled(it, noiseSuppression) } }
    }

    /** Adds the platform noise suppressor to a microphone recording. */
    fun attach(record: AudioRecord) {
        if (!NoiseSuppressor.isAvailable()) return
        try {
            val ns = NoiseSuppressor.create(record.audioSessionId) ?: return
            setEnabled(ns, noiseSuppression)
            suppressors[record] = ns
        } catch (_: Exception) {}
    }

    fun detach(record: AudioRecord) {
        suppressors.remove(record)?.let { try { it.release() } catch (_: Exception) {} }
    }

    private fun setEnabled(ns: NoiseSuppressor, on: Boolean) {
        try { ns.enabled = on } catch (_: Exception) {}
    }
}

/**
 * Mixes the microphone inputs into one mono bus: each [MicProcessing.Input]
 * takes its channel, runs its filters, then its fader. Reports each input's
 * level (for its mixer meter) through [onLevel].
 */
class MicBus(private val sampleRate: Int, private val onLevel: (String, Float, Float) -> Unit) {
    private val processors = HashMap<String, MicProcessor>()
    private var tmp = FloatArray(0)
    private val sums = HashMap<String, DoubleArray>() // sum, peak, frames

    /** [src]: interleaved 16-bit with [srcChannels]; [out]: mono -1..1, [frames] long. */
    fun mix(src: ShortArray, frames: Int, srcChannels: Int, out: FloatArray) {
        java.util.Arrays.fill(out, 0, frames, 0f)
        if (tmp.size < frames) tmp = FloatArray(frames)
        val inputs = MicProcessing.inputs
        for (input in inputs) {
            val ch = when {
                srcChannels < 2 -> -1
                input.channel == "left" -> 0
                input.channel == "right" -> 1
                else -> -1
            }
            for (f in 0 until frames) {
                tmp[f] = if (ch >= 0) {
                    src[f * srcChannels + ch] / 32768f
                } else {
                    var v = 0f
                    for (c in 0 until srcChannels) v += src[f * srcChannels + c]
                    v / srcChannels / 32768f
                }
            }
            processors.getOrPut(input.id) { MicProcessor(sampleRate) }.process(tmp, frames, input.chain)
            val g = input.gain
            val acc = sums.getOrPut(input.id) { DoubleArray(3) }
            for (f in 0 until frames) {
                val v = tmp[f] * g
                out[f] += v
                val a = abs(v)
                acc[0] += (a * a).toDouble()
                if (a > acc[1]) acc[1] = a.toDouble()
            }
            acc[2] += frames
            if (acc[2] >= sampleRate / 20) {
                onLevel(input.id, sqrt(acc[0] / acc[2]).toFloat(), acc[1].toFloat().coerceAtMost(1f))
                acc[0] = 0.0
                acc[1] = 0.0
                acc[2] = 0.0
            }
        }
        if (processors.size > inputs.size) processors.keys.retainAll(inputs.map { it.id }.toSet())
    }
}

/** Per-input state for a filter chain (envelopes, gate state). */
class MicProcessor(private val sampleRate: Int) {
    private var stages: List<MicProcessing.Stage> = emptyList()
    private var gateEnv = FloatArray(0)
    private var gateGain = FloatArray(0)
    private var gateHeld = FloatArray(0)
    private var gateOpen = BooleanArray(0)
    private var compEnvDb = FloatArray(0)
    private var atk = FloatArray(0)
    private var rel = FloatArray(0)
    private val envFall = coef(10f)

    private fun coef(ms: Float) = if (ms <= 0f) 0f else exp(-1f / (ms / 1000f * sampleRate))

    private fun db(x: Float) = if (x <= 1e-6f) -120f else 20f * log10(x)

    /** Processes mono samples (-1..1) in place. */
    fun process(samples: FloatArray, count: Int, chain: List<MicProcessing.Stage>) {
        if (chain.isEmpty()) return
        if (chain !== stages) {
            stages = chain
            gateEnv = FloatArray(chain.size)
            gateGain = FloatArray(chain.size) { 1f }
            gateHeld = FloatArray(chain.size)
            gateOpen = BooleanArray(chain.size) { true }
            compEnvDb = FloatArray(chain.size) { -120f }
            atk = FloatArray(chain.size) {
                when (val st = chain[it]) {
                    is MicProcessing.Stage.Gate -> coef(st.attackMs)
                    is MicProcessing.Stage.Compressor -> coef(st.attackMs)
                    is MicProcessing.Stage.Gain -> 0f
                }
            }
            rel = FloatArray(chain.size) {
                when (val st = chain[it]) {
                    is MicProcessing.Stage.Gate -> coef(st.releaseMs)
                    is MicProcessing.Stage.Compressor -> coef(st.releaseMs)
                    is MicProcessing.Stage.Gain -> 0f
                }
            }
        }
        for (s in 0 until count) {
            val peak = abs(samples[s])
            var gain = 1f
            for ((i, st) in chain.withIndex()) {
                val level = peak * gain
                when (st) {
                    is MicProcessing.Stage.Gate -> {
                        // Peak envelope with a fast rise and ~10 ms fall.
                        gateEnv[i] = max(level, gateEnv[i] * envFall)
                        val envDb = db(gateEnv[i])
                        if (envDb >= st.openDb) {
                            gateOpen[i] = true
                            gateHeld[i] = 0f
                        } else if (envDb < st.closeDb && gateOpen[i]) {
                            gateHeld[i] += 1000f / sampleRate
                            if (gateHeld[i] >= st.holdMs) gateOpen[i] = false
                        }
                        val target = if (gateOpen[i]) 1f else 0f
                        val k = if (target > gateGain[i]) atk[i] else rel[i]
                        gateGain[i] = target + (gateGain[i] - target) * k
                        gain *= gateGain[i]
                    }
                    is MicProcessing.Stage.Compressor -> {
                        val inDb = db(level)
                        val k = if (inDb > compEnvDb[i]) atk[i] else rel[i]
                        compEnvDb[i] = inDb + (compEnvDb[i] - inDb) * k
                        val over = compEnvDb[i] - st.thresholdDb
                        val reduction = if (over > 0f) over * (1f - 1f / st.ratio) else 0f
                        gain *= 10f.pow((st.outputDb - reduction) / 20f)
                    }
                    is MicProcessing.Stage.Gain -> gain *= 10f.pow(st.db / 20f)
                }
            }
            if (gain != 1f) samples[s] = (samples[s] * gain).coerceIn(-1f, 1f)
        }
    }
}
