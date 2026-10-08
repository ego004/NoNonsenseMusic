import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'auth.dart';
import 'lyrics.dart';
import 'models.dart';

/// The window's background on Windows. Drawn by Windows itself, not by the app.
enum WindowMaterial {
  acrylic('Acrylic', 'A live blur of what is behind the window. On some PCs, dragging the window stutters with it.'),
  mica('Mica', 'A soft tint from your wallpaper. The lightest.'),
  solid('Solid', 'No see-through at all.');

  final String label, note;
  const WindowMaterial(this.label, this.note);
}

/// Every setting, kept between launches. A change applies at once.
class Settings extends ChangeNotifier {
  late SharedPreferences _p;
  String server = Api.base;
  WindowMaterial material = WindowMaterial.acrylic; // your choice, 8 Oct
  bool explicit = true; // play a song's explicit version when it has one
  /// What this device is called in your list of signed-in devices (AUTH-4): yours to choose on the sign-in screen;
  /// it starts as the computer's name (Auth.computerName).
  String deviceName = Auth.computerName;
  /// Appearance: light, dark, or as the system is; the size of all text (the Mac app's Text size, 0.85 to 1.4).
  ThemeMode theme = ThemeMode.system;
  double textScale = 1;
  /// Lyrics: asked for when a song starts (and the next song's too), or only when the panel opens; how long the lit
  /// line takes to move to the middle, in seconds (the Mac app's 0.9 by default).
  bool lyricsEarly = true;
  double lyricsMotion = 0.9;
  bool _loaded = false;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    server = _p.getString('server') ?? Api.base;
    material = WindowMaterial.values.asNameMap()[_p.getString('material')] ?? WindowMaterial.acrylic;
    explicit = _p.getBool('explicit') ?? true;
    deviceName = _p.getString('deviceName') ?? Auth.computerName;
    theme = ThemeMode.values.asNameMap()[_p.getString('theme')] ?? ThemeMode.system;
    textScale = _p.getDouble('textScale') ?? 1;
    lyricsEarly = _p.getBool('lyricsEarly') ?? true;
    lyricsMotion = _p.getDouble('lyricsMotion') ?? 0.9;
    _loaded = true;
    _apply();
  }

  void _apply() {
    Api.base = server;
    Track.prefersExplicit = explicit;
    LyricsStore.early = lyricsEarly;
  }

  /// One setter for the plain ones: set, kept, applied, and everything showing it redrawn.
  Future<void> _set(String key, Object value, void Function() assign) async {
    assign();
    if (_loaded) {
      switch (value) {
        case final bool b: await _p.setBool(key, b);
        case final double d: await _p.setDouble(key, d);
        case final String s: await _p.setString(key, s);
      }
    }
    _apply();
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode m) => _set('theme', m.name, () => theme = m);
  Future<void> setTextScale(double v) => _set('textScale', v, () => textScale = v);
  Future<void> setLyricsEarly(bool on) => _set('lyricsEarly', on, () => lyricsEarly = on);
  Future<void> setLyricsMotion(double v) => _set('lyricsMotion', v, () => lyricsMotion = v);

  Future<void> setServer(String s) async {
    server = s.trim().isEmpty ? const String.fromEnvironment('SERVER', defaultValue: 'http://127.0.0.1:8000') : s.trim();
    await _p.setString('server', server);
    _apply();
    notifyListeners();
  }

  Future<void> setDeviceName(String name) async {
    deviceName = name;
    if (_loaded) await _p.setString('deviceName', name); // a widget test's Settings is never loaded: nothing to keep
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
