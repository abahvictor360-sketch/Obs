package org.obstablet.obs_tablet

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Rect
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

class EncodedSample(val data: ByteArray, val ptsUs: Long, val flags: Int)

interface EncoderListener {
    /** Event map for Dart (see ObsEncoderPlugin). */
    fun onPacket(packet: Map<String, Any>)

    /** Raw sample for the MP4 recorder. */
    fun onSample(isVideo: Boolean, sample: EncodedSample)
    fun onError(message: String)
}

/**
 * H.264 hardware encoder fed through its input Surface. Composited canvas
 * frames arrive from Dart as RGBA (premultiplied, same byte layout as an
 * ARGB_8888 Bitmap), are copied into a Bitmap and drawn onto the surface
 * with a hardware canvas, which also scales them to the output size.
 */
class VideoEncoder(
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrate: Int,
    private val keyframeIntervalSec: Int,
    private val listener: EncoderListener,
) {
    private lateinit var codec: MediaCodec
    private lateinit var surface: Surface
    private val frameThread = HandlerThread("obs-video-frames")
    private lateinit var frameHandler: Handler
    private var drainThread: Thread? = null
    @Volatile private var running = false
    @Volatile var outputFormat: MediaFormat? = null
        private set

    private var bitmap: Bitmap? = null
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val dst = Rect()

    // Screen compositing mode: under layer + live screen + over layer, drawn
    // on a timer so the stream keeps running while Flutter is in background.
    private var compositing = false
    private var underBmp: Bitmap? = null
    private var overBmp: Bitmap? = null
    private var placement = Placement(0f, 0f, 0f, 0f, 0f, "contain")
    private val compositeTick = object : Runnable {
        override fun run() {
            if (!running || !compositing) return
            renderComposite()
            frameHandler.postDelayed(this, (1000L / fps).coerceAtLeast(1))
        }
    }

    fun start() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, keyframeIntervalSec)
            // Repeat the last frame if Dart stalls, so the stream never freezes.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000L / fps * 3)
        }
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val caps = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).encoderCapabilities
        if (caps.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)) {
            // CBR is what streaming services expect (same default as OBS).
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
        codec.start()
        running = true
        frameThread.start()
        frameHandler = Handler(frameThread.looper)
        dst.set(0, 0, width, height)
        drainThread = Thread({ drain() }, "obs-video-drain").also { it.start() }
    }

    fun drawFrame(rgba: ByteArray, w: Int, h: Int, done: () -> Unit) {
        if (!running) {
            done()
            return
        }
        val posted = frameHandler.post {
            try {
                if (running && w > 0 && h > 0 && rgba.size >= w * h * 4) {
                    var bmp = bitmap
                    if (bmp == null || bmp.width != w || bmp.height != h) {
                        bmp?.recycle()
                        bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        bitmap = bmp
                    }
                    bmp!!.copyPixelsFromBuffer(ByteBuffer.wrap(rgba, 0, w * h * 4))
                    // A plain frame from Dart ends screen compositing.
                    if (compositing) {
                        compositing = false
                        frameHandler.removeCallbacks(compositeTick)
                    }
                    val canvas = surface.lockHardwareCanvas()
                    try {
                        canvas.drawColor(android.graphics.Color.BLACK)
                        canvas.drawBitmap(bmp, null, dst, paint)
                    } finally {
                        surface.unlockCanvasAndPost(canvas)
                    }
                }
            } catch (e: Exception) {
                listener.onError("Video frame error: ${e.message}")
            } finally {
                done()
            }
        }
        // The looper is shutting down: still answer Dart so it doesn't wait forever.
        if (!posted) done()
    }

    /**
     * Updates the compositing layers (null = keep the previous one) and
     * switches to compositing mode.
     */
    fun setOverlays(
        under: ByteArray?,
        over: ByteArray?,
        clearOver: Boolean,
        w: Int,
        h: Int,
        place: Placement,
        done: () -> Unit,
    ) {
        if (!running) {
            done()
            return
        }
        val posted = frameHandler.post {
            try {
                fun load(bytes: ByteArray, current: Bitmap?): Bitmap? {
                    if (w <= 0 || h <= 0 || bytes.size < w * h * 4) return current
                    val b = if (current == null || current.width != w || current.height != h) {
                        current?.recycle()
                        Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    } else {
                        current
                    }
                    b.copyPixelsFromBuffer(ByteBuffer.wrap(bytes, 0, w * h * 4))
                    return b
                }
                if (under != null) underBmp = load(under, underBmp)
                if (over != null) {
                    overBmp = load(over, overBmp)
                } else if (clearOver) {
                    overBmp?.recycle()
                    overBmp = null
                }
                placement = place
                if (!compositing && running) {
                    compositing = true
                    frameHandler.post(compositeTick)
                }
            } catch (e: Exception) {
                listener.onError("Overlay error: ${e.message}")
            } finally {
                done()
            }
        }
        if (!posted) done()
    }

    private fun renderComposite() {
        try {
            val canvas = surface.lockHardwareCanvas()
            try {
                canvas.drawColor(android.graphics.Color.BLACK)
                underBmp?.let { canvas.drawBitmap(it, null, dst, paint) }
                // Hold the lock until the frame is posted: the hardware canvas
                // uploads the bitmap at unlockCanvasAndPost.
                synchronized(ScreenCapture.lock) {
                    val screen = ScreenCapture.frontBitmap()
                    if (screen != null && ScreenCapture.frameWidth > 0) {
                        drawScreen(canvas, screen, ScreenCapture.frameWidth, ScreenCapture.frameHeight)
                    }
                    overBmp?.let { canvas.drawBitmap(it, null, dst, paint) }
                    surface.unlockCanvasAndPost(canvas)
                }
            } catch (e: Exception) {
                // Canvas already posted or surface gone; nothing else to do.
                throw e
            }
        } catch (e: Exception) {
            if (running) listener.onError("Compositor error: ${e.message}")
        }
    }

    private fun drawScreen(canvas: android.graphics.Canvas, screen: Bitmap, sw: Int, sh: Int) {
        val p = placement
        if (p.w <= 0f || p.h <= 0f) return
        val box = android.graphics.RectF(p.x, p.y, p.x + p.w, p.y + p.h)
        val dest = fitRect(sw.toFloat(), sh.toFloat(), box, p.fit)
        canvas.save()
        canvas.rotate(p.rotation, box.centerX(), box.centerY())
        canvas.clipRect(box)
        canvas.drawBitmap(screen, Rect(0, 0, sw, sh), dest, paint)
        canvas.restore()
    }

    fun requestKeyframe() {
        if (!running) return
        try {
            codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: Exception) {
        }
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        while (running) {
            val index = try {
                codec.dequeueOutputBuffer(info, 10_000)
            } catch (e: IllegalStateException) {
                break
            }
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = codec.outputFormat
                    outputFormat = f
                    val sps = f.getByteBuffer("csd-0")
                    val pps = f.getByteBuffer("csd-1")
                    if (sps != null && pps != null) {
                        listener.onPacket(packet("video", true, false, 0, bytesOf(sps) + bytesOf(pps)))
                    }
                }
                index >= 0 -> {
                    val buf = codec.getOutputBuffer(index)
                    if (buf != null && info.size > 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val data = ByteArray(info.size)
                        buf.get(data)
                        val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        val isKey = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        listener.onPacket(packet("video", isConfig, isKey, info.presentationTimeUs, data))
                        if (!isConfig) listener.onSample(true, EncodedSample(data, info.presentationTimeUs, info.flags))
                    }
                    codec.releaseOutputBuffer(index, false)
                }
            }
        }
    }

    fun stop() {
        if (!running) return
        running = false
        compositing = false
        drainThread?.join(1000)
        frameThread.quitSafely()
        frameThread.join(1000)
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        codec.release()
        surface.release()
        bitmap?.recycle()
        bitmap = null
        underBmp?.recycle()
        underBmp = null
        overBmp?.recycle()
        overBmp = null
    }
}

