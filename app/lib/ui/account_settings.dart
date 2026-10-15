import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/account_api.dart';
import '../core/spotify_import.dart';
import 'glass_menu.dart';
import 'recovery_codes.dart';
import 'scope.dart';

/// Settings › Account › Recovery Codes: how many of the ten are unused (orange at three or fewer), and a new set.
class RecoveryCodesSettings extends StatefulWidget {
  const RecoveryCodesSettings({super.key});
  @override
  State<RecoveryCodesSettings> createState() => _RecoveryCodesSettingsState();
}

class _RecoveryCodesSettingsState extends State<RecoveryCodesSettings> {
  int? _left;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final n = await AccountApi.codesLeft();
      if (mounted) setState(() => _left = n);
    } catch (_) {} // the count stays "–" until the next visit
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = _left;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text('Recovery Codes', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Row(children: [
        const Expanded(child: Text('Unused Codes')),
        Text(left == null ? '–' : '$left of 10',
            style: theme.textTheme.bodyMedium?.copyWith(color: left != null && left <= 3 ? Colors.orange : theme.colorScheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: () async {
            final s = Scope.of(context);
            final codes = await askNewRecoveryCodes(context);
            if (codes == null || !context.mounted) return;
            setState(() => _left = codes.length);
            await showRecoveryCodes(context, codes, s.auth.user?.username ?? '');
          },
          child: const Text('New Recovery Codes…'),
        ),
      ),
    ]);
  }
}

/// Settings › Account › Import from Spotify: pick Exportify's CSVs or Spotify's data-download files; the server adds
/// the songs it finds, and the songs it cannot find are listed.
class SpotifyImportSettings extends StatelessWidget {
  const SpotifyImportSettings({super.key});

  Future<void> _choose(BuildContext context) async {
    final library = Scope.of(context).library;
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'json']);
    if (picked.isEmpty) return;
    final files = [for (final f in picked) (f.name, utf8.decode(await f.readAsBytes(), allowMalformed: true))];
    await SpotifyImporter.shared.start(files, done: library.refresh);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final importer = SpotifyImporter.shared;
    return ListenableBuilder(
      listenable: importer,
      builder: (context, _) {
        final status = importer.status;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 16),
          Text('Import from Spotify or YouTube', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Spotify: files from exportify.net, or from Spotify\'s Privacy settings (Download your data). YouTube: a '
              'playlist link, or Google Takeout\'s playlist files. Only song names and video ids leave this device.',
              style: TextStyle(color: muted)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: importer.running ? null : () => _choose(context),
              child: Text(importer.running ? 'Importing…' : 'Choose Files…'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            enabled: !importer.running,
            decoration: const InputDecoration(labelText: 'YouTube playlist', hintText: 'music.youtube.com/playlist?list=…'),
            onSubmitted: (link) {
              if (link.trim().isEmpty) return;
              SpotifyImporter.shared.startLink(link, done: Scope.of(context).library.refresh);
            },
          ),
          if (status != null && !status.finished) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: status.total == 0 ? null : status.done / status.total),
            const SizedBox(height: 4),
            Text('${status.done} of ${status.total} songs', style: TextStyle(color: muted)),
          ],
          if (status != null && status.finished) ...[
            const SizedBox(height: 8),
            Text('${status.added} of ${status.total} added', style: TextStyle(color: muted)),
            if (status.missing.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Not Found (${status.total - status.added})'),
                children: [for (final m in status.missing) Align(alignment: Alignment.centerLeft, child: Text(m, style: TextStyle(color: muted)))],
              ),
          ],
          if (importer.problem != null) ...[
            const SizedBox(height: 8),
            Text(importer.problem!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ]);
      },
    );
  }
}

/// A playlist's Import: songs from Spotify or YouTube files, or from a YouTube playlist link, added to this playlist.
class ImportIntoPlaylistButton extends StatelessWidget {
  const ImportIntoPlaylistButton({super.key, required this.playlistId});
  final String playlistId;

  /// "Import", or how far the import has got: "Importing 20 of 112…" ("Importing…" until the server first answers).
  static String _progress(SpotifyImporter i) {
    if (!i.running) return 'Import';
    final s = i.status;
    return s == null || s.total == 0 ? 'Importing…' : 'Importing ${s.done} of ${s.total}…';
  }

  Future<void> _files(BuildContext context) async {
    final library = Scope.of(context).library;
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'json']);
    if (picked.isEmpty) return;
    final files = [for (final f in picked) (f.name, utf8.decode(await f.readAsBytes(), allowMalformed: true))];
    await SpotifyImporter.shared.start(files, playlistId: playlistId, done: () => library.loadPlaylist(playlistId));
  }

  Future<void> _link(BuildContext context) async {
    final library = Scope.of(context).library;
    final controller = TextEditingController();
    final link = await showGlassDialog<String>(
      context: context,
      builder: (c) => GlassDialog(
        title: const Text('Import a YouTube Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'music.youtube.com/playlist?list=…'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('Import')),
        ],
      ),
    );
    if (link == null || link.trim().isEmpty) return;
    await SpotifyImporter.shared.startLink(link, playlistId: playlistId, done: () => library.loadPlaylist(playlistId));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SpotifyImporter.shared,
      builder: (context, _) => GlassMenuButton<String>(
        enabled: !SpotifyImporter.shared.running,
        tooltip: 'Add songs from Spotify or YouTube',
        onSelected: (v) => v == 'files' ? _files(context) : _link(context),
        width: 280,
        entries: () => const [
          GlassMenuEntry('files', 'Songs from Files…'),
          GlassMenuEntry('link', 'Songs from a YouTube Playlist…'),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.download_outlined, size: 18),
            const SizedBox(width: 6),
            Text(_progress(SpotifyImporter.shared)),
          ]),
        ),
      ),
    );
  }
}
