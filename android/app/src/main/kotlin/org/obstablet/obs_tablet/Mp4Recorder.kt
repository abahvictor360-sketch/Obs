package org.obstablet.obs_tablet

import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Writes encoder output to an MP4 with MediaMuxer, then publishes it to the
 * gallery (Movies/OBSpad). The muxer is started lazily on the first video
 * keyframe once the codec formats are known (MediaMuxer needs all tracks up
 * front), and timestamps are rebased so the file starts at 0.
 */
class Mp4Recorder(
    private val context: Context,
    private val videoFormat: () -> MediaFormat?,
    private val audioFormat: () -> MediaFormat?,
    private val audioExpected: () -> Boolean,
    private val requestKeyframe: () -> Unit,
) {
    private val name = "OBS " + SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.US).format(Date()) + ".mp4"
    private val file: File
    private lateinit var muxer: MediaMuxer
    private var videoTrack = -1
    private var audioTrack = -1
    private var startUs = -1L
    private val lock = Any()
    private var started = false
    private var stopped = false
    private var lastKeyRequestMs = 0L

    init {
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_MOVIES), "Recordings")
        dir.mkdirs()
        file = File(dir, name)
    }

    val displayPath: String get() = file.absolutePath

    private fun tryStart(): Boolean {
        val vf = videoFormat() ?: return false
        val af = audioFormat()
        if (af == null && audioExpected()) {
            // Audio encoder hasn't produced its format yet; ask for another
            // keyframe shortly so we don't wait a full GOP.
            val now = System.currentTimeMillis()
            if (now - lastKeyRequestMs > 300) {
                lastKeyRequestMs = now
                requestKeyframe()
            }
            return false
        }
        muxer = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        videoTrack = muxer.addTrack(vf)
        if (af != null) audioTrack = muxer.addTrack(af)
        muxer.start()
        started = true
        return true
    }

    fun write(isVideo: Boolean, sample: EncodedSample) {
        synchronized(lock) {
            if (stopped) return
            if (startUs < 0) {
                // Begin on a video keyframe.
                if (!isVideo || sample.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME == 0) return
                if (!started && !tryStart()) return
                startUs = sample.ptsUs
            }
            val track = if (isVideo) videoTrack else audioTrack
            if (track < 0 || sample.ptsUs < startUs) return
            val info = MediaCodec.BufferInfo().apply {
                set(0, sample.data.size, sample.ptsUs - startUs, sample.flags)
            }
            try {
                muxer.writeSampleData(track, ByteBuffer.wrap(sample.data), info)
            } catch (_: Exception) {
            }
        }
    }

    /** Finishes the file and returns where the user can find it. */
    fun stop(): String {
        synchronized(lock) {
            stopped = true
            if (!started) return file.absolutePath
            started = false
            try {
                muxer.stop()
            } catch (_: Exception) {
                // Thrown if nothing was written (stopped before the first keyframe).
            }
            muxer.release()
        }
        return publishToGallery() ?: file.absolutePath
    }

    private fun publishToGallery(): String? {
        if (!file.exists() || file.length() == 0L) return null
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, name)
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/OBSpad")
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                }
                val resolver = context.contentResolver
                val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return null
                resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                values.clear()
                values.put(MediaStore.Video.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                file.delete()
                "Movies/OBSpad/$name"
            } else {
                MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), arrayOf("video/mp4"), null)
                file.absolutePath
            }
        } catch (_: Exception) {
            null
        }
    }
}
