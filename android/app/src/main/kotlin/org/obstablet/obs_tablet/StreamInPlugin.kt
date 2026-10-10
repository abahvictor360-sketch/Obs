package org.obstablet.obs_tablet

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes what phones and encoders stream into OBSpad over RTMP (the
 * "Phone / Encoder (RTMP)" source): Dart runs the RTMP server and passes
 * the H.264 video and AAC audio here. Video is decoded by the hardware
 * decoder straight onto a Flutter texture; audio is decoded to PCM and
 * mixed into the stream through [LiveAudio].
 *
 * Channel "obs_tablet/stream_in": open {id} -> {textureId}, videoConfig
 * {id, avcc}, video {id, data, key}, audioConfig {id, asc}, audio {id,
 * data}, close {id}. Calls back "videoSize" {id, width, height} and
 * "error" {id, message}.
 */
class StreamInPlugin(messenger: BinaryMessenger, private val textures: TextureRegistry) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "obs_tablet/stream_in")
    private val main = Handler(Looper.getMainLooper())
    private val decoders = HashMap<String, StreamDecoder>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id == null) {
            result.error("args", "id missing", null)
            return
        }
        try {
            when (call.method) {
                "open" -> {
                    decoders.remove(id)?.close()
                    val d = StreamDecoder(id, textures.createSurfaceProducer(), ::onSize, ::onError)
                    decoders[id] = d
                    result.success(mapOf("textureId" to d.textureId))
                }
                "videoConfig" -> {
                    decoders[id]?.videoConfig(call.argument<ByteArray>("avcc") ?: ByteArray(0))
                    result.success(null)
                }
                "video" -> {
                    decoders[id]?.video(call.argument<ByteArray>("data") ?: ByteArray(0), call.argument<Boolean>("key") == true)
                    result.success(null)
                }
                "audioConfig" -> {
                    decoders[id]?.audioConfig(call.argument<ByteArray>("asc") ?: ByteArray(0))
                    result.success(null)
                }
                "audio" -> {
                    decoders[id]?.audio(call.argument<ByteArray>("data") ?: ByteArray(0))
                    result.success(null)
                }
                "close" -> {
                    decoders.remove(id)?.close()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("stream_in", e.message ?: e.toString(), null)
        }
    }

    private fun onSize(id: String, w: Int, h: Int) {
        main.post { channel.invokeMethod("videoSize", mapOf("id" to id, "width" to w, "height" to h)) }
    }

    private fun onError(id: String, message: String) {
        main.post { channel.invokeMethod("error", mapOf("id" to id, "message" to message)) }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        decoders.values.forEach { it.close() }
        decoders.clear()
    }
}

