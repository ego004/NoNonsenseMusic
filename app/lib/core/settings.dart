import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
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

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    server = _p.getString('server') ?? Api.base;
    material = WindowMaterial.values.asNameMap()[_p.getString('material')] ?? WindowMaterial.acrylic;
    explicit = _p.getBool('explicit') ?? true;
    _apply();
  }

  void _apply() {
    Api.base = server;
    Track.prefersExplicit = explicit;
  }

  Future<void> setServer(String s) async {
    server = s.trim().isEmpty ? const String.fromEnvironment('SERVER', defaultValue: 'http://127.0.0.1:8000') : s.trim();
    await _p.setString('server', server);
    _apply();
    notifyListeners();
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
