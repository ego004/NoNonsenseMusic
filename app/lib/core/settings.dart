import 'dart:io';

import 'package:flutter/material.dart' show BuildContext, Color, Theme, ThemeExtension, ThemeMode;
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

/// Settings › Appearance › Colours: where a coloured part takes its colour, as on the Mac (ThemeStore.Mode).
enum ColourMode {
  system('System'),
  song('Song'),
  custom('Custom');

  final String label;
  const ColourMode(this.label);
}

/// "#5E5CE6" (the "#" optional) as a colour; null for anything else. The Mac's hex codes: a colour reads the same on both.
Color? colourFromHex(String text) {
  final hex = text.trim().replaceFirst('#', '');
  return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex) ? Color(0xFF000000 | int.parse(hex, radix: 16)) : null;
}

String hexOf(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Settings › Appearance as one value (#29): the window's background, the colours, the bar's blur and fill, the
/// background's colour strength, the card size. The theme carries it (buildTheme), so a change redraws what shows it, at
/// once: a const widget deep in the tree included, which a value read from [Settings] left as it was until something
/// else redrew it (the sidebar kept Glass's fill after a change to Mica until another page was opened). The defaults are
/// the look from before these settings (15 Oct), but for a phone's blur ([phone]).
@immutable
class Look extends ThemeExtension<Look> {
  /// Window: the window's background on Windows, drawn by Windows.
  final WindowMaterial material;

  /// Colours › Accent: buttons, selections and the playing song. System: the app's blue.
  final ColourMode accent;

  /// Colours › Background: the colours behind the lists and Now Playing. System: none.
  final ColourMode background;

  /// Custom's colours.
  final Color accentColour, backgroundColour;

  /// The playing cover's most vivid colour (Accent), what Song means; null for a grey cover or none. Set by buildTheme.
  final Color? song;

  /// Surfaces › Main area and Now Playing › Colour strength: how strong the background's colours are, 0 (none) up;
  /// [defaultStrength] is the strength they had before they could be set.
  final double artStrength, nowPlayingColour;

  /// Surfaces › Player bar (a phone's bottom bar: the player bar and the tabs): its blur, 0 (none) to 1, and how much of
  /// the see-through part of its tint is filled in, 0 (as before) to 1 (solid), as the Mac's barSolid.
  final double barBlur, barSolid;

  /// Sizes › Card size: the covers on Home, in the Library and in album grids, in points (the Mac's default and range).
  final double cardSize;

  const Look({
    this.material = WindowMaterial.glass,
    this.accent = ColourMode.song,
    this.background = ColourMode.song,
    this.accentColour = const Color(0xFF0A84FF), // the Mac's: the system blue
    this.backgroundColour = const Color(0xFF5E5CE6), // the system indigo
    this.song,
    this.artStrength = defaultStrength,
    this.nowPlayingColour = defaultStrength,
    this.barBlur = 1,
    this.barSolid = 0,
    this.cardSize = 148,
  });

  /// A phone's: the bars without blur, as a blur is drawn again with every frame anything under it moves (battery,
  /// #29).
  static const phone = Look(barBlur: 0);

  static final Look defaults = Platform.isAndroid ? phone : const Look();

  /// The colour strengths' default: the cover's colours as strong as before they could be set (the Mac's artStrength).
  static const defaultStrength = 0.7;

  /// The opacity of the background's colours at [strength], [before] being theirs at the default.
  static double strong(double strength, double before) => (before * strength / defaultStrength).clamp(0.0, 1.0);

  /// The look the theme above [context] carries.
  static Look of(BuildContext context) => Theme.of(context).extension<Look>() ?? const Look();

  /// [side], a card's size at the default, at the chosen card size.
  double card(double side) => side * cardSize / 148;

  /// [fill], the opacity of a part of the bar's tint as it was, with [barSolid] of the rest filled in.
  double solid(double fill) => fill + (1 - fill) * barSolid;

  /// The look as it is kept, a key and a value each.
  Map<String, Object> get _prefs => {
        'material': material.name,
        'accentMode': accent.name,
        'accentHex': hexOf(accentColour),
        'backgroundMode': background.name,
        'backgroundHex': hexOf(backgroundColour),
        'artStrength': artStrength,
        'nowPlayingColour': nowPlayingColour,
        'barBlur': barBlur,
        'barSolid': barSolid,
        'cardSize': cardSize,
      };

  static Look _read(SharedPreferences p) {
    final d = defaults;
    ColourMode mode(String key, ColourMode or) => ColourMode.values.asNameMap()[p.getString(key)] ?? or;
    Color colour(String key, Color or) => colourFromHex(p.getString(key) ?? '') ?? or;
    double number(String key, double or) => p.getDouble(key) ?? or;
    // a saved 'solid' (before the six backgrounds, 15 Oct) is the dark one
    final material = p.getString('material');
    return Look(
      material: material == 'solid' ? WindowMaterial.solidDark : WindowMaterial.values.asNameMap()[material] ?? d.material,
      accent: mode('accentMode', d.accent),
      // Cover glow (15 Oct) switched off is Background: System
      background: mode('backgroundMode', p.getBool('coverGlow') == false ? ColourMode.system : d.background),
      accentColour: colour('accentHex', d.accentColour),
      backgroundColour: colour('backgroundHex', d.backgroundColour),
      artStrength: number('artStrength', d.artStrength),
      nowPlayingColour: number('nowPlayingColour', d.nowPlayingColour),
      barBlur: number('barBlur', d.barBlur),
      barSolid: number('barSolid', d.barSolid),
      cardSize: number('cardSize', d.cardSize),
    );
  }

  static const _same = Object();

  @override
  Look copyWith({
    WindowMaterial? material,
    ColourMode? accent,
    ColourMode? background,
    Color? accentColour,
    Color? backgroundColour,
    Object? song = _same, // a Color, or null for none
    double? artStrength,
    double? nowPlayingColour,
    double? barBlur,
    double? barSolid,
    double? cardSize,
  }) =>
      Look(
        material: material ?? this.material,
        accent: accent ?? this.accent,
        background: background ?? this.background,
        accentColour: accentColour ?? this.accentColour,
        backgroundColour: backgroundColour ?? this.backgroundColour,
        song: identical(song, _same) ? this.song : song as Color?,
        artStrength: artStrength ?? this.artStrength,
        nowPlayingColour: nowPlayingColour ?? this.nowPlayingColour,
        barBlur: barBlur ?? this.barBlur,
        barSolid: barSolid ?? this.barSolid,
        cardSize: cardSize ?? this.cardSize,
      );

  /// A change of look is shown whole, not blended: a blur or a fill between two settings would be drawn for nothing.
  @override
  Look lerp(Look? other, double t) => other == null || t < 0.5 ? this : other;

  @override
  bool operator ==(Object other) => other is Look && other.song == song && mapEquals(other._prefs, _prefs);

  @override
  int get hashCode => Object.hash(song, Object.hashAll(_prefs.values));
}

/// Holds every setting and keeps it between launches. A change applies at once.
class Settings extends ChangeNotifier {
  late SharedPreferences _p;
  String server = Api.base;
  WindowMaterial get material => look.material;

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

  /// Settings › Appearance's colours, surfaces and card size.
  Look look = Look.defaults;

  /// Settings › Storage › Download location: the folder the user chose for downloads, null for the app's own.
  String? downloadFolder;
  bool _loaded = false;

  /// Read the stored settings, using each default where a key is missing, then apply them.
  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    server = _address(_p.getString('server') ?? Api.defaultServer); // also mends one saved with a trailing "/" or no scheme
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
    look = Look._read(_p);
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
    await _write(key, value);
    _apply();
    notifyListeners();
  }

  /// Keep [value] under [key], once the stored settings are loaded (a widget test's Settings never is: nothing to keep).
  Future<void> _write(String key, Object value) async {
    if (!_loaded) return;
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

  /// Settings › Appearance: [next] shown at once, and each of its values that changed kept.
  Future<void> setLook(Look next) async {
    final before = look._prefs;
    look = next;
    for (final e in next._prefs.entries) {
      if (before[e.key] != e.value) await _write(e.key, e.value);
    }
    notifyListeners();
  }

  /// Settings › Appearance › Reset All: the colours, the surfaces and both sizes as they came.
  Future<void> resetLook() async {
    await setTextScale(1);
    await setLook(Look.defaults);
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

  Future<void> setMaterial(WindowMaterial m) => setLook(look.copyWith(material: m));

  Future<void> setExplicit(bool on) async {
    explicit = on;
    await _p.setBool('explicit', on);
    _apply();
    notifyListeners();
  }
}
