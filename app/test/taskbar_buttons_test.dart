// Windows' taskbar buttons (#22): what they are told, when, and what their presses do. The native side is
// windows/runner/taskbar_buttons.cpp; here the channel is answered by the test.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/api.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/taskbar_buttons.dart';

Track song(String name) =>
    Track(Listing(source: 'jiosaavn', id: 'id-$name', title: name, artists: const ['Kai'], duration: 200), const []);

/// The player's controls, recorded instead of played: no audio in a unit test.
class RecordingPlayer extends Player {
  final calls = <String>[];
  bool loaded = false;
  bool playingNow = false;

  @override
  Track? get current => loaded ? song('Blue') : null;
  @override
  bool get isPlaying => playingNow;
  @override
  void togglePlayPause() => calls.add('toggle');
  @override
  Future<void> next() async => calls.add('next');
  @override
  Future<void> previous() async => calls.add('previous');
  @override
  Future<void> play(List<Track> tracks,
          {int startAt = 0, List<String>? keys, String? source, bool shuffled = false, bool wholeList = false}) async =>
      calls.add('play ${tracks.map((t) => t.title).join(', ')}');

  void changed() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nononsense/taskbar');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('state', () {
    test('a song playing: every button on, Pause', () {
      expect(TaskbarButtons.stateOf(signedIn: true, loaded: true, playing: true, latest: 'Old'),
          {'loaded': true, 'playing': true, 'canPlay': true, 'playTip': 'Play'});
    });

    test('nothing loaded: Play resumes the latest play and says which; Previous and Next wait for a song', () {
      expect(TaskbarButtons.stateOf(signedIn: true, loaded: false, playing: false, latest: 'Old'),
          {'loaded': false, 'playing': false, 'canPlay': true, 'playTip': 'Resume “Old”'});
    });

    test('nothing loaded and nothing played: all off', () {
      expect(TaskbarButtons.stateOf(signedIn: true, loaded: false, playing: false),
          {'loaded': false, 'playing': false, 'canPlay': false, 'playTip': 'Play'});
    });

    test('signed out: all off, and nothing of the account in the tooltip', () {
      expect(TaskbarButtons.stateOf(signedIn: false, loaded: true, playing: true, latest: 'Old'),
          {'loaded': false, 'playing': false, 'canPlay': false, 'playTip': 'Play'});
    });
  });

  group('the channel', () {
    late List<Map> sent;
    late RecordingPlayer player;
    late Library library;
    late TaskbarButtons buttons;

    setUp(() {
      sent = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'set') sent.add(call.arguments as Map);
        return true;
      });
      player = RecordingPlayer();
      library = Library()..recent = [LibrarySong('s1', song('Old'))];
      final auth = Auth(store: MemoryTokenStore())..user = const AuthUser('u1', 'kai');
      buttons = TaskbarButtons(player, library, auth)..start();
    });

    tearDown(() {
      buttons.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    /// A press as Windows sends it: the native side calls `press` with the button's name.
    Future<void> press(String name) async {
      await messenger.handlePlatformMessage(
          channel.name, const StandardMethodCodec().encodeMethodCall(MethodCall('press', name)), (_) {});
    }

    test('the state goes once at the start, and again only when it changes', () async {
      await pumpEventQueue();
      expect(sent, [
        {'loaded': false, 'playing': false, 'canPlay': true, 'playTip': 'Resume “Old”'}
      ]);
      player.changed(); // the player tells of something the buttons do not show (a buffering change, the queue)
      await pumpEventQueue();
      expect(sent, hasLength(1), reason: 'nothing the buttons show changed: nothing is sent');
      player
        ..loaded = true
        ..playingNow = true
        ..changed();
      await pumpEventQueue();
      expect(sent.last, {'loaded': true, 'playing': true, 'canPlay': true, 'playTip': 'Play'});
      expect(sent, hasLength(2));
    });

    test('with nothing loaded, Play resumes the latest play, as on the Android widget', () async {
      await press('toggle');
      expect(player.calls, ['play Old']);
    });

    test('with a song loaded, the buttons are Previous, Play or Pause, and Next', () async {
      player.loaded = true;
      await press('previous');
      await press('toggle');
      await press('next');
      expect(player.calls, ['previous', 'toggle', 'next']);
    });

    test('anything else is ignored', () async {
      await press('format-disk');
      expect(player.calls, isEmpty);
    });
  });
}
