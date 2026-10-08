// Playlist links (8 Oct): the link a playlist is shared by, read back as the Mac app reads it.
import 'package:flutter_test/flutter_test.dart';
import 'package:nononsense/core/links.dart';

void main() {
  test("both kinds of link name the playlist; anything else names none", () {
    const id = '0192f1a2-3b4c-7d5e-8f60-718293a4b5c6';
    expect(PlaylistLinks.playlistId(Uri.parse('nononsense://playlist/$id')), id);
    expect(PlaylistLinks.playlistId(Uri.parse('http://127.0.0.1:8765/p/$id')), id, reason: 'the web address shared');
    expect(PlaylistLinks.playlistId(Uri.parse('nononsense://playlist/${id.toUpperCase()}')), id);
    expect(PlaylistLinks.playlistId(Uri.parse('nononsense://playlist/not-an-id')), isNull);
    expect(PlaylistLinks.playlistId(Uri.parse('https://example.com/somewhere/$id')), isNull);
  });
}
