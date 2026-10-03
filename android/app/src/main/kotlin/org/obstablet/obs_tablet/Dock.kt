package org.obstablet.obs_tablet

import android.app.Activity
import android.app.Presentation
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.hardware.display.DisplayManager
import android.hardware.usb.UsbManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Display
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.BinaryMessenger
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Docking stations and connected screens.
 *
 * Android has no "a dock is connected" signal for USB-C docks, so the dock is
 * recognised from what comes through it: an external display (DisplayPort alt
 * mode / HDMI), USB Ethernet, USB audio and video devices, and power.
 *
 * When a screen is connected and the mode is "program", the program is shown
 * full screen on it with a [Presentation] (like OBS's fullscreen projector);
 * frames come from Dart over "obs_tablet/display_frames". In "mirror" mode
 * the system mirrors the tablet as usual.
 */
class DockMonitor(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val ethernetConnected: () -> Boolean,
    private val usbAudioConnected: () -> Boolean,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val displays = activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val usb = activity.getSystemService(Context.USB_SERVICE) as UsbManager?
    private val frames = BasicMessageChannel(messenger, "obs_tablet/display_frames", BinaryCodec.INSTANCE_DIRECT)

    private var mode = "program"
    private var presentation: ProgramPresentation? = null
    private var charging = false

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = refresh()
        override fun onDisplayRemoved(displayId: Int) = refresh()
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != Display.DEFAULT_DISPLAY) refresh()
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_BATTERY_CHANGED) {
                val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
                if (plugged == charging) return
                charging = plugged
            }
            changed()
        }
    }

    /** First external screen that can show app content. */
    private fun externalDisplay(): Display? =
        displays.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
            .firstOrNull { it.displayId != Display.DEFAULT_DISPLAY && it.isValid }

    private fun usbVideoConnected(): Boolean = usb?.deviceList?.values?.any { d ->
        d.deviceClass == USB_CLASS_VIDEO || d.deviceClass == USB_CLASS_MISC ||
            (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == USB_CLASS_VIDEO }
    } ?: false

    fun state(): Map<String, Any?> {
        val d = externalDisplay()
        val display = d?.let {
            @Suppress("DEPRECATION")
            val size = android.graphics.Point().also { p -> it.getRealSize(p) }
            mapOf(
                "name" to it.name,
                "width" to size.x,
                "height" to size.y,
                "refreshRate" to it.refreshRate.toDouble(),
                "presenting" to (presentation?.display?.displayId == it.displayId && presentation?.isShowing == true),
            )
        }
        return mapOf(
            "display" to display,
            "ethernet" to ethernetConnected(),
            "usbAudio" to usbAudioConnected(),
            "usbVideo" to usbVideoConnected(),
            "usbDevices" to (usb?.deviceList?.size ?: 0),
            "charging" to charging,
        )
    }

    /** Something connected through the dock may have changed. */
    fun changed() {
        main.post { emit(mapOf("type" to "dock") + state()) }
    }

    fun setMode(m: String): Map<String, Any?> {
        mode = if (m == "mirror") "mirror" else "program"
        updatePresentation()
        return state()
    }

    private fun refresh() {
        updatePresentation()
        changed()
    }

    private fun updatePresentation() {
        val target = if (mode == "program" && !activity.isFinishing) externalDisplay() else null
        val current = presentation
        if (current != null && (target == null || current.display.displayId != target.displayId || !current.isShowing)) {
            current.dismissQuietly()
            presentation = null
        }
        if (target != null && presentation == null) {
            val p = ProgramPresentation(activity, target)
            try {
                p.show()
                presentation = p
            } catch (e: WindowManager.InvalidDisplayException) {
                presentation = null
            }
        }
    }

    private fun onFrame(msg: ByteBuffer?, reply: BasicMessageChannel.Reply<ByteBuffer>) {
        val p = presentation
        if (msg != null && p != null && msg.remaining() >= 8) {
            msg.order(ByteOrder.LITTLE_ENDIAN)
            val w = msg.getInt(0)
            val h = msg.getInt(4)
            if (w > 0 && h > 0 && msg.remaining() >= 8 + w * h * 4) {
                msg.position(8)
                // The buffer is only valid during this call: copy it now, draw later.
                p.renderer.submit(msg.slice(), w, h)
            }
        }
        reply.reply(null)
    }

    init {
        frames.setMessageHandler(::onFrame)
        displays.registerDisplayListener(displayListener, main)
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(Intent.ACTION_BATTERY_CHANGED)
        }
        val sticky = if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            activity.registerReceiver(receiver, filter)
        }
        charging = (sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        updatePresentation()
    }

    fun dispose() {
        frames.setMessageHandler(null)
        displays.unregisterDisplayListener(displayListener)
        try {
            activity.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        presentation?.dismissQuietly()
        presentation = null
    }

    companion object {
        const val USB_CLASS_VIDEO = 0x0E
        const val USB_CLASS_MISC = 0xEF // UVC devices often report "miscellaneous" (IAD)
    }
}

