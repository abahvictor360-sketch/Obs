package org.obstablet.obs_tablet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var encoderPlugin: ObsEncoderPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        encoderPlugin = ObsEncoderPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        encoderPlugin?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        encoderPlugin?.dispose()
        encoderPlugin = null
        super.onDestroy()
    }
}