/** Screen placement in output pixels; rotation in degrees around the center. */
data class Placement(val x: Float, val y: Float, val w: Float, val h: Float, val rotation: Float, val fit: String) {
    companion object {
        fun from(map: Map<*, *>?): Placement {
            fun f(k: String) = (map?.get(k) as? Number)?.toFloat() ?: 0f
            return Placement(f("x"), f("y"), f("w"), f("h"), f("rotation"), map?.get("fit") as? String ?: "contain")
        }
    }
}

/** Destination rect for an [sw]x[sh] image inside [box] (contain/cover/stretch). */
internal fun fitRect(sw: Float, sh: Float, box: android.graphics.RectF, fit: String): android.graphics.RectF {
    if (fit == "stretch" || sw <= 0f || sh <= 0f) return android.graphics.RectF(box)
    val scale = if (fit == "cover") max(box.width() / sw, box.height() / sh) else minOf(box.width() / sw, box.height() / sh)
    val w = sw * scale
    val h = sh * scale
    val l = box.centerX() - w / 2
    val t = box.centerY() - h / 2
    return android.graphics.RectF(l, t, l + w, t + h)
}

/**
 * Microphone capture + AAC-LC encoding. Applies the mixer gain to the PCM
 * samples and reports RMS/peak levels for the mixer meters.
 */