/** Full-screen program on the external display. */
class ProgramPresentation(context: Context, display: Display) : Presentation(context, display) {
    val renderer = FrameRenderer()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val view = SurfaceView(context)
        view.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = renderer.attach(holder)
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = renderer.attach(holder)
            override fun surfaceDestroyed(holder: SurfaceHolder) = renderer.detach()
        })
        setContentView(view)
    }

    fun dismissQuietly() {
        renderer.release()
        try {
            dismiss()
        } catch (_: Exception) {
        }
    }
}

/**
 * Draws RGBA frames letterboxed onto a surface on its own thread. Keeps two
 * bitmaps so a new frame can be copied in while the previous one is drawn.
 */
class FrameRenderer {
    private val thread = HandlerThread("obs-external-display").apply { start() }
    private val handler = Handler(thread.looper)
    private val lock = Any()
    private var holder: SurfaceHolder? = null
    private var back: Bitmap? = null
    private var front: Bitmap? = null
    private var pending = false
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)

    fun attach(h: SurfaceHolder) {
        synchronized(lock) { holder = h }
        handler.post { draw() }
    }

    fun detach() {
        synchronized(lock) { holder = null }
    }

    fun submit(rgba: ByteBuffer, w: Int, h: Int) {
        synchronized(lock) {
            if (pending) return // still drawing the last frame: drop this one
            var b = back
            if (b == null || b.width != w || b.height != h) {
                b?.recycle()
                b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                back = b
            }
            rgba.limit(rgba.position() + w * h * 4)
            b!!.copyPixelsFromBuffer(rgba)
            back = front
            front = b
            pending = true
        }
        handler.post { draw() }
    }

    private fun draw() {
        // Snapshot under the lock, draw outside it so the platform thread
        // never waits on a draw. [submit] doesn't touch [front] while a draw
        // is pending.
        val h: SurfaceHolder?
        val frame: Bitmap?
        synchronized(lock) {
            h = holder
            frame = front
        }
        try {
            val surface = h?.surface
            if (surface == null || !surface.isValid) return
            val canvas = try {
                surface.lockHardwareCanvas()
            } catch (_: Exception) {
                null
            } ?: return
            try {
                canvas.drawColor(Color.BLACK)
                if (frame != null && !frame.isRecycled) {
                    val dst = fitRect(
                        frame.width.toFloat(), frame.height.toFloat(),
                        RectF(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat()), "contain",
                    )
                    canvas.drawBitmap(frame, Rect(0, 0, frame.width, frame.height), dst, paint)
                }
            } finally {
                surface.unlockCanvasAndPost(canvas)
            }
        } finally {
            synchronized(lock) { pending = false }
        }
    }

    fun release() {
        synchronized(lock) { holder = null }
        handler.post {
            synchronized(lock) {
                back?.recycle()
                front?.recycle()
                back = null
                front = null
            }
            thread.quitSafely()
        }
    }
}
