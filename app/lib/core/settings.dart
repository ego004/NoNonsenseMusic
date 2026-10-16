import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'audio_cache.dart';
import 'auth.dart';
import 'lyrics.dart';
import 'models.dart';
import 'player.dart';
import 'translation.dart';

/// The window's background on Windows, drawn by Windows itself rather than by the app (no CPU of the app's), with the
/// app's panels as glass over it. Solid Dark and Solid Light set the theme too (themeFor).
enum WindowMaterial {
  glass('Glass', 'Translucent, your wallpaper blurred behind it. The default. On some PCs, dragging the window stutters.'),
  mica('Mica', 'A soft tint from your wallpaper. The lightest for the PC.'),
  acrylic('Acrylic', 'Semi-transparent with a deeper tint. On some PCs, dragging the window stutters.'),
  solidDark('Solid Dark', 'A plain dark window, in the dark theme.'),
  solidLight('Solid Light', 'A plain light window, in the light theme.'),
  clear('Clear', 'See-through with no blur: the most transparent.');

  final String label, note;
  const WindowMaterial(this.label, this.note);

  /// The theme this background sets, when it sets one: a solid window is one colour, light or dark.
  ThemeMode? get theme => switch (this) { solidDark => ThemeMode.dark, solidLight => ThemeMode.light, _ => null };
}

/// Holds every setting and keeps it between launches. A change applies at once.
class Settings extends ChangeNotifier {
  late SharedPreferences _p;
  String server = Api.base;
  WindowMaterial material = WindowMaterial.glass;

  /// Whether to play a song's explicit version when one exists.
  bool explicit = true;

  /// Settings › Playback › Preferred Source: "jiosaavn", "ytmusic" or "youtube"; empty is Automatic (the server's pick).
  String preferredSource = '';

  /// Up Next › Autoplay: when two songs or fewer are left, songs like the last one are added. On by default.
  bool autoplay = true;

  /// Settings › Playback › Autoplay: the server leaves out your last 50 played songs, skipped ones too. On by default.
  bool autoplaySkipsRecent = true;

  /// Settings › Check for updates: once per launch, GitHub is asked for the latest release (core/update_check.dart).
  bool checkUpdates = true;

  /// The release the user chose Skip This Version for: not offered again; a later one is.
  String? skippedUpdate;

  /// Lyrics › Translate: whether lyrics in another language show with their translation. Off by default and kept.
  bool translateLyrics = false;

  /// Settings › Lyrics › Translate into: one of [LyricsTranslations.languages], or '' (the default) for the device's
  /// language.
  String translateInto = '';

  /// The name this device shows in the user's list of signed-in devices.
  /// The user chooses it on the sign-in screen; it starts as the computer's name ([Auth.computerName]).
  String deviceName = Auth.computerName;

  /// Appearance: light, dark, or matching the system.
  ThemeMode theme = ThemeMode.system;

  /// The theme in use: a solid background's own (Solid Dark, Solid Light), else [theme].
  ThemeMode get themeShown => material.theme ?? theme;

  /// The size of all text, from 0.85 to 1.4, matching the Mac app's Text size.
  double textScale = 1;

  /// Whether lyrics are fetched when a song starts, and when the next one starts, or only when the panel opens.
  bool lyricsEarly = true;

  /// How long the lit line takes to reach the middle, in seconds; 0.9, the Mac app's default.
  double lyricsMotion = 0.9;

  /// Lyrics › Genius notes (experimental): off by default; one extra lookup per song when on.
  bool geniusNotes = false;

  /// Settings › Storage › Keep songs on this device: the audio cache's limit in MB, 0 is off.
  int audioCacheMB = AudioCache.defaultLimitMB;

  /// Settings › Appearance › Cover glow: the window takes a soft light from the playing song's cover (UI v2, 15 Oct).
  bool coverGlow = true;

  /// Settings › Storage › Download location: the folder the user chose for downloads, null for the app's own.
  String? downloadFolder;
  bool _loaded = false;