/** One RTMP input's decoders, on their own thread. */
class StreamDecoder(
    private val id: String,
    private val producer: TextureRegistry.SurfaceProducer,
    private val onSize: (String, Int, Int) -> Unit,
    private val onError: (String, String) -> Unit,
) {
    val textureId: Long get() = producer.id()

    private val thread = HandlerThread("obs-stream-in").apply { start() }
    private val handler = Handler(thread.looper)
    private var video: MediaCodec? = null
    private var audio: MediaCodec? = null
    private var avcc: ByteArray? = null
    private var nalLength = 4
    private var waitKey = true
    private var width = 0
    private var height = 0
    private var audioRate = 44100
    private var audioChannels = 2
    @Volatile private var closed = false
    private val info = MediaCodec.BufferInfo()
    private val startUs = System.nanoTime() / 1000

    init {
        producer.setSize(1280, 720)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                // The surface was recreated (app came back): start over at a keyframe.
                handler.post { restartVideo() }
            }

            override fun onSurfaceCleanup() {
                handler.post { releaseVideo() }
            }
        })
    }

    fun videoConfig(config: ByteArray) = handler.post {
        if (config.contentEquals(avcc)) return@post
        avcc = config
        restartVideo()
    }

    fun video(data: ByteArray, key: Boolean) = handler.post {
        if (closed) return@post
        if (waitKey && !key) return@post
        val codec = video ?: return@post
        waitKey = false
        try {
            val annexB = toAnnexB(data, nalLength)
            val i = codec.dequeueInputBuffer(20_000)
            if (i >= 0) {
                val buf = codec.getInputBuffer(i)!!
                buf.clear()
                if (annexB.size > buf.capacity()) {
                    codec.queueInputBuffer(i, 0, 0, 0, 0)
                } else {
                    buf.put(annexB)
                    codec.queueInputBuffer(i, 0, annexB.size, System.nanoTime() / 1000 - startUs, 0)
                }
            }
            drainVideo(codec)
        } catch (e: Exception) {
            onError(id, "Video decoder: ${e.message}")
            restartVideo()
        }
    }

    private fun drainVideo(codec: MediaCodec) {
        while (true) {
            val o = codec.dequeueOutputBuffer(info, 0)
            when {
                o >= 0 -> codec.releaseOutputBuffer(o, true) // show it now: live, lowest delay
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = codec.outputFormat
                    var w = f.getInteger(MediaFormat.KEY_WIDTH)
                    var h = f.getInteger(MediaFormat.KEY_HEIGHT)
                    if (f.containsKey("crop-right") && f.containsKey("crop-left")) {
                        w = f.getInteger("crop-right") - f.getInteger("crop-left") + 1
                    }
                    if (f.containsKey("crop-bottom") && f.containsKey("crop-top")) {
                        h = f.getInteger("crop-bottom") - f.getInteger("crop-top") + 1
                    }
                    if (w > 0 && h > 0 && (w != width || h != height)) {
                        width = w
                        height = h
                        producer.setSize(w, h)
                        onSize(id, w, h)
                    }
                }
                else -> return
            }
        }
    }

    private fun releaseVideo() {
        try {
            video?.stop()
        } catch (_: Exception) {
        }
        try {
            video?.release()
        } catch (_: Exception) {
        }
        video = null
    }

    private fun restartVideo() {
        releaseVideo()
        if (closed) return
        val config = avcc ?: return
        val (sps, pps, lengthSize) = parseAvcc(config) ?: run {
            onError(id, "The phone sent a video format OBSpad can't read. Use H.264 (AVC).")
            return
        }
        nalLength = lengthSize
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(START + sps))
                setByteBuffer("csd-1", ByteBuffer.wrap(START + pps))
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 shl 20)
            }
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            val surface: Surface = producer.surface
            codec.configure(format, surface, null, 0)
            codec.start()
            video = codec
            waitKey = true
        } catch (e: Exception) {
            onError(id, "Video decoder: ${e.message}")
        }
    }

    fun audioConfig(asc: ByteArray) = handler.post {
        if (closed || asc.size < 2) return@post
        try {
            audio?.let {
                it.stop()
                it.release()
            }
            val (rate, ch) = parseAsc(asc)
            audioRate = rate
            audioChannels = ch
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, ch).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(asc))
                setInteger(MediaFormat.KEY_IS_ADTS, 0)
            }
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec.configure(format, null, null, 0)
            codec.start()
            audio = codec
        } catch (e: Exception) {
            audio = null
            onError(id, "Audio decoder: ${e.message}")
        }
    }

    private val audioInfo = MediaCodec.BufferInfo()

    fun audio(data: ByteArray) = handler.post {
        if (closed) return@post
        val codec = audio ?: return@post
        try {
            val i = codec.dequeueInputBuffer(10_000)
            if (i >= 0) {
                val buf = codec.getInputBuffer(i)!!
                buf.clear()
                buf.put(data)
                codec.queueInputBuffer(i, 0, data.size, System.nanoTime() / 1000 - startUs, 0)
            }
            while (true) {
                val o = codec.dequeueOutputBuffer(audioInfo, 0)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    audioRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    audioChannels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    continue
                }
                if (o < 0) break
                val out = codec.getOutputBuffer(o)!!
                out.position(audioInfo.offset)
                out.limit(audioInfo.offset + audioInfo.size)
                val shorts = out.order(ByteOrder.nativeOrder()).asShortBuffer()
                val pcm = FloatArray(shorts.remaining()) { shorts.get(it) / 32768f }
                codec.releaseOutputBuffer(o, false)
                LiveAudio.push(id, pcm, audioChannels, audioRate)
            }
        } catch (e: Exception) {
            onError(id, "Audio decoder: ${e.message}")
        }
    }

    fun close() {
        closed = true
        handler.post {
            releaseVideo()
            try {
                audio?.stop()
                audio?.release()
            } catch (_: Exception) {
            }
            audio = null
            producer.release()
            thread.quitSafely()
        }
    }

    companion object {
        private val START = byteArrayOf(0, 0, 0, 1)

        /** First SPS and PPS and the NAL length size from an avcC record. */
        fun parseAvcc(c: ByteArray): Triple<ByteArray, ByteArray, Int>? {
            if (c.size < 7 || c[0].toInt() != 1) return null
            val lengthSize = (c[4].toInt() and 3) + 1
            var p = 5
            val numSps = c[p++].toInt() and 0x1F
            var sps: ByteArray? = null
            repeat(numSps) {
                if (p + 2 > c.size) return null
                val len = ((c[p].toInt() and 0xFF) shl 8) or (c[p + 1].toInt() and 0xFF)
                p += 2
                if (p + len > c.size) return null
                if (sps == null) sps = c.copyOfRange(p, p + len)
                p += len
            }
            if (p >= c.size) return null
            val numPps = c[p++].toInt() and 0xFF
            var pps: ByteArray? = null
            repeat(numPps) {
                if (p + 2 > c.size) return null
                val len = ((c[p].toInt() and 0xFF) shl 8) or (c[p + 1].toInt() and 0xFF)
                p += 2
                if (p + len > c.size) return null
                if (pps == null) pps = c.copyOfRange(p, p + len)
                p += len
            }
            return Triple(sps ?: return null, pps ?: return null, lengthSize)
        }

        /** Length-prefixed NAL units (AVCC) to start-code (Annex B) form. */
        fun toAnnexB(data: ByteArray, lengthSize: Int): ByteArray {
            val out = java.io.ByteArrayOutputStream(data.size + 16)
            var p = 0
            while (p + lengthSize <= data.size) {
                var len = 0
                for (k in 0 until lengthSize) len = (len shl 8) or (data[p + k].toInt() and 0xFF)
                p += lengthSize
                if (len <= 0 || p + len > data.size) break
                out.write(START)
                out.write(data, p, len)
                p += len
            }
            return out.toByteArray()
        }

        private val RATES = intArrayOf(96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)

        /** Sample rate and channels from an AAC AudioSpecificConfig. */
        fun parseAsc(asc: ByteArray): Pair<Int, Int> {
            val b0 = asc[0].toInt() and 0xFF
            val b1 = asc[1].toInt() and 0xFF
            val idx = ((b0 and 0x07) shl 1) or (b1 shr 7)
            val ch = (b1 shr 3) and 0x0F
            return Pair(RATES.getOrElse(idx) { 44100 }, if (ch in 1..2) ch else 2)
        }
    }
}
