package dev.nononsense.nononsense

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Receives every press on the home-screen widget. While the app runs, the press goes to it on the
 * `nononsense/widget` channel (HomeScreenWidget in lib/core/home_screen_widget.dart); otherwise the app is started
 * with `nononsense://widget/<press>`, which it runs once signed in.
 */
class WidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val press = intent.getStringExtra(EXTRA_PRESS) ?: return
        val engine = FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId())
        if (engine == null) {
            // The app stopped since the widget was drawn: open it with the press (Android may refuse that from the
            // background), and redraw the widget so its buttons open the app directly from now on.
            open(context, press)
            return NowPlayingWidget.redraw(context)
        }
        val pending = goAsync()
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).invokeMethod("press", press, object : MethodChannel.Result {
            override fun success(result: Any?) = pending.finish()
            override fun error(code: String, message: String?, details: Any?) = pending.finish()
            // The engine is there but its Dart side has not started listening yet: start the app with the press.
            override fun notImplemented() {
                open(context, press)
                pending.finish()
            }
        })
    }

    private fun open(context: Context, press: String) {
        try {
            context.startActivity(openIntent(context, press).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            // refused from the background: the redrawn widget's next press opens the app itself
        }
    }

    companion object {
        const val CHANNEL = "nononsense/widget"
        const val EXTRA_PRESS = "press"

        /** `next` as a link: `nononsense://widget/next`. */
        fun openIntent(context: Context, press: String?): Intent {
            val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW)
            if (press != null) intent.data = Uri.parse("nononsense://widget/" + Uri.encode(press))
            return intent
        }

        /** The press as a broadcast to this receiver; [code] keeps each button's PendingIntent distinct. */
        fun pressIntent(context: Context, press: String, code: Int): PendingIntent = PendingIntent.getBroadcast(
            context,
            code,
            Intent(context, WidgetActionReceiver::class.java).putExtra(EXTRA_PRESS, press),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        /** Opens the app, with no press. */
        fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            openIntent(context, null).setAction(Intent.ACTION_MAIN),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