  /// Read the stored settings, using each default where a key is missing, then apply them.
  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    server = _address(_p.getString('server') ?? Api.defaultServer); // also mends one saved with a trailing "/" or no scheme
    // a saved 'solid' (before the six backgrounds, 15 Oct) is the dark one
    final saved = _p.getString('material');
    material = saved == 'solid' ? WindowMaterial.solidDark : WindowMaterial.values.asNameMap()[saved] ?? WindowMaterial.glass;
    explicit = _p.getBool('explicit') ?? true;
    preferredSource = _p.getString('preferredSource') ?? '';
    autoplay = _p.getBool('autoplay') ?? true;
    autoplaySkipsRecent = _p.getBool('autoplaySkipsRecent') ?? true;
    checkUpdates = _p.getBool('checkUpdates') ?? true;
    skippedUpdate = _p.getString('skippedUpdate');
    translateLyrics = _p.getBool('lyricsTranslated') ?? false;
    // a language no longer offered is the device's again
    final into = _p.getString('translateInto') ?? '';
    translateInto = LyricsTranslations.languages.containsKey(into) ? into : '';
    deviceName = _p.getString('deviceName') ?? Auth.computerName;
    theme =
        ThemeMode.values.asNameMap()[_p.getString('theme')] ?? ThemeMode.system;
    textScale = _p.getDouble('textScale') ?? 1;
    lyricsEarly = _p.getBool('lyricsEarly') ?? true;
    lyricsMotion = _p.getDouble('lyricsMotion') ?? 0.9;
    geniusNotes = _p.getBool('geniusNotes') ?? false;
    audioCacheMB = _p.getInt('audioCacheMB') ?? AudioCache.defaultLimitMB;
    downloadFolder = _p.getString('downloadFolder');
    coverGlow = _p.getBool('coverGlow') ?? true;
    _loaded = true;
    _apply();
  }

  /// Copy the settings into the globals the rest of the app reads: the server URL, the explicit-track
  /// preference, and the three lyric options.
  void _apply() {
    Api.base = server;
    Track.prefersExplicit = explicit;
    Track.preferredSource = preferredSource.isEmpty ? null : preferredSource;
    Player.autoplay = autoplay;
    Player.autoplaySkipsRecent = autoplaySkipsRecent;
    LyricsStore.early = lyricsEarly;
    LyricsStore.genius = geniusNotes;
    LyricsStore.translateInto = translateInto;
    AudioCache.shared.limitMB = audioCacheMB;
  }

  /// Set one plain setting (bool, double or String): [assign] writes the field, the value goes to
  /// storage under [key] once loaded, then the change is applied and listeners are notified.
  Future<void> _set(String key, Object value, void Function() assign) async {
    assign();
    if (_loaded) {
      switch (value) {
        case final bool b:
          await _p.setBool(key, b);
        case final double d:
          await _p.setDouble(key, d);
        case final int i:
          await _p.setInt(key, i);
        case final String s:
          await _p.setString(key, s);
      }
    }
    _apply();
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode m) => _set('theme', m.name, () => theme = m);
  Future<void> setTextScale(double v) =>
      _set('textScale', v, () => textScale = v);
  Future<void> setLyricsEarly(bool on) =>
      _set('lyricsEarly', on, () => lyricsEarly = on);
  Future<void> setLyricsMotion(double v) =>
      _set('lyricsMotion', v, () => lyricsMotion = v);

  /// A lower limit takes effect now: the least recently played songs are removed to fit it.
  Future<void> setAudioCacheMB(int mb) async {
    await _set('audioCacheMB', mb, () => audioCacheMB = mb);
    AudioCache.shared.evict();
  }

  /// After DownloadStore.moveTo has moved the songs there; null is the app's own folder.
  Future<void> setDownloadFolder(String? path) async {
    downloadFolder = path;
    if (_loaded) path == null ? await _p.remove('downloadFolder') : await _p.setString('downloadFolder', path);
    notifyListeners();
  }

  Future<void> setCoverGlow(bool on) => _set('coverGlow', on, () => coverGlow = on);

  Future<void> setGeniusNotes(bool on) =>
      _set('geniusNotes', on, () => geniusNotes = on);
  Future<void> setPreferredSource(String source) =>
      _set('preferredSource', source, () => preferredSource = source);
  Future<void> setAutoplay(bool on) =>
      _set('autoplay', on, () => autoplay = on);
  Future<void> setAutoplaySkipsRecent(bool on) =>
      _set('autoplaySkipsRecent', on, () => autoplaySkipsRecent = on);
  Future<void> setCheckUpdates(bool on) =>
      _set('checkUpdates', on, () => checkUpdates = on);
  Future<void> skipUpdate(String version) =>
      _set('skippedUpdate', version, () => skippedUpdate = version);
  Future<void> setTranslateLyrics(bool on) =>
      _set('lyricsTranslated', on, () => translateLyrics = on);

  /// The lyrics showing translated are translated again into [language] (kept per language, LyricsTranslations).
  Future<void> setTranslateInto(String language) =>
      _set('translateInto', language, () => translateInto = language);

  /// [s] as the app joins paths to it: trimmed, without trailing slashes, with a scheme; blank is the SERVER
  /// compile-time define. Api joins `$base/$path`, so "https://host/" asked for "https://host//search", which the
  /// server answers 404. And "music.example.com", pasted without a scheme, parsed with no host: every request failed
  /// as "Can't connect" (14 Oct, #23). A name gets https; localhost, an IP address or a .local name gets http, as a
  /// server on this device or the local network runs without TLS (certificates are issued to names).
  static String _address(String s) {
    final a = s.trim().replaceFirst(RegExp(r'/+$'), '');
    if (a.isEmpty) return Api.defaultServer;
    if (a.contains('://')) return a;
    final authority = a.split('/').first;
    final host = authority.startsWith('[') ? authority.substring(1).split(']').first : authority.split(':').first;
    final parts = host.split('.');
    final ip = parts.length == 4 && parts.every((p) => RegExp(r'^\d{1,3}$').hasMatch(p) && int.parse(p) <= 255);
    final local = host == 'localhost' || host.endsWith('.local') || host.contains(':') || ip;
    return '${local ? 'http' : 'https'}://$a';
  }

  /// Point the app at [s] and persist it; a blank [s] falls back to the SERVER compile-time define.
  Future<void> setServer(String s) async {
    server = _address(s);
    await _p.setString('server', server);
    _apply();
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    deviceName = name;
    if (_loaded) {
      await _p.setString(
        'deviceName',
        name,
      ); // a widget test's Settings is never loaded: nothing to keep
    }
  }

  Future<void> setMaterial(WindowMaterial m) async {
    material = m;
    await _p.setString('material', m.name);
    notifyListeners();
  }

  Future<void> setExplicit(bool on) async {
    explicit = on;
    await _p.setBool('explicit', on);
    _apply();
    notifyListeners();
  }
}
