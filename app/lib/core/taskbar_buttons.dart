// Windows' taskbar buttons: Previous, Play or Pause, and Next under the window's preview (#22). The buttons are native
// (windows/runner/taskbar_buttons.cpp); this side tells them what the player can do and runs their presses.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'auth.dart';
import 'home_screen_widget.dart';
import 'library.dart';
import 'player.dart';

/// The toolbar Windows shows under the app's preview when the pointer rests on its taskbar button, as Windows Media
/// Player has: the nearest Windows comes to a widget for an app like this one. The Widgets board takes widgets only
/// from packaged (MSIX) apps, and this app is a plain .exe (#22). The song with its cover and the same buttons are
/// also in Windows' own media controls (MediaControls).
///
/// The buttons do what the Android widget's do ([runPress]): with nothing loaded, Play resumes the latest play, and
/// Previous and Next wait for a song. Signed out, all three are off. Nothing runs at rest: Windows draws the toolbar,
/// and the state is sent only when it changes.
class TaskbarButtons {
  final Player player;
  final Library library;
  final Auth auth;
  final MethodChannel channel;
  TaskbarButtons(this.player, this.library, this.auth, {this.channel = const MethodChannel('nononsense/taskbar')});

  Map<String, Object?>? _sent; // the state last sent: an unchanged one is not sent again

  /// Route the buttons' presses to the player and keep the buttons in step with it. Windows only (main.dart).
  void start() {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'press') return;
      final a = WidgetAction.parse(call.arguments as String);
      if (a != null) await runPress(a, player, library);
    });
    for (final l in _followed) {
      l.addListener(_changed);
    }
    _changed();
  }

  List<Listenable> get _followed => [player, library, auth];

  void dispose() {
    for (final l in _followed) {
      l.removeListener(_changed);
    }
    channel.setMethodCallHandler(null);
  }

  void _changed() {
    final state = stateOf(
      signedIn: auth.user != null,
      loaded: player.current != null,
      playing: player.isPlaying,
      latest: library.recent.firstOrNull?.track.title,
    );
    if (mapEquals(state, _sent)) return;
    _sent = state;
    unawaited(channel.invokeMethod<bool>('set', state).catchError((Object e) {
      debugPrint('taskbar buttons not updated: $e');
      return false;
    }));
  }

  /// What the buttons show: [loaded] turns on Previous and Next; Play is on with a song loaded or a [latest] play to
  /// resume, and says which. Signed out, nothing of the account is shown.
  static Map<String, Object?> stateOf({required bool signedIn, required bool loaded, required bool playing, String? latest}) {
    final resume = signedIn && !loaded && latest != null;
    return {
      'loaded': signedIn && loaded,
      'playing': signedIn && loaded && playing,
      'canPlay': signedIn && (loaded || resume),
      'playTip': resume ? 'Resume “$latest”' : 'Play',
    };
  }
}
