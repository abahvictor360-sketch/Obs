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
    }
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
            for (i in 0 until count) {
                val s = (shorts[i] * g).toInt().coerceIn(-32768, 32767)
                shorts[i] = s.toShort()
                val f = abs(s) / 32768f
                levelSum += (f * f).toDouble()
                if (f > levelPeak) levelPeak = f
            }
            levelCount += count
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
