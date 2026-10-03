package org.obstablet.obs_tablet

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between Dart and the hardware encoders.
 *
 * Methods (channel "obs_tablet/encoder"):
 *   isSupported, start(config), stop, frame(data,width,height), requestKeyframe,
 *   setMicGain(gain), startRecording -> path, stopRecording -> path
 *
 * Events (channel "obs_tablet/encoder_events"), all maps with a "type":
 *   packet {kind: video|audio, config, key, pts (us), data}
 *   level  {rms, peak}
 *   error  {message}
 */
class ObsEncoderPlugin(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, "obs_tablet/encoder")
    private val events = EventChannel(messenger, "obs_tablet/encoder_events")
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    private var video: VideoEncoder? = null
    private var audio: AudioEncoder? = null
    private var recorder: Mp4Recorder? = null
    @Volatile private var micGain = 1.0f

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Thread-safe event emission (EventSink must be used on the main thread). */
    private fun emit(event: Map<String, Any>) {
        main.post { sink?.success(event) }
    }

    private fun emitError(message: String) = emit(mapOf("type" to "error", "message" to message))

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // lockHardwareCanvas on the encoder input surface needs API 23.
                "isSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                "start" -> {
                    start(call)
                    result.success(null)
                }
                "stop" -> {
                    stop()
                    result.success(null)
                }
                "frame" -> {
                    val v = video
                    val data = call.argument<ByteArray>("data")
                    val w = call.argument<Int>("width") ?: 0
                    val h = call.argument<Int>("height") ?: 0
                    if (v == null || data == null) {
                        result.success(null)
                    } else {
                        // Reply once the frame is drawn so Dart never queues frames.
                        v.drawFrame(data, w, h) { main.post { result.success(null) } }
                    }
                }
                "requestKeyframe" -> {
                    video?.requestKeyframe()
                    result.success(null)
                }
                "setMicGain" -> {
                    micGain = (call.argument<Double>("gain") ?: 1.0).toFloat()
                    audio?.gain = micGain
                    result.success(null)
                }
                "startRecording" -> result.success(startRecording())
                "stopRecording" -> result.success(stopRecording())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("encoder", e.message ?: e.toString(), null)
        }
    }

    private var pendingAudio: (() -> Unit)? = null

    private fun start(call: MethodCall) {
        stop()
        val width = call.argument<Int>("width")!!
        val height = call.argument<Int>("height")!!
        val fps = call.argument<Int>("fps")!!
        val vBitrate = call.argument<Int>("videoBitrate")!!
        val aBitrate = call.argument<Int>("audioBitrate")!!
        val keyInt = call.argument<Int>("keyframeInterval")!!
        val sampleRate = call.argument<Int>("sampleRate") ?: 44100
        val channels = call.argument<Int>("channels") ?: 1

        video = VideoEncoder(width, height, fps, vBitrate, keyInt, object : EncoderListener {
            override fun onPacket(packet: Map<String, Any>) = emit(packet)
            override fun onSample(isVideo: Boolean, sample: EncodedSample) {
                recorder?.write(isVideo, sample)
            }
            override fun onError(message: String) = emitError(message)
        }).also { it.start() }

        val startAudio = {
            audio = AudioEncoder(sampleRate, channels, aBitrate, object : EncoderListener {
                override fun onPacket(packet: Map<String, Any>) = emit(packet)
                override fun onSample(isVideo: Boolean, sample: EncodedSample) {
                    recorder?.write(isVideo, sample)
                }
                override fun onError(message: String) = emitError(message)
            }, onLevel = { rms, peak ->
                emit(mapOf("type" to "level", "rms" to rms.toDouble(), "peak" to peak.toDouble()))
            }).also {
                it.gain = micGain
                it.start()
            }
        }
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startAudio()
        } else {
            pendingAudio = startAudio
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != MIC_REQUEST) return
        val start = pendingAudio
        pendingAudio = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            if (video != null) start?.invoke()
        } else {
            emitError("Microphone permission denied: streaming without audio")
        }
    }

    private fun stop() {
        pendingAudio = null
        stopRecording()
        audio?.stop()
        audio = null
        video?.stop()
        video = null
    }

    private fun startRecording(): String? {
        val v = video ?: throw IllegalStateException("Encoder is not running")
        val r = Mp4Recorder(
            activity,
            videoFormat = { video?.outputFormat },
            audioFormat = { audio?.outputFormat },
            audioExpected = { audio != null },
            requestKeyframe = { video?.requestKeyframe() },
        )
        recorder = r
        v.requestKeyframe()
        return r.displayPath
    }

    private fun stopRecording(): String? {
        val r = recorder ?: return null
        recorder = null
        return r.stop()
    }

    fun dispose() {
        stop()
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    companion object {
        private const val MIC_REQUEST = 4711
    }
}
