// The Downloads page: the songs on this device, newest first, with no server; Remove All asks first.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/audio_cache.dart';
import 'package:nononsense/core/auth.dart';
import 'package:nononsense/core/download_store.dart';
import 'package:nononsense/core/library.dart';
import 'package:nononsense/core/lyrics.dart';
import 'package:nononsense/core/models.dart';
import 'package:nononsense/core/player.dart';
import 'package:nononsense/core/settings.dart';
import 'package:nononsense/ui/scope.dart';
import 'package:nononsense/ui/screens.dart';
import 'package:nononsense/ui/storage_settings.dart';
import 'package:nononsense/ui/theme.dart';


Widget app(Widget page) => Scope(
      player: Player(),
      library: Library(),
      lyrics: LyricsStore(),
      settings: Settings(),
      auth: Auth(store: MemoryTokenStore()),
      child: MaterialApp(theme: buildTheme(Brightness.dark, null), home: Scaffold(body: page)),
    );

DownloadItem downloaded(String id, String title, {int bytes = 4000000, required DateTime added}) {
  final l = Listing(source: 'jiosaavn', id: id, title: title, artists: const ['Alex'], duration: 200);
  return DownloadItem(key: l.key, file: '$id.m4a', best: l, listings: [l], bytes: bytes, added: added);
}

void main() {
  late Directory folder;
  late DownloadStore store;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('downloads');
    store = DownloadStore()..folder = folder;
  });
  tearDown(() async {
    if (folder.existsSync()) await folder.delete(recursive: true);
  });

  testWidgets('with nothing downloaded it says how to download', (tester) async {
    await tester.pumpWidget(app(SongListScreen.downloads(store: store)));
    expect(find.text('Nothing downloaded yet'), findsOneWidget);
    expect(find.textContaining("Can't reach"), findsNothing, reason: 'downloads need no server');
  });

  testWidgets('it lists the downloaded songs, newest first, with their size; Remove All asks first', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final id in ['a', 'b']) {
      File('${folder.path}/$id.m4a').writeAsBytesSync([0, 1, 2]);
    }
    store.items = [
      downloaded('b', 'Newer song', added: DateTime(2026, 10, 13)),
      downloaded('a', 'Older song', added: DateTime(2026, 10, 12)),
    ];
    await tester.pumpWidget(app(SongListScreen.downloads(store: store)));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('2 songs, 8.0 MB'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Newer song')).dy, lessThan(tester.getTopLeft(find.text('Older song')).dy));

    await tester.tap(find.text('Remove All'));
    await tester.pumpAndSettle();
    expect(find.text('Remove all 2 downloads?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.items.length, 2, reason: 'cancelled: nothing removed');

    await tester.tap(find.text('Remove All'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove All'));
    // the removal deletes files and saves the list: real I/O, which moves on only outside the test's fake clock
    for (var i = 0; i < 40 && find.text('Nothing downloaded yet').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(store.items, isEmpty);
    expect(find.text('Nothing downloaded yet'), findsOneWidget);
    expect(File('${folder.path}/a.m4a').existsSync(), isFalse, reason: 'the files go too');
  });

  testWidgets('on a phone, Settings › Storage opens the Downloads page (the bottom bar has no room for it)', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    File('${folder.path}/a.m4a').writeAsBytesSync([0, 1, 2]);
    store.items = [downloaded('a', 'A song', added: DateTime(2026, 10, 13))];
    await tester.pumpWidget(app(SingleChildScrollView(child: StorageSettings(cache: AudioCache(folder), downloads: store))));
    await tester.tap(find.text('See'));
    await tester.pumpAndSettle();
    // the page itself reads the app's own downloads, empty in a test: its empty state shows it opened
    expect(find.text('Nothing downloaded yet'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget, reason: 'a page of its own, with a way back');
  });
}
