package org.obstablet.obs_tablet

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Sound that arrives live from the network (NDI and RTMP input sources):
 * Dart pushes PCM as it comes, and it's mixed into the stream after the
 * media sources. Each track keeps a small buffer to ride out network
 * jitter, plus the source's audio sync offset; if it falls further behind
 * than that, the oldest sound is dropped so the delay doesn't grow.
 * Set with "setLiveAudio" / "pushLiveAudio".
 */
object LiveAudio {
    const val RATE = MediaAudioMixer.RATE

    /** Extra buffer against network jitter. */
    private const val JITTER_MS = 80

    /** How far beyond its target delay a track may drift before catching up. */
    private const val SLACK_MS = 250

    @Volatile var onLevel: ((String, Float, Float) -> Unit)? = null

    private val tracks = HashMap<String, Track>()

    /** [list]: {id, gain, delayMs} for each live source on Program. */
    fun update(list: List<Map<*, *>>) {
        synchronized(tracks) {
            val wanted = list.mapNotNull { it["id"] as? String }.toSet()
            tracks.keys.retainAll(wanted)
            for (m in list) {
                val id = m["id"] as? String ?: continue
                val t = tracks.getOrPut(id) { Track(id) }
                t.gain = (m["gain"] as? Number)?.toFloat() ?: 1f
                t.setDelay((m["delayMs"] as? Number)?.toInt() ?: 0)
            }
        }
    }

    /** Interleaved float PCM ([channels] 1 or 2) at [rate] for source [id]. */
    fun push(id: String, pcm: FloatArray, channels: Int, rate: Int) {
        val t = synchronized(tracks) { tracks[id] } ?: return
        t.write(pcm, channels, rate)
    }

    private var scratch = FloatArray(0)

    /** Adds the live tracks to interleaved 16-bit PCM, like [MediaAudioMixer.mixInto]. */
    fun mixInto(samples: ShortArray, count: Int, channels: Int, mix: Boolean = true) {
        val active = synchronized(tracks) { tracks.values.toList() }
        if (active.isEmpty()) return
        val frames = count / max(channels, 1)
        if (scratch.size < frames * 2) scratch = FloatArray(frames * 2)
        for (t in active) {
            val got = t.read(scratch, frames)
            if (got == 0) {
                t.reportLevel(0f, 0f, frames)
                continue
            }
            val g = t.gain
            var sum = 0.0
            var peak = 0f
            for (f in 0 until got) {
                val l = scratch[f * 2] * g
                val r = scratch[f * 2 + 1] * g
                val a = max(abs(l), abs(r))
                sum += (a * a).toDouble()
                if (a > peak) peak = a
                if (!mix) continue
                if (channels == 2) {
                    samples[f * 2] = clamp(samples[f * 2] + l * 32767f)
                    samples[f * 2 + 1] = clamp(samples[f * 2 + 1] + r * 32767f)
                } else {
                    samples[f] = clamp(samples[f] + (l + r) * 0.5f * 32767f)
                }
            }
            t.reportLevel(sqrt(sum / got).toFloat(), min(peak, 1f), got)
        }
    }

    private fun clamp(v: Float): Short = v.toInt().coerceIn(-32768, 32767).toShort()

    private class Track(val id: String) {
        @Volatile var gain = 1f
        private val lock = Any()
        private val ring = FloatArray(RATE * 2 * 4) // 4 s of stereo
        private var readAt = 0
        private var writeAt = 0
        private var buffered = 0 // stereo frames
        private var targetFrames = RATE * JITTER_MS / 1000
        /** Waiting to fill up to the target before playing (start, underrun, delay change). */
        private var priming = true
        private var resamplePos = 0.0
        private var lastL = 0f
        private var lastR = 0f
        private var levelSum = 0.0
        private var levelPeak = 0f
        private var levelFrames = 0

        fun setDelay(ms: Int) {
            val t = RATE * (JITTER_MS + ms.coerceIn(0, 2000)) / 1000
            synchronized(lock) {
                if (t != targetFrames) {
                    targetFrames = t
                    priming = buffered < t
                }
            }
        }

        /** Resamples to [RATE] (linear) and appends; drops the oldest on overflow. */
        fun write(pcm: FloatArray, channels: Int, rate: Int) {
            if (channels < 1 || rate <= 0) return
            val inFrames = pcm.size / channels
            val step = rate.toDouble() / RATE
            synchronized(lock) {
                var pos = resamplePos
                while (pos < inFrames) {
                    val i = pos.toInt()
                    val frac = (pos - i).toFloat()
                    val l0 = if (i == 0) lastL else pcm[(i - 1) * channels]
                    val r0 = if (i == 0) lastR else pcm[(i - 1) * channels + (channels - 1)]
                    val l1 = pcm[i * channels]
                    val r1 = pcm[i * channels + (channels - 1)]
                    // pos is between frame i-1 and i (frame "-1" is the last of the previous push).
                    put(l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac)
                    pos += step
                }
                resamplePos = pos - inFrames
                if (inFrames > 0) {
                    lastL = pcm[(inFrames - 1) * channels]
                    lastR = pcm[(inFrames - 1) * channels + (channels - 1)]
                }
                // Too far behind (the network caught up in a burst): skip ahead.
                val max = targetFrames + RATE * SLACK_MS / 1000
                if (buffered > max) {
                    val drop = buffered - targetFrames
                    readAt = (readAt + drop * 2) % ring.size
                    buffered -= drop
                }
            }
        }

        private fun put(l: Float, r: Float) {
            if (buffered >= ring.size / 2) {
                readAt = (readAt + 2) % ring.size
                buffered--
            }
            ring[writeAt] = l
            ring[(writeAt + 1) % ring.size] = r
            writeAt = (writeAt + 2) % ring.size
            buffered++
        }

        fun read(out: FloatArray, frames: Int): Int {
            synchronized(lock) {
                if (priming) {
                    if (buffered < targetFrames) return 0
                    priming = false
                }
                val n = min(frames, buffered)
                for (i in 0 until n * 2) {
                    out[i] = ring[readAt]
                    readAt = (readAt + 1) % ring.size
                }
                buffered -= n
                if (n < frames) priming = true // ran dry: build the buffer up again
                return n
            }
        }

        fun reportLevel(rms: Float, peak: Float, frames: Int) {
            levelSum += (rms * rms * frames).toDouble()
            levelPeak = max(levelPeak, peak)
            levelFrames += frames
            if (levelFrames >= RATE / 20) {
                onLevel?.invoke(id, sqrt(levelSum / levelFrames).toFloat(), levelPeak)
                levelSum = 0.0
                levelPeak = 0f
                levelFrames = 0
            }
        }
    }
}

/** A fixed delay for one mono signal (a mic's audio sync offset). */
class DelayLine(private val sampleRate: Int) {
    private var buf = FloatArray(0)
    private var at = 0
    private var delay = 0

    fun process(samples: FloatArray, count: Int, delayMs: Int) {
        val d = sampleRate * delayMs.coerceIn(0, 2000) / 1000
        if (d != delay) {
            delay = d
            buf = FloatArray(d)
            at = 0
        }
        if (d == 0) return
        for (i in 0 until count) {
            val out = buf[at]
            buf[at] = samples[i]
            samples[i] = out
            at = (at + 1) % d
        }
    }
}