class AudioEncoder(
    private val sampleRate: Int,
    private val channels: Int,
    private val bitrate: Int,
    private val listener: EncoderListener,
    private val onLevel: (Float, Float) -> Unit,
) {
    @Volatile var gain = 1.0f

    /** Receives the mixed PCM (float, interleaved) when set: NDI audio. */
    @Volatile var pcmTap: ((FloatArray, Int, Int) -> Unit)? = null

    /** Gain for audio played by other apps (captured with the screen). */
    @Volatile var appGain = 1.0f
    private var playback: AudioRecord? = null
    private var playbackProjection: android.media.projection.MediaProjection? = null
    @Volatile var outputFormat: MediaFormat? = null
        private set
    @Volatile private var running = false
    private lateinit var codec: MediaCodec
    private lateinit var record: AudioRecord
    private var thread: Thread? = null

    @SuppressLint("MissingPermission") // checked by ObsEncoderPlugin before start()
    fun start() {
        val channelMask = if (channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        record = AudioRecord(
            MediaRecorder.AudioSource.CAMCORDER,
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT,
            max(minBuf, 4096 * channels * 2),
        )
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        record.startRecording()
        running = true
        thread = Thread({ loop() }, "obs-audio").also { it.start() }
    }

    private fun loop() {
        val frameBytes = 1024 * channels * 2 // one AAC frame of PCM
        val pcm = ByteArray(frameBytes)
        val shorts = ShortArray(frameBytes / 2)
        val info = MediaCodec.BufferInfo()
        val startUs = System.nanoTime() / 1000
        var samplesRead = 0L
        var levelSum = 0.0
        var levelPeak = 0f
        var levelCount = 0
        var lastLevelUs = 0L

        while (running) {
            var read = 0
            while (read < frameBytes && running) {
                val n = record.read(pcm, read, frameBytes - read)
                if (n <= 0) break
                read += n
            }
            if (read <= 0) continue

            // Gain + level metering.
            val bb = ByteBuffer.wrap(pcm, 0, read).order(ByteOrder.LITTLE_ENDIAN)
            val count = read / 2
            bb.asShortBuffer().get(shorts, 0, count)
            val g = gain
            val app = readAppAudio(count)
            val ag = appGain
            for (i in 0 until count) {
                var mixed = shorts[i] * g
                if (app != null) mixed += app[i] * ag
                val s = mixed.toInt().coerceIn(-32768, 32767)
                shorts[i] = s.toShort()
                val f = abs(s) / 32768f
                levelSum += (f * f).toDouble()
                if (f > levelPeak) levelPeak = f
            }
            levelCount += count
            pcmTap?.let { tap -> tap(FloatArray(count) { shorts[it] / 32768f }, sampleRate, channels) }
            bb.clear()
            bb.asShortBuffer().put(shorts, 0, count)

            val ptsUs = startUs + samplesRead * 1_000_000L / sampleRate
            samplesRead += count / channels

            if (ptsUs - lastLevelUs > 50_000) {
                onLevel(sqrt(levelSum / max(levelCount, 1)).toFloat(), levelPeak)
                levelSum = 0.0
                levelPeak = 0f
                levelCount = 0
                lastLevelUs = ptsUs
            }

            try {
                val inIndex = codec.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val inBuf = codec.getInputBuffer(inIndex)!!
                    inBuf.clear()
                    inBuf.put(pcm, 0, read)
                    codec.queueInputBuffer(inIndex, 0, read, ptsUs, 0)
                }
                drainOutput(info)
            } catch (e: IllegalStateException) {
                if (running) listener.onError("Audio encoder error: ${e.message}")
                break
            }
        }
    }

    private var appBuf = ShortArray(0)

    /**
     * Reads the same number of samples of other apps' audio (games, videos)
     * when screen capture is running, or null. Uses AudioPlaybackCapture,
     * which needs Android 10 and an active MediaProjection.
     */
    @SuppressLint("MissingPermission")
    private fun readAppAudio(count: Int): ShortArray? {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) return null
        val projection = ScreenCapture.projection
        if (projection !== playbackProjection) {
            playback?.let {
                try { it.stop() } catch (_: Exception) {}
                it.release()
            }
            playback = null
            playbackProjection = projection
            if (projection != null) {
                try {
                    val config = android.media.AudioPlaybackCaptureConfiguration.Builder(projection)
                        .addMatchingUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .addMatchingUsage(android.media.AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(android.media.AudioAttributes.USAGE_UNKNOWN)
                        .build()
                    val channelMask = if (channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
                    playback = AudioRecord.Builder()
                        .setAudioFormat(
                            AudioFormat.Builder()
                                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .setSampleRate(sampleRate)
                                .setChannelMask(channelMask)
                                .build(),
                        )
                        .setAudioPlaybackCaptureConfig(config)
                        .build()
                        .also { it.startRecording() }
                } catch (e: Exception) {
                    listener.onError("App audio capture unavailable: ${e.message}")
                    playback = null
                }
            }
        }
        val r = playback ?: return null
        if (appBuf.size < count) appBuf = ShortArray(count)
        val n = r.read(appBuf, 0, count, AudioRecord.READ_NON_BLOCKING)
        if (n <= 0) return null
        // Missing samples (app audio arrives in bursts) are treated as silence.
        for (i in n until count) appBuf[i] = 0
        return appBuf
    }

    private fun drainOutput(info: MediaCodec.BufferInfo) {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, 0)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = codec.outputFormat
                    outputFormat = f
                    f.getByteBuffer("csd-0")?.let {
                        listener.onPacket(packet("audio", true, false, 0, bytesOf(it)))
                    }
                }
                index >= 0 -> {
                    val buf = codec.getOutputBuffer(index)
                    val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (buf != null && info.size > 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val data = ByteArray(info.size)
                        buf.get(data)
                        listener.onPacket(packet("audio", isConfig, false, info.presentationTimeUs, data))
                        if (!isConfig) listener.onSample(false, EncodedSample(data, info.presentationTimeUs, info.flags))
                    }
                    codec.releaseOutputBuffer(index, false)
                }
                else -> return
            }
        }
    }

    fun stop() {
        if (!running) return
        running = false
        thread?.join(1000)
        try {
            record.stop()
        } catch (_: Exception) {
        }
        record.release()
        playback?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        playback = null
        try {
            codec.stop()
        } catch (_: Exception) {
        }
        codec.release()
    }
}

internal fun bytesOf(b: ByteBuffer): ByteArray {
    val d = b.duplicate()
    d.rewind()
    val out = ByteArray(d.remaining())
    d.get(out)
    return out
}

internal fun packet(kind: String, config: Boolean, key: Boolean, ptsUs: Long, data: ByteArray): Map<String, Any> =
    mapOf(
        "type" to "packet",
        "kind" to kind,
        "config" to config,
        "key" to key,
        "pts" to ptsUs,
        "data" to data,
    )
