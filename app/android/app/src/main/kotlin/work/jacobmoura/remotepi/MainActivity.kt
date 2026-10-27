package work.jacobmoura.remotepi

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var artifacts: ArtifactViewer? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        artifacts = ArtifactViewer(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai.weisslabs.remotepi/artifacts")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "preview" -> artifacts!!.open(call.argument<ByteArray>("bytes"), call.argument<String>("extension"), result)
                    "dismiss" -> { artifacts?.dismiss(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }
    override fun onDestroy() {
        artifacts?.dismiss()
        super.onDestroy()
    }
}
