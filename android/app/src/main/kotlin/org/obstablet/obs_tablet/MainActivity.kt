package org.obstablet.obs_tablet

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var encoderPlugin: ObsEncoderPlugin? = null
    private var devicesPlugin: DevicesPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        encoderPlugin = ObsEncoderPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
        devicesPlugin = DevicesPlugin(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        encoderPlugin?.onRequestPermissionsResult(requestCode, grantResults)
    }

    @Deprecated("Needed for MediaProjection consent result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (encoderPlugin?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        encoderPlugin?.dispose()
        encoderPlugin = null
        devicesPlugin?.dispose()
        devicesPlugin = null
        super.onDestroy()
    }
}
