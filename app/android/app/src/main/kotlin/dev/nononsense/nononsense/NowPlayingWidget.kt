package dev.nononsense.nononsense

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.ryanheise.audioservice.AudioServicePlugin
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import io.flutter.embedding.engine.FlutterEngineCache
import org.json.JSONObject

/**
 * The home-screen widget: the cover, the song, like, and previous / play / next; from the medium size also back and
 * forward ten seconds, and at the large size the cover large with a button that opens the app. It draws what the app
 * stored (HomeScreenWidget in lib/core/home_screen_widget.dart) and has no timer of its own: the app redraws it when
 * something changes.
 */
class NowPlayingWidget : HomeWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val state = WidgetState.read(widgetData)
        for (id in appWidgetIds) appWidgetManager.updateAppWidget(id, views(context, state, appWidgetManager.getAppWidgetOptions(id)))
    }

    override fun onAppWidgetOptionsChanged(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        appWidgetManager.updateAppWidget(appWidgetId, views(context, WidgetState.read(HomeWidgetPlugin.getData(context)), newOptions))
    }

    private fun views(context: Context, state: WidgetState, options: Bundle): RemoteViews {
        if (!state.signedIn) return signedOut(context)
        night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val cover = state.cover?.let { decodeCover(it) }
        val small = build(context, state, R.layout.widget_small, cover)
        val medium = build(context, state, R.layout.widget_medium, cover)
        val large = build(context, state, R.layout.widget_large, cover)
        // Android 12 picks the layout for each size the launcher shows the widget at.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return RemoteViews(mapOf(SizeF(110f, 110f) to small, SizeF(250f, 110f) to medium, SizeF(250f, 260f) to large))
        }
        val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
        return when {
            width < 250 -> small
            height < 260 -> medium
            else -> large
        }
    }

    private fun build(context: Context, s: WidgetState, layout: Int, cover: Bitmap?): RemoteViews {
        val v = RemoteViews(context.packageName, layout)
        val press = Presses(context)
        val open = WidgetActionReceiver.openApp(context)
        v.setOnClickPendingIntent(R.id.widget_root, open)
        if (cover != null) v.setImageViewBitmap(R.id.cover, cover) else v.setImageViewResource(R.id.cover, R.drawable.widget_no_cover)
        v.setOnClickPendingIntent(R.id.cover, open)
        if (layout == R.layout.widget_large) v.setOnClickPendingIntent(R.id.bookmark, open)

        v.setTextViewText(R.id.title, s.title ?: context.getString(R.string.widget_nothing_played))
        // "Artist • Album", either alone when the other is unknown
        val line = listOfNotNull(s.artist, s.album).filter { it.isNotEmpty() }.joinToString(" • ")
        v.setTextViewText(R.id.artist, if (s.resume) context.getString(R.string.widget_resume, line) else line)

        v.setOnClickPendingIntent(R.id.play, press("toggle", 1))
        v.setImageViewResource(R.id.play, if (s.playing) R.drawable.widget_pause else R.drawable.widget_play)
        // in the ink, set each time: a launcher may reuse a view an older widget tinted
        tint(v, R.id.play, Accent.ink(context, false), Accent.ink(context, true))
        v.setContentDescription(R.id.play, context.getString(if (s.playing) R.string.widget_pause else R.string.widget_play))
        v.setBoolean(R.id.play, "setEnabled", s.title != null)

        // Like and the skips are for the song that is loaded; the song offered to resume is not loaded yet.
        val loaded = s.title != null && !s.resume
        val skips = mutableListOf(Triple(R.id.prev, "previous", 2), Triple(R.id.next, "next", 3))
        if (layout != R.layout.widget_small) skips += listOf(Triple(R.id.back10, "back10", 5), Triple(R.id.forward10, "forward10", 6))
        for ((id, name, code) in skips) {
            v.setOnClickPendingIntent(id, press(name, code))
            v.setViewVisibility(id, if (loaded) View.VISIBLE else View.INVISIBLE)
        }

        v.setViewVisibility(R.id.like, if (loaded) View.VISIBLE else View.INVISIBLE)
        v.setImageViewResource(R.id.like, if (s.liked) R.drawable.widget_heart else R.drawable.widget_heart_outline)
        // a liked heart in the song's accent, an empty one in the ink; set each time, since a launcher may reuse the view
        val accent = s.accent ?: Accent.fallback(context)
        if (s.liked) tint(v, R.id.like, accent.light, accent.dark) else tint(v, R.id.like, Accent.ink(context, false), Accent.ink(context, true))
        v.setContentDescription(R.id.like, context.getString(if (s.liked) R.string.widget_unlike else R.string.widget_like))
        v.setOnClickPendingIntent(R.id.like, press("like", 4))
        return v
    }

    /**
     * Colours an image: [light] or [dark] after the phone's theme. Android 12 lets the launcher choose as the theme
     * changes; before it, the colour is picked now, and the next redraw follows a change of theme.
     */
    private fun tint(v: RemoteViews, id: Int, light: Int, dark: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            v.setColorInt(id, "setColorFilter", light, dark)
        } else {
            v.setInt(id, "setColorFilter", if (night) dark else light)
        }
    }

    private var night = false

    private fun signedOut(context: Context) = RemoteViews(context.packageName, R.layout.widget_signed_out).apply {
        setOnClickPendingIntent(R.id.widget_root, WidgetActionReceiver.openApp(context))
    }

    /**
     * Each button's intent. While the app runs, a press is a broadcast that the app handles without coming to the
     * front. Otherwise it opens the app with the press: Android may refuse an activity start from a broadcast while
     * the app is in the background, so the widget asks for the activity directly. The app redraws the widget once it
     * runs, which switches the buttons back to broadcasts.
     */
    private class Presses(private val context: Context) {
        private val running = FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId()) != null

        operator fun invoke(press: String, code: Int): PendingIntent = if (running) {
            WidgetActionReceiver.pressIntent(context, press, code)
        } else {
            PendingIntent.getActivity(context, code, WidgetActionReceiver.openIntent(context, press), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }

    /** The cover, shrunk to at most [COVER_PX]: a widget's views travel to the launcher, which limits their size. */
    private fun decodeCover(path: String): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= COVER_PX && bounds.outHeight / (sample * 2) >= COVER_PX) sample *= 2
        BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
    } catch (_: Exception) {
        null
    }

    companion object {
        private const val COVER_PX = 256

        /** Redraws every placed widget from the stored state. */
        fun redraw(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, NowPlayingWidget::class.java))
            if (ids.isEmpty()) return
            context.sendBroadcast(Intent(context, NowPlayingWidget::class.java).setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE).putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids))
        }
    }
}

