import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'audio_cache.dart';
import 'auth.dart';
import 'lyrics.dart';
import 'models.dart';
import 'player.dart';

/// A background material for the window on Windows, drawn by Windows itself rather than by the app.
enum WindowMaterial {
  acrylic(
    'Acrylic',
    'A live blur of what is behind the window. On some PCs, dragging the window stutters with it.',
  ),
  mica('Mica', 'A soft tint from your wallpaper. The lightest.'),
  solid('Solid', 'No see-through at all.');

  final String label, note;
  const WindowMaterial(this.label, this.note);
}

/// Holds every setting and keeps it between launches. A change applies at once.
class Settings extends ChangeNotifier {
  late SharedPreferences _p;
  String server = Api.base;
  WindowMaterial material = WindowMaterial.acrylic;

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

  /// The name this device shows in the user's list of signed-in devices.
  /// The user chooses it on the sign-in screen; it starts as the computer's name ([Auth.computerName]).
  String deviceName = Auth.computerName;

  /// Appearance: light, dark, or matching the system.
  ThemeMode theme = ThemeMode.system;

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
  bool _loaded = false;

  /// Read the stored settings, using each default where a key is missing, then apply them.
  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    server = _address(_p.getString('server') ?? Api.defaultServer); // also mends an address saved with a trailing "/"
    material =
        WindowMaterial.values.asNameMap()[_p.getString('material')] ??
        WindowMaterial.acrylic;
    explicit = _p.getBool('explicit') ?? true;
    preferredSource = _p.getString('preferredSource') ?? '';
    autoplay = _p.getBool('autoplay') ?? true;
    autoplaySkipsRecent = _p.getBool('autoplaySkipsRecent') ?? true;
    checkUpdates = _p.getBool('checkUpdates') ?? true;
    skippedUpdate = _p.getString('skippedUpdate');
    translateLyrics = _p.getBool('lyricsTranslated') ?? false;
    deviceName = _p.getString('deviceName') ?? Auth.computerName;
    theme =
        ThemeMode.values.asNameMap()[_p.getString('theme')] ?? ThemeMode.system;
    textScale = _p.getDouble('textScale') ?? 1;
    lyricsEarly = _p.getBool('lyricsEarly') ?? true;
    lyricsMotion = _p.getDouble('lyricsMotion') ?? 0.9;
    geniusNotes = _p.getBool('geniusNotes') ?? false;
    audioCacheMB = _p.getInt('audioCacheMB') ?? AudioCache.defaultLimitMB;
    _loaded = true;
    _apply();
  }

  /// Copy the settings into the globals the rest of the app reads: the server URL, the explicit-track
  /// preference, and the two lyric options.
  void _apply() {
    Api.base = server;
    Track.prefersExplicit = explicit;
    Track.preferredSource = preferredSource.isEmpty ? null : preferredSource;
    Player.autoplay = autoplay;
    Player.autoplaySkipsRecent = autoplaySkipsRecent;
    LyricsStore.early = lyricsEarly;
    LyricsStore.genius = geniusNotes;
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

  /// [s] as the app joins paths to it: trimmed, without trailing slashes. Api joins `$base/$path`, so
  /// "https://host/" asked for "https://host//search", which the server answers 404: every request failed.
  static String _address(String s) => s.trim().replaceFirst(RegExp(r'/+$'), '');

  /// Point the app at [s] and persist it; a blank [s] falls back to the SERVER compile-time define.
  Future<void> setServer(String s) async {
    server = _address(s.trim().isEmpty ? Api.defaultServer : s);
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
