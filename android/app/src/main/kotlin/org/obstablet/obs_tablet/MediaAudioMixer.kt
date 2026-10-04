package org.obstablet.obs_tablet

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * The sound of Media Sources (video files) in the stream. video_player shows
 * the picture; the audio track is decoded again here, kept in step with the
 * player's position (sent from Dart) and mixed into the encoder after the
 * microphone, like OBS's media source audio. Set with "setMediaAudio".
 */
object MediaAudioMixer {
    const val RATE = 44100

    /** Per-source level (rms, peak) of what is mixed, for the mixer meters. */
    @Volatile var onLevel: ((String, Float, Float) -> Unit)? = null

    private val tracks = HashMap<String, Track>()

    /** [list]: {id, path, gain, playing, positionMs, loop} for each live media source. */
    fun update(list: List<Map<*, *>>) {
        synchronized(tracks) {
            val wanted = list.mapNotNull { it["id"] as? String }.toSet()
            for (id in tracks.keys.toList()) {
                if (id !in wanted) tracks.remove(id)?.close()
            }
            for (m in list) {
                val id = m["id"] as? String ?: continue
                val path = m["path"] as? String ?: continue
                var t = tracks[id]
                if (t != null && t.path != path) {
                    t.close()
                    t = null
                }
                if (t == null) {
                    t = Track(id, path)
                    tracks[id] = t
                }
                t.gain = (m["gain"] as? Number)?.toFloat() ?: 1f
                t.loop = m["loop"] as? Boolean ?: true
                t.sync((m["positionMs"] as? Number)?.toLong() ?: 0L, m["playing"] as? Boolean ?: false)
            }
        }
    }

    fun clear() = update(emptyList())

    private var scratch = FloatArray(0)