/** The song's accent on each theme (the app's Accent.readable, buildTheme): a liked heart takes it. */
data class Accent(val light: Int, val dark: Int) {
    companion object {
        /** Windows 11's default accent from colors.xml, for a song with a grey cover or none. */
        fun fallback(context: Context) = Accent(themed(context, false, R.color.widget_accent), themed(context, true, R.color.widget_accent))

        fun ink(context: Context, night: Boolean) = themed(context, night, R.color.widget_ink)

        /** A colour from the light or the dark resources, whichever theme the phone has now. */
        private fun themed(context: Context, night: Boolean, id: Int): Int {
            val config = Configuration(context.resources.configuration)
            config.uiMode = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                (if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO)
            return context.createConfigurationContext(config).getColor(id)
        }
    }
}

/** The state the app stored under `state`: see HomeWidgetState.of in lib/core/home_screen_widget.dart. */
data class WidgetState(
    val signedIn: Boolean,
    val title: String?,
    val artist: String?,
    val album: String?,
    val cover: String?,
    val playing: Boolean,
    val liked: Boolean,
    val resume: Boolean,
    val accent: Accent?, // null: the default blue
) {
    companion object {
        private val SIGNED_OUT = WidgetState(false, null, null, null, null, false, false, false, null)

        fun read(prefs: SharedPreferences): WidgetState {
            val json = prefs.getString("state", null) ?: return SIGNED_OUT
            return try {
                val j = JSONObject(json)
                if (!j.optBoolean("signedIn")) return SIGNED_OUT
                fun text(k: String) = if (j.isNull(k)) null else j.optString(k)
                WidgetState(
                    signedIn = true,
                    title = text("title"),
                    artist = text("artist"),
                    album = text("album"),
                    cover = text("cover"),
                    playing = j.optBoolean("playing"),
                    liked = j.optBoolean("liked"),
                    resume = j.optBoolean("resume"),
                    // ARGB as Dart's toARGB32: a JSON number past Int's range, read as Long and cut to its 32 bits
                    accent = j.optJSONObject("accent")?.let { a -> Accent(a.getLong("light").toInt(), a.getLong("dark").toInt()) },
                )
            } catch (_: Exception) {
                SIGNED_OUT
            }
        }
    }
}
