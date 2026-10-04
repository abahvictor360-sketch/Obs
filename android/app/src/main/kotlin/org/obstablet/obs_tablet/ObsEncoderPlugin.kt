package org.obstablet.obs_tablet

import android.Manifest
import android.app.Activity
import android.content.Intent
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
 *   setMicGain(gain), startRecording -> path, stopRecording -> path,
 *   setMetering(enabled): mic levels while no output runs
 *   setOutputMetering(enabled): level of what the tablet plays
 *
 * Events (channel "obs_tablet/encoder_events"), all maps with a "type":
 *   packet {kind: video|audio, config, key, pts (us), data}
 *   level  {rms, peak, source: mic|output}
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
    private var meter: MicMeter? = null
    private var meterWanted = false
    private var meterAsked = false
    private var outputMeter: OutputMeter? = null
    private var outputMeterWanted = false

    @Volatile private var appAudioGain = 1.0f
    @Volatile private var pcmTapEnabled = false
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

    private val pcmTap: (FloatArray, Int, Int) -> Unit = { samples, rate, channels ->
        val bytes = java.nio.ByteBuffer.allocate(samples.size * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        bytes.asFloatBuffer().put(samples)
        emit(mapOf("type" to "pcm", "data" to bytes.array(), "sampleRate" to rate, "channels" to channels))
    }

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
        ScreenCapture.stateListener = { active, w, h, error ->
            val e = mutableMapOf<String, Any>(
                "type" to "screen",
                "state" to if (active) "active" else "stopped",
                "width" to w,
                "height" to h,
            )
            if (error != null) e["error"] = error
            emit(e)
        }
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
                    updateMeter()
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
                    meter?.gain = micGain
                    result.success(null)
                }
                "setMetering" -> {
                    meterWanted = call.argument<Boolean>("enabled") ?: false
                    updateMeter()
                    result.success(null)
                }
                "setLiveOutput" -> {
                    OutputService.set(activity.applicationContext, call.argument<String>("text"))
                    result.success(null)
                }
                "setMicProcessing" -> {
                    MicProcessing.configure(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                    result.success(null)
                }
                "setOutputMetering" -> {
                    outputMeterWanted = call.argument<Boolean>("enabled") ?: false
                    updateOutputMeter()
                    result.success(null)
                }
                "setScreenAudioGain" -> {
                    appAudioGain = (call.argument<Double>("gain") ?: 1.0).toFloat()
                    audio?.appGain = appAudioGain
                    result.success(null)
                }
                "setPcmTap" -> {
                    pcmTapEnabled = call.argument<Boolean>("enabled") ?: false
                    audio?.pcmTap = if (pcmTapEnabled) pcmTap else null
                    setNdiNetworking(pcmTapEnabled)
                    result.success(null)
                }
                "isScreenCaptureSupported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                "startScreenCapture" -> {
                    if (!ScreenCapture.isActive) {
                        @Suppress("DEPRECATION")
                        activity.startActivityForResult(ScreenCapture.requestIntent(activity), SCREEN_REQUEST)
                    }
                    result.success(null)
                }
                "stopScreenCapture" -> {
                    ScreenCapture.stop(activity)
                    result.success(null)
                }
                "overlays" -> {
                    val v = video
                    if (v == null) {
                        result.success(null)
                    } else {
                        v.setOverlays(
                            call.argument<ByteArray>("under"),
                            call.argument<ByteArray>("over"),
                            call.argument<Boolean>("clearOver") ?: false,
                            call.argument<Int>("width") ?: 0,
                            call.argument<Int>("height") ?: 0,
                            Placement.from(call.argument<Map<*, *>>("placement")),
                        ) { main.post { result.success(null) } }
                    }
                }
                "startRecording" -> result.success(startRecording())
                "stopRecording" -> {
                    // Finishing copies the file into the gallery: not on the UI thread.
                    val r = recorder
                    recorder = null
                    Thread({
                        val path = try { r?.stop() } catch (_: Exception) { null }
                        main.post { result.success(path) }
                    }, "obs-mp4-finish").start()
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("encoder", e.message ?: e.toString(), null)
        }
    }

    private var pendingAudio: (() -> Unit)? = null

    private fun start(call: MethodCall) {
        stop()
        stopMeter() // the encoder takes over the microphone and the levels
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
                it.appGain = appAudioGain
                if (pcmTapEnabled) it.pcmTap = pcmTap
                it.start()
            }
        }
        if (micGranted()) {
            startAudio()
        } else {
            pendingAudio = startAudio
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
        }
    }

    /**
     * NDI discovery uses mDNS: Android needs the NSD service referenced and a
     * Wi-Fi multicast lock while NDI output runs.
     */
    private fun setNdiNetworking(on: Boolean) {
        if (on) {
            activity.getSystemService(android.content.Context.NSD_SERVICE)
            if (multicastLock == null) {
                val wifi = activity.applicationContext.getSystemService(android.content.Context.WIFI_SERVICE)
                    as android.net.wifi.WifiManager
                multicastLock = wifi.createMulticastLock("obspad-ndi").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } else {
            multicastLock?.release()
            multicastLock = null
        }
    }

    /** Result of the system "start recording your screen?" dialog. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SCREEN_REQUEST) return false
        if (resultCode == Activity.RESULT_OK && data != null) {
            ScreenCapture.start(activity, resultCode, data)
        } else {
            emit(mapOf("type" to "screen", "state" to "stopped", "error" to "Screen capture permission was denied"))
        }
        return true
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != MIC_REQUEST) return
        val start = pendingAudio
        pendingAudio = null
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            if (video != null) start?.invoke() else updateMeter()
            updateOutputMeter()
        } else if (start != null) {
            emitError("Microphone permission denied: streaming without audio")
        }
    }

    private fun micGranted() =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** Runs the [MicMeter] while it's wanted and no encoder uses the microphone. */
    private fun updateMeter() {
        val run = meterWanted && video == null && audio == null
        if (!run) {
            stopMeter()
            return
        }
        if (meter != null) return
        if (!micGranted()) {
            // Ask once; afterwards the meter starts when permission is given.
            if (!meterAsked) {
                meterAsked = true
                activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
            }
            return
        }
        meter = MicMeter { rms, peak ->
            emit(mapOf("type" to "level", "rms" to rms.toDouble(), "peak" to peak.toDouble()))
        }.also {
            it.gain = micGain
            it.start()
        }
    }

    /** The Visualizer needs the microphone permission too. */
    private fun updateOutputMeter() {
        if (outputMeterWanted && !micGranted() && !meterAsked) {
            meterAsked = true
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
        }
        if (!outputMeterWanted || !micGranted()) {
            outputMeter?.stop()
            outputMeter = null
            return
        }
        if (outputMeter != null) return
        val m = OutputMeter { rms, peak ->
            emit(mapOf("type" to "level", "source" to "output", "rms" to rms.toDouble(), "peak" to peak.toDouble()))
        }
        if (m.start()) outputMeter = m
    }

    private fun stopMeter() {
        meter?.stop()
        meter = null
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

    private fun stopRecording() {
        val r = recorder ?: return
        recorder = null
        Thread({ try { r.stop() } catch (_: Exception) {} }, "obs-mp4-finish").start()
    }

    fun dispose() {
        OutputService.set(activity.applicationContext, null)
        stop()
        stopMeter()
        outputMeter?.stop()
        outputMeter = null
        ScreenCapture.stateListener = null
        setNdiNetworking(false)
        ScreenCapture.stop(activity)
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    companion object {
        private const val MIC_REQUEST = 4711
        private const val SCREEN_REQUEST = 4712
    }
}
