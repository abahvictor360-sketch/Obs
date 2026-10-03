package org.obstablet.obs_tablet

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Whole-device screen capture with MediaProjection.
 *
 * Frames land in an ImageReader and are copied into a double-buffered Bitmap
 * that the video compositor draws between the overlay layers. Everything
 * runs inside [ScreenCaptureService] (a foreground service), so capture and
 * streaming continue while the user is in another app.
 */
object ScreenCapture {
    /** Long side of the captured image; plenty for a 720p/1080p output. */
    private const val MAX_SIDE = 1280

    /** Guards [front] while the compositor draws it. */
    val lock = Any()

    private var front: Bitmap? = null
    private var back: Bitmap? = null
    var frameWidth = 0
        private set
    var frameHeight = 0
        private set

    @Volatile var projection: MediaProjection? = null
        private set
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    /** (active, width, height, error) */
    @Volatile var stateListener: ((Boolean, Int, Int, String?) -> Unit)? = null

    val isActive: Boolean get() = projection != null

    fun requestIntent(context: Context): Intent =
        (context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager)
            .createScreenCaptureIntent()

    /** Called with the result of the system consent dialog. */
    fun start(context: Context, resultCode: Int, data: Intent) {
        val intent = Intent(context, ScreenCaptureService::class.java)
            .putExtra(ScreenCaptureService.EXTRA_CODE, resultCode)
            .putExtra(ScreenCaptureService.EXTRA_DATA, data)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stop(context: Context) {
        context.stopService(Intent(context, ScreenCaptureService::class.java))
    }

    /** Runs [block] with the latest frame while holding [lock]. */
    inline fun withLatest(block: (Bitmap, Int, Int) -> Unit) {
        synchronized(lock) {
            val f = frontBitmap() ?: return
            block(f, frameWidth, frameHeight)
        }
    }

    fun frontBitmap(): Bitmap? = front

    internal fun attach(service: Service, resultCode: Int, data: Intent) {
        try {
            val mpm = service.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val p = mpm.getMediaProjection(resultCode, data)
                ?: throw IllegalStateException("Permission was not granted")
            val t = HandlerThread("obs-screen").also { it.start() }
            thread = t
            handler = Handler(t.looper)
            // Required before createVirtualDisplay on Android 14+.
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    // The user revoked capture from the system UI.
                    stop(service)
                }
            }, handler)
            projection = p
            createDisplay(service)
        } catch (e: Exception) {
            stateListener?.invoke(false, 0, 0, "Screen capture failed: ${e.message}")
            service.stopSelf()
        }
    }

    private fun captureSize(context: Context): Triple<Int, Int, Int> {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val w: Int
        val h: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.maximumWindowMetrics.bounds
            w = b.width()
            h = b.height()
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(m)
            w = m.widthPixels
            h = m.heightPixels
        }
        val scale = minOf(1f, MAX_SIDE.toFloat() / max(w, h))
        // Even sizes keep some GPU drivers happy.
        val sw = ((w * scale).roundToInt() / 2) * 2
        val sh = ((h * scale).roundToInt() / 2) * 2
        return Triple(sw, sh, context.resources.displayMetrics.densityDpi)
    }

    private fun createDisplay(context: Context) {
        val p = projection ?: return
        val (w, h, dpi) = captureSize(context)
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        r.setOnImageAvailableListener({ onImage(it) }, handler)
        val old = reader
        reader = r
        val d = display
        if (d == null) {
            display = p.createVirtualDisplay(
                "OBS Tablet screen", w, h, dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                r.surface, null, handler,
            )
        } else {
            // Rotation: resize the existing display (a projection may only
            // create one display on Android 14+).
            d.resize(w, h, dpi)
            d.surface = r.surface
        }
        old?.close()
        stateListener?.invoke(true, w, h, null)
    }

    /** Device rotated: match the new screen shape. */
    internal fun onConfigurationChanged(context: Context) {
        handler?.post { if (projection != null) createDisplay(context) }
    }

    private fun onImage(r: ImageReader) {
        val image = try {
            r.acquireLatestImage()
        } catch (_: Exception) {
            null
        } ?: return
        try {
            val plane = image.planes[0]
            // Rows may be padded: the bitmap is as wide as the row stride and
            // the compositor only draws the first frameWidth columns.
            val strideW = plane.rowStride / plane.pixelStride
            val h = image.height
            var b = back
            if (b == null || b.width != strideW || b.height != h) {
                b?.recycle()
                b = Bitmap.createBitmap(strideW, h, Bitmap.Config.ARGB_8888)
            }
            b!!.copyPixelsFromBuffer(plane.buffer)
            synchronized(lock) {
                back = front
                front = b
                frameWidth = image.width
                frameHeight = h
            }
        } catch (_: Exception) {
        } finally {
            image.close()
        }
    }

    internal fun detach() {
        display?.release()
        display = null
        reader?.close()
        reader = null
        projection?.stop()
        projection = null
        thread?.quitSafely()
        thread = null
        handler = null
        synchronized(lock) {
            front?.recycle()
            back?.recycle()
            front = null
            back = null
            frameWidth = 0
            frameHeight = 0
        }
        stateListener?.invoke(false, 0, 0, null)
    }
}

/**
 * Foreground service that owns the MediaProjection. Android requires one for
 * screen capture, and it also keeps the microphone and the stream alive while
 * another app is in front.
 */
class ScreenCaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        val data: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_DATA)
        }
        if (data == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
            ) {
                // Keeps the microphone working while another app is in front.
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (ScreenCapture.projection == null) ScreenCapture.attach(this, code, data)
        return START_NOT_STICKY
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        ScreenCapture.onConfigurationChanged(this)
    }

    override fun onDestroy() {
        ScreenCapture.detach()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen capture", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("OBS Tablet is capturing your screen")
            .setContentText("Tap to return to the studio")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val CHANNEL_ID = "screen_capture"
        private const val NOTIFICATION_ID = 7
    }
}