    /**
     * Adds the playing tracks to interleaved 16-bit PCM ([channels] 1 or 2,
     * at [RATE]) and advances them. With [mix] false they only advance (for
     * the meters while nothing is encoded).
     */
    fun mixInto(samples: ShortArray, count: Int, channels: Int, mix: Boolean = true) {
        val active = synchronized(tracks) { tracks.values.filter { it.playing } }
        if (active.isEmpty()) return
        val frames = count / max(channels, 1)
        if (scratch.size < frames * 2) scratch = FloatArray(frames * 2)
        for (t in active) {
            val got = t.read(scratch, frames)
            if (got == 0) continue
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

    /** One media file's audio: a decoder thread filling a small ring buffer. */
    private class Track(val id: String, val path: String) {
        @Volatile var gain = 1f
        @Volatile var loop = true
        @Volatile var playing = false

        private val lock = Object()
        private val ring = FloatArray(RATE * 2 * 2) // 2 s of stereo
        private var readAt = 0
        private var writeAt = 0
        private var buffered = 0 // floats
        /** Media time (µs) of the next sample read. */
        private var readPosUs = 0L
        private var seekToUs = -1L
        /** File length, to compare positions across a loop. */
        @Volatile private var durationUs = 0L
        @Volatile private var alive = true
        private var levelSum = 0.0
        private var levelPeak = 0f
        private var levelFrames = 0
        private val thread = Thread({ decodeLoop() }, "obs-media-audio").also { it.start() }

        fun close() {
            alive = false
            synchronized(lock) { lock.notifyAll() }
        }

        fun sync(positionMs: Long, isPlaying: Boolean) {
            synchronized(lock) {
                playing = isPlaying
                val dur = durationUs
                val cur = if (loop && dur > 0) (readPosUs % dur) / 1000 else readPosUs / 1000
                var drift = abs(cur - positionMs)
                if (loop && dur > 0) drift = min(drift, dur / 1000 - drift) // across the wrap
                // The player reports its position every few hundred ms; only a
                // real jump (seek, restart, loop, start) moves the audio.
                if (seekToUs < 0 && (drift > 500 || !isPlaying)) {
                    if (drift > 500) {
                        seekToUs = positionMs * 1000
                        buffered = 0
                        readAt = 0
                        writeAt = 0
                        readPosUs = seekToUs
                    }
                }
                lock.notifyAll()
            }
        }

        fun read(out: FloatArray, frames: Int): Int {
            synchronized(lock) {
                val n = min(frames, buffered / 2)
                for (i in 0 until n * 2) {
                    out[i] = ring[readAt]
                    readAt = (readAt + 1) % ring.size
                }
                buffered -= n * 2
                readPosUs += n * 1_000_000L / RATE
                lock.notifyAll()
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

        private fun write(stereo: FloatArray, n: Int) {
            synchronized(lock) {
                var i = 0
                while (i < n * 2 && alive) {
                    while (buffered >= ring.size - 2 && alive && seekToUs < 0) lock.wait(50)
                    if (seekToUs >= 0) return // a seek discards what was being written
                    ring[writeAt] = stereo[i]
                    writeAt = (writeAt + 1) % ring.size
                    buffered++
                    i++
                }
            }
        }

        private fun decodeLoop() {
            var extractor: MediaExtractor? = null
            var codec: MediaCodec? = null
            try {
                val ex = MediaExtractor().also { extractor = it }
                ex.setDataSource(path)
                var format: MediaFormat? = null
                for (i in 0 until ex.trackCount) {
                    val f = ex.getTrackFormat(i)
                    if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                        ex.selectTrack(i)
                        format = f
                        break
                    }
                }
                val fmt = format ?: return // no audio track
                if (fmt.containsKey(MediaFormat.KEY_DURATION)) durationUs = fmt.getLong(MediaFormat.KEY_DURATION)
                val c = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!).also { codec = it }
                c.configure(fmt, null, null, 0)
                c.start()
                var srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var srcChannels = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var floatPcm = false
                var resamplePos = 0.0
                var prevL = 0f
                var prevR = 0f
                var inputDone = false
                var dropBeforeUs = -1L
                val info = MediaCodec.BufferInfo()
                var stereo = FloatArray(0)

                while (alive) {
                    // Seek requested by sync().
                    val target = synchronized(lock) {
                        val s = seekToUs
                        if (s >= 0) {
                            seekToUs = -1
                            buffered = 0
                            readAt = 0
                            writeAt = 0
                        }
                        s
                    }
                    if (target >= 0) {
                        ex.seekTo(target, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                        c.flush()
                        inputDone = false
                        dropBeforeUs = target
                        resamplePos = 0.0
                    }
                    if (!inputDone) {
                        val ii = c.dequeueInputBuffer(10_000)
                        if (ii >= 0) {
                            val buf = c.getInputBuffer(ii)!!
                            val size = ex.readSampleData(buf, 0)
                            if (size < 0) {
                                c.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                c.queueInputBuffer(ii, 0, size, ex.sampleTime, 0)
                                ex.advance()
                            }
                        }
                    }
                    val oi = c.dequeueOutputBuffer(info, 10_000)
                    when {
                        oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val of = c.outputFormat
                            srcRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            srcChannels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            floatPcm = of.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                                of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                        }
                        oi >= 0 -> {
                            val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            val out = c.getOutputBuffer(oi)
                            if (out != null && info.size > 0 && (dropBeforeUs < 0 || info.presentationTimeUs >= dropBeforeUs)) {
                                dropBeforeUs = -1
                                out.position(info.offset)
                                out.order(java.nio.ByteOrder.nativeOrder())
                                val bytesPer = if (floatPcm) 4 else 2
                                val inFrames = info.size / (bytesPer * srcChannels)
                                // Resample to RATE stereo (linear).
                                val step = srcRate.toDouble() / RATE
                                val maxOut = (inFrames / step).toInt() + 2
                                if (stereo.size < maxOut * 2) stereo = FloatArray(maxOut * 2)
                                val src = FloatArray(inFrames * 2)
                                for (f in 0 until inFrames) {
                                    var l: Float
                                    var r: Float
                                    if (floatPcm) {
                                        l = out.float
                                        r = if (srcChannels > 1) out.float else l
                                        for (k in 2 until srcChannels) out.float
                                    } else {
                                        l = out.short / 32768f
                                        r = if (srcChannels > 1) out.short / 32768f else l
                                        for (k in 2 until srcChannels) out.short
                                    }
                                    src[f * 2] = l
                                    src[f * 2 + 1] = r
                                }
                                var n = 0
                                var pos = resamplePos
                                while (pos < inFrames) {
                                    val i0 = pos.toInt()
                                    val frac = (pos - i0).toFloat()
                                    val l0 = if (i0 == 0) prevL else src[(i0 - 1) * 2]
                                    val r0 = if (i0 == 0) prevR else src[(i0 - 1) * 2 + 1]
                                    stereo[n * 2] = l0 + (src[i0 * 2] - l0) * frac
                                    stereo[n * 2 + 1] = r0 + (src[i0 * 2 + 1] - r0) * frac
                                    n++
                                    pos += step
                                }
                                resamplePos = pos - inFrames
                                if (inFrames > 0) {
                                    prevL = src[(inFrames - 1) * 2]
                                    prevR = src[(inFrames - 1) * 2 + 1]
                                }
                                c.releaseOutputBuffer(oi, false)
                                write(stereo, n)
                            } else {
                                c.releaseOutputBuffer(oi, false)
                            }
                            if (eos) {
                                if (loop) {
                                    // Rewind the decoder without dropping what's buffered.
                                    ex.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                                    c.flush()
                                    inputDone = false
                                } else {
                                    // Wait for a seek (restart) or close.
                                    synchronized(lock) { while (alive && seekToUs < 0) lock.wait(200) }
                                }
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // Unreadable file or codec: the source just has no audio in the mix.
            } finally {
                try { codec?.stop() } catch (_: Exception) {}
                try { codec?.release() } catch (_: Exception) {}
                try { extractor?.release() } catch (_: Exception) {}
            }
        }
    }
}
