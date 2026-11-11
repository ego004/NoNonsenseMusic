package dev.nononsense.nononsense

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// audio_service's activity: it shares one Flutter engine with the playback service (lib/core/media_controls.dart)
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // in-place updates (lib/core/update_check.dart): a downloaded APK, its signature already checked, handed to
        // Android's installer, which asks first. Android installs it over this app only when it is signed with the
        // same key. The first time, Android needs permission to install from this app: its page opens instead
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nononsense/update").setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            if (call.method == "allowed") {
                result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls())
            } else if (call.method == "settings") {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                result.success(null)
            } else if (call.method != "install" || path == null) {
                result.notImplemented()
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                result.success("permission")
            } else {
                val apk = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
                startActivity(Intent(Intent.ACTION_VIEW)
                    .setDataAndType(apk, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success("installer")
            }
        }
    }
}
