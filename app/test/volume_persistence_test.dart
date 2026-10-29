// Volume persistence across restarts.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/player.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restores volume and mute state from SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({
      'playerVolume': 0.65,
      'playerBeforeMute': 0.65,
    });
    final p = Player();
    addTearDown(p.dispose);
    await p.restore();
    expect(p.volume, closeTo(0.65, 0.001));
  });

  test('restores default volume when preferences are absent', () async {
    SharedPreferences.setMockInitialValues({});
    final p = Player();
    addTearDown(p.dispose);
    await p.restore();
    expect(p.volume, 1.0);
  });

  test('persists volume change to SharedPreferences after debounce', () async {
    SharedPreferences.setMockInitialValues({});
    final p = Player();
    addTearDown(p.dispose);
    p.setVolume(0.42);
    expect(p.volume, closeTo(0.42, 0.001));

    // Wait for the debounce timer (200ms) to complete
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('playerVolume'), closeTo(0.42, 0.001));
  });

  test('release flushes volume persistence immediately', () async {
    SharedPreferences.setMockInitialValues({});
    final p = Player();
    p.setVolume(0.28);
    await p.release();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('playerVolume'), closeTo(0.28, 0.001));
  });

  test('mute and unmute cycles correctly persist and restore', () async {
    SharedPreferences.setMockInitialValues({});
    final p = Player();
    addTearDown(p.dispose);
    p.setVolume(0.75);
    p.toggleMute();
    expect(p.volume, 0.0);

    await Future<void>.delayed(const Duration(milliseconds: 250));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('playerVolume'), 0.0);
    expect(prefs.getDouble('playerBeforeMute'), closeTo(0.75, 0.001));

    // Create a new player to simulate app restart
    final restartedPlayer = Player();
    addTearDown(restartedPlayer.dispose);
    await restartedPlayer.restore();
    expect(restartedPlayer.volume, 0.0);

    // Unmute should restore pre-mute volume
    restartedPlayer.toggleMute();
    expect(restartedPlayer.volume, closeTo(0.75, 0.001));
  });
}
