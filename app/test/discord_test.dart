// Discord status (8 Oct): what is shared, and the protocol, against a fake Discord on a real local socket.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/discord.dart';
import 'package:nononsense/core/models.dart';

final song = Track(const Listing(source: 'jiosaavn', id: 'made-up', title: 'Made-Up Song', artists: ['Kai', 'Sam'],
    album: 'Made-Up Album', duration: 200, image: 'https://covers.example/1.jpg'), const []);

/// A fake Discord: answers the handshake (or refuses it with `refuse`), then every command; keeps every frame.
Future<(ServerSocket, List<(int, Map<String, dynamic>)>)> fakeDiscord(String folder, {String? refuse}) async {
  final frames = <(int, Map<String, dynamic>)>[];
  final server = await ServerSocket.bind(InternetAddress('$folder/discord-ipc-0', type: InternetAddressType.unix), 0);
  server.listen((client) {
    var buffer = <int>[];
    client.listen((data) {
      buffer = [...buffer, ...data];
      while (buffer.length >= 8) {
        final head = ByteData.sublistView(Uint8List.fromList(buffer.sublist(0, 8)));
        final length = head.getUint32(4, Endian.little);
        if (buffer.length < 8 + length) break;
        final opcode = head.getUint32(0, Endian.little);
        frames.add((opcode, jsonDecode(utf8.decode(buffer.sublist(8, 8 + length))) as Map<String, dynamic>));
        buffer = buffer.sublist(8 + length);
        client.add(opcode == 0 && refuse != null
            ? DiscordIpc.frame(2, {'code': 4000, 'message': refuse})
            : DiscordIpc.frame(1, {'cmd': opcode == 0 ? 'DISPATCH' : 'SET_ACTIVITY', 'evt': opcode == 0 ? 'READY' : null, 'data': {}}));
      }
    });
  });
  return (server, frames);
}

void main() {
  test('the status follows the share switches: song, artist, cover, time bar; paused shows your message', () {
    final d = Presence.shared;
    final at = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
    final playing = d.activity(song, isPlaying: true, position: 30, playlist: 'Gym', now: at)!;
    expect(playing['type'], 2, reason: '"Listening to"');
    expect((playing['details'], playing['state']), ('Made-Up Song', 'by Kai, Sam'), reason: 'the playlist is not shared by default');
    expect(playing['timestamps'], {'start': 1000000 - 30, 'end': 1000000 - 30 + 200});
    expect(playing['assets'], {'large_image': 'https://covers.example/1.jpg', 'large_text': 'Made-Up Album',
        'small_image': 'nononsense', 'small_text': 'NoNonsenseMusic'});

    d.shareArtist = false; d.shareTime = false; d.sharePlaylist = true;
    final fewer = d.activity(song, isPlaying: true, position: 30, playlist: 'Gym', now: at)!;
    expect((fewer['state'], fewer.containsKey('timestamps')), ('from “Gym”', false));
    d.shareArtist = true; d.shareTime = true; d.sharePlaylist = false;

    d.pausedMessage = 'Away';
    expect(d.activity(song, isPlaying: false, position: 30)!['details'], 'Away');
    d.whenPaused = 'clear';
    expect(d.activity(song, isPlaying: false, position: 30), isNull, reason: 'nothing shown');
    d.whenPaused = 'message';
  });

  test("Discord's protocol: the handshake with the app's id, then the status; a refused id says why", () async {
    final folder = await Directory.systemTemp.createTemp('discord');
    var (server, frames) = await fakeDiscord(folder.path);
    final ipc = DiscordIpc(socketDirs: [folder.path]);
    await ipc.setActivity({'type': 2, 'details': 'Made-Up Song'}, Presence.applicationId);
    expect(frames[0].$1, 0, reason: 'the handshake first');
    expect(frames[0].$2, {'v': 1, 'client_id': Presence.applicationId});
    expect((frames[1].$1, frames[1].$2['cmd']), (1, 'SET_ACTIVITY'));
    expect(frames[1].$2['args']['activity'], {'type': 2, 'details': 'Made-Up Song'});
    expect(frames[1].$2['args']['pid'], pid);
    await ipc.setActivity(null, Presence.applicationId);
    expect(frames.length, 3, reason: 'the same connection: no second handshake');
    expect(frames[2].$2['args'].containsKey('activity'), isFalse, reason: 'no activity clears the status');
    await ipc.disconnect();
    await server.close();

    (server, frames) = await fakeDiscord(folder.path, refuse: 'Invalid Client ID');
    await expectLater(ipc.setActivity({'type': 2}, 'not-an-id'),
        throwsA(isA<DiscordRefused>().having((e) => e.reason, 'reason', 'Invalid Client ID')));
    await server.close();
    await expectLater(DiscordIpc(socketDirs: [folder.path]).setActivity(null, 'x'), throwsA(isA<DiscordNotRunning>()));
    await folder.delete(recursive: true);
  }, skip: Platform.isWindows ? 'Windows talks to Discord over a named pipe, not a socket' : null);
}
