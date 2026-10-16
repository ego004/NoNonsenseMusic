// Windows' taskbar buttons (#22) in the real runner: the toolbar goes onto the app's taskbar button, and a press on
// it, which Windows sends to the window as WM_COMMAND with THBN_CLICKED, reaches Dart as the button's name. The test
// presses the buttons the way Windows does, by posting that message to its own window (never another process's: the
// installed app has the same window class). Run with `flutter test integration_test/taskbar_buttons_test.dart -d
// windows`; .github/workflows/windows.yml runs it on GitHub's Windows machine.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nononsense/core/taskbar_buttons.dart';

typedef _FindWindowExC = IntPtr Function(IntPtr parent, IntPtr after, Pointer<Utf16> className, Pointer<Utf16> title);
typedef _FindWindowEx = int Function(int parent, int after, Pointer<Utf16> className, Pointer<Utf16> title);
typedef _ThreadProcessIdC = Uint32 Function(IntPtr window, Pointer<Uint32> process);
typedef _ThreadProcessId = int Function(int window, Pointer<Uint32> process);
typedef _PostMessageC = Int32 Function(IntPtr window, Uint32 message, IntPtr wparam, IntPtr lparam);
typedef _PostMessage = int Function(int window, int message, int wparam, int lparam);

const _wmCommand = 0x0111;
const _thbnClicked = 0x1800;

final _user32 = DynamicLibrary.open('user32.dll');
final _findWindowEx = _user32.lookupFunction<_FindWindowExC, _FindWindowEx>('FindWindowExW');
final _threadProcessId = _user32.lookupFunction<_ThreadProcessIdC, _ThreadProcessId>('GetWindowThreadProcessId');
final _postMessage = _user32.lookupFunction<_PostMessageC, _PostMessage>('PostMessageW');

/// A top-level window of [className] that belongs to this process, or 0.
int _ownWindow(String className) {
  final name = className.toNativeUtf16();
  final process = calloc<Uint32>();
  try {
    for (var w = _findWindowEx(0, 0, name, nullptr); w != 0; w = _findWindowEx(0, w, name, nullptr)) {
      _threadProcessId(w, process);
      if (process.value == pid) return w;
    }
    return 0;
  } finally {
    calloc.free(name);
    calloc.free(process);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('nononsense/taskbar');
  final state = TaskbarButtons.stateOf(signedIn: true, loaded: true, playing: false);

  testWidgets('the toolbar is on the taskbar button, and its presses reach Dart', (tester) async {
    await tester.runAsync(() async {
      final window = _ownWindow('FLUTTER_RUNNER_WIN32_WINDOW');
      expect(window, isNot(0), reason: "this test's own window");

      // the toolbar goes on once the taskbar has made the window's button: "set" answers whether it is there
      final tray = 'Shell_TrayWnd'.toNativeUtf16(); // the taskbar: Explorer's, absent where no shell runs
      final taskbar = _findWindowEx(0, 0, tray, nullptr) != 0;
      calloc.free(tray);
      var shown = false;
      for (var i = 0; i < 40 && !shown; i++) {
        shown = await channel.invokeMethod<bool>('set', state) ?? false;
        if (!shown) await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      // ignore: avoid_print
      print('TASKBAR-CHECK taskbar present: $taskbar, toolbar on the taskbar button: $shown');
      if (taskbar) expect(shown, isTrue, reason: 'ThumbBarAddButtons after TaskbarButtonCreated');

      final presses = <String>[];
      channel.setMethodCallHandler((call) async {
        if (call.method == 'press') presses.add(call.arguments as String);
      });
      for (final id in [1, 2, 3]) {
        expect(_postMessage(window, _wmCommand, (_thbnClicked << 16) | id, 0), isNot(0));
      }
      for (var i = 0; i < 40 && presses.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      channel.setMethodCallHandler(null);
      // ignore: avoid_print
      print('TASKBAR-CHECK presses: ${presses.join(', ')}');
      expect(presses, ['previous', 'toggle', 'next']);
    });
  }, skip: !Platform.isWindows);
}
