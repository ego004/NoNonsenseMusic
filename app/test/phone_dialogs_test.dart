// The dialogs and the sign-in screen on the narrowest phone, at the usual and the largest text size: they build
// without a RenderFlex overflow, the sign-in screen with the keyboard up too. Sign-in picks its layout by the
// platform, which is the computer's here: its form, in a window this small, overflowed until it scrolled (13 Oct).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/playlist_screen.dart';
import 'package:nononsense/ui/recovery_codes.dart';
import 'package:nononsense/ui/sign_in.dart';
import 'package:nononsense/ui/theme.dart';

const size = Size(360, 740);

void main() {
  for (final scale in [1.0, 1.4]) {
    /// Shows [home] on the phone, with [keyboard] of the screen's height taken by the keyboard.
    Future<void> show(WidgetTester tester, Widget home, {double keyboard = 0}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale), viewInsets: EdgeInsets.only(bottom: keyboard)),
        child: MaterialApp(theme: buildTheme(Brightness.light, null), home: home),
      ));
      await tester.pump();
    }

    testWidgets('the recovery codes fit a phone at text size $scale, every code whole', (tester) async {
      final codes = [for (var i = 0; i < 10; i++) 'ABCD-EFGH-IJKL-MN0$i'];
      await show(tester, Scaffold(body: RecoveryCodesDialog(codes: codes, username: 'someone')));
      expect(tester.takeException(), isNull);
      for (final code in codes) {
        expect(find.text(code), findsOneWidget);
      }
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('naming a playlist and confirming fit a phone at text size $scale', (tester) async {
      late BuildContext inside;
      await show(tester, Scaffold(body: Builder(builder: (context) {
        inside = context;
        return const SizedBox.expand();
      })));
      askName(inside, title: 'Rename Playlist', initial: 'A playlist with a rather long name that does not fit');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Rename Playlist'), findsOneWidget);
      Navigator.of(inside).pop();
      await tester.pumpAndSettle();
      confirm(inside, 'Delete “A playlist with a rather long name that does not fit”?', 'Its songs stay in your library.');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Its songs stay in your library.'), findsOneWidget);
    });

    for (final keyboard in [0.0, 300.0]) {
      testWidgets('signing in fits a phone at text size $scale, ${keyboard > 0 ? 'the keyboard up' : 'the keyboard down'}', (tester) async {
        await show(tester, SignInScreen(auth: Auth(store: MemoryTokenStore()), settings: Settings()), keyboard: keyboard);
        expect(tester.takeException(), isNull);
        expect(find.text('Username'), findsOneWidget);
        // every mode: creating an account and resetting a password add a longer label and a field
        await tester.ensureVisible(find.text('Create Account…'));
        await tester.tap(find.text('Create Account…'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Sign In Instead'));
        await tester.tap(find.text('Sign In Instead'));
        await tester.pump();
        await tester.ensureVisible(find.text('Forgot Password?'));
        await tester.tap(find.text('Forgot Password?'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Recovery Code'), findsOneWidget);
      });
    }
  }
}
