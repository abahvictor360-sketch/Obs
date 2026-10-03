package org.obstablet.obs_tablet

import android.app.Activity
import android.content.Context
import android.hardware.usb.UsbDevice
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecord
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.herohan.uvcapp.CameraHelper
import com.herohan.uvcapp.ICameraHelper
import com.serenegiant.utils.UVCUtils
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Hardware connected over USB OTG (and the network it runs on):
 *  - USB video (UVC capture cards / webcams) rendered into a Flutter texture,
 *  - audio input selection (USB mics and interfaces),
 *  - wired vs Wi-Fi vs cellular status, and "prefer wired" routing,
 *  - docking stations and connected screens ([DockMonitor]).
 *
 * Channel "obs_tablet/devices", events on "obs_tablet/device_events".
 */
class DevicesPlugin(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val method = MethodChannel(messenger, "obs_tablet/devices")
    private val events = EventChannel(messenger, "obs_tablet/device_events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        emitNetwork()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(e: Map<String, Any?>) {
        main.post { sink?.success(e) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listUsbCameras" -> result.success(usbCameras())
                "openUsbCamera" -> openUsbCamera(call.argument<String>("id"), result)
                "closeUsbCamera" -> {
                    closeUsbCamera()
                    result.success(null)
                }
                "listAudioInputs" -> result.success(audioInputs())
                "setAudioInput" -> {
                    AudioRouting.setPreferred(audioManager, call.argument<String>("id"))
                    result.success(null)
                }
                "getNetwork" -> result.success(networkState())
                "getDock" -> result.success(dock?.state())
                "setDisplayMode" -> result.success(dock?.setMode(call.argument<String>("mode") ?: "program"))
                "setPreferWired" -> {
                    preferWired = call.argument<Boolean>("enabled") ?: false
                    applyRouting()
                    result.success(networkState())
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("devices", e.message ?: e.toString(), null)
        }
    }

    // ---------------------------------------------------------------------------------------
    // USB video (UVC)

    private var camera: CameraHelper? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var openDevice: UsbDevice? = null
    private var pendingOpen: MethodChannel.Result? = null

    private fun helper(): CameraHelper = camera ?: CameraHelper().also { h ->
        h.setStateCallback(object : ICameraHelper.StateCallback {
            override fun onAttach(device: UsbDevice) {
                dock?.changed()
                emit(mapOf("type" to "usbVideo", "state" to "attached", "id" to device.deviceName, "name" to label(device)))
            }

            override fun onDeviceOpen(device: UsbDevice, isFirstOpen: Boolean) {
                h.openCamera()
            }

            override fun onCameraOpen(device: UsbDevice) {
                h.startPreview()
                val size = h.previewSize
                val w = size?.width ?: 1280
                val hgt = size?.height ?: 720
                val p = producer ?: textures.createSurfaceProducer().also { producer = it }
                p.setSize(w, hgt)
                p.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        h.addSurface(p.surface, false)
                    }

                    override fun onSurfaceCleanup() {
                        h.removeSurface(p.surface)
                    }
                })
                h.addSurface(p.surface, false)
                openDevice = device
                val info = mapOf("textureId" to p.id(), "width" to w, "height" to hgt, "id" to device.deviceName)
                pendingOpen?.success(info)
                pendingOpen = null
                emit(mapOf("type" to "usbVideo", "state" to "opened") + info)
            }

            override fun onCameraClose(device: UsbDevice) {
                producer?.let { h.removeSurface(it.surface) }
                emit(mapOf("type" to "usbVideo", "state" to "closed", "id" to device.deviceName))
            }

            override fun onDeviceClose(device: UsbDevice) {}

            override fun onDetach(device: UsbDevice) {
                dock?.changed()
                if (openDevice?.deviceName == device.deviceName) {
                    openDevice = null
                    releaseTexture()
                }
                emit(mapOf("type" to "usbVideo", "state" to "detached", "id" to device.deviceName))
            }

            override fun onCancel(device: UsbDevice) {
                pendingOpen?.error("usb", "USB permission was denied", null)
                pendingOpen = null
            }

            override fun onError(device: UsbDevice, e: com.herohan.uvcapp.CameraException) {
                pendingOpen?.error("usb", e.message ?: "USB camera error", null)
                pendingOpen = null
                emit(mapOf("type" to "usbVideo", "state" to "error", "id" to device.deviceName, "message" to (e.message ?: "")))
            }
        })
        camera = h
    }

    private fun label(d: UsbDevice): String =
        listOfNotNull(d.manufacturerName, d.productName).joinToString(" ").ifBlank { "USB video device" }

    private fun usbCameras(): List<Map<String, Any>> = helper().deviceList.map {
        mapOf("id" to it.deviceName, "name" to label(it), "vendorId" to it.vendorId, "productId" to it.productId)
    }

    private fun openUsbCamera(id: String?, result: MethodChannel.Result) {
        val h = helper()
        val devices = h.deviceList
        val device = devices.firstOrNull { it.deviceName == id } ?: devices.firstOrNull()
        if (device == null) {
            result.error("usb", "No USB video device connected", null)
            return
        }
        val p = producer
        if (openDevice?.deviceName == device.deviceName && h.isCameraOpened && p != null) {
            result.success(mapOf("textureId" to p.id(), "width" to p.width, "height" to p.height, "id" to device.deviceName))
            return
        }
        pendingOpen?.error("usb", "Superseded", null)
        pendingOpen = result
        // Asks for USB permission if needed, then onDeviceOpen -> onCameraOpen.
        h.selectDevice(device)
    }

    private fun closeUsbCamera() {
        camera?.closeCamera()
        openDevice = null
        releaseTexture()
    }

    private fun releaseTexture() {
        producer?.release()
        producer = null
    }

    // ---------------------------------------------------------------------------------------
    // Audio inputs

    private val audioManager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private val audioCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = emitAudio()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = emitAudio()
    }

    private fun emitAudio() {
        emit(mapOf("type" to "audioInputs", "inputs" to audioInputs()))
        dock?.changed()
    }

    private fun usbAudioConnected(): Boolean =
        audioManager.getDevices(AudioManager.GET_DEVICES_ALL).any {
            it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_USB_ACCESSORY || it.type == AudioDeviceInfo.TYPE_HDMI
        }

    private fun audioInputs(): List<Map<String, Any>> =
        audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .filter { it.isSource && it.type != AudioDeviceInfo.TYPE_TELEPHONY && it.type != AudioDeviceInfo.TYPE_FM_TUNER }
            .map {
                mapOf(
                    "id" to it.id.toString(),
                    "name" to it.productName.toString().ifBlank { "Microphone" },
                    "type" to when (it.type) {
                        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET,
                        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth"
                        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "headset"
                        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtin"
                        else -> "other"
                    },
                )
            }

    // ---------------------------------------------------------------------------------------
    // Network (wired Ethernet over a USB adapter, Wi-Fi, cellular)

    private val connectivity = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var ethernet: Network? = null
    private var preferWired = false

    private val defaultCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = emitNetwork()
        override fun onLost(network: Network) = emitNetwork()
    }

    private val ethernetCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            main.post {
                ethernet = network
                applyRouting()
                emitNetwork()
                dock?.changed()
            }
        }

        override fun onLost(network: Network) {
            main.post {
                if (ethernet == network) ethernet = null
                applyRouting()
                emitNetwork()
                dock?.changed()
            }
        }
    }

    private fun startNetworkMonitoring() {
        // Handler-less variants: available on API 24 (callbacks post to main via emit).
        connectivity.registerDefaultNetworkCallback(defaultCallback)
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.registerNetworkCallback(req, ethernetCallback)
    }

    /** "Prefer wired": route this app's traffic (incl. RTMP) over Ethernet. */
    private fun applyRouting() {
        connectivity.bindProcessToNetwork(if (preferWired) ethernet else null)
    }

    private fun networkState(): Map<String, Any?> {
        val active = connectivity.boundNetworkForProcess ?: connectivity.activeNetwork
        val caps = active?.let { connectivity.getNetworkCapabilities(it) }
        val transport = when {
            caps == null -> "none"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
        return mapOf(
            "transport" to transport,
            "wiredAvailable" to (ethernet != null),
            "preferWired" to preferWired,
            "canPreferWired" to true,
            "downKbps" to (caps?.linkDownstreamBandwidthKbps ?: 0),
            "upKbps" to (caps?.linkUpstreamBandwidthKbps ?: 0),
        )
    }

    private fun emitNetwork() = emit(mapOf("type" to "network") + networkState())

    // ---------------------------------------------------------------------------------------
    // Docking station / connected screen

    private var dock: DockMonitor? = null

    // Runs after all properties above are initialized.
    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
        UVCUtils.init(activity.application)
        audioManager.registerAudioDeviceCallback(audioCallback, main)
        startNetworkMonitoring()
        dock = DockMonitor(activity, messenger, { ethernet != null }, ::usbAudioConnected, ::emit)
    }

    fun dispose() {
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
        audioManager.unregisterAudioDeviceCallback(audioCallback)
        try {
            connectivity.unregisterNetworkCallback(defaultCallback)
            connectivity.unregisterNetworkCallback(ethernetCallback)
        } catch (_: Exception) {
        }
        connectivity.bindProcessToNetwork(null)
        dock?.dispose()
        dock = null
        camera?.release()
        camera = null
        releaseTexture()
    }
}

/** Preferred microphone, applied to every AudioRecord the app creates. */
object AudioRouting {
    @Volatile private var preferred: AudioDeviceInfo? = null
    private val records = java.util.Collections.newSetFromMap(java.util.WeakHashMap<AudioRecord, Boolean>())

    fun setPreferred(am: AudioManager, id: String?) {
        preferred = am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id.toString() == id }
        synchronized(records) { records.forEach { it.preferredDevice = preferred } }
    }

    fun attach(record: AudioRecord) {
        record.preferredDevice = preferred
        synchronized(records) { records.add(record) }
    }
}
