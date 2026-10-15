import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/audio_cache.dart';
import '../core/download_store.dart';
import '../core/reveal.dart';
import 'browse_nav.dart';
import 'scope.dart';

/// "48 MB", "1.2 GB" (decimal, as the cache limit is).
String formatBytes(int bytes) =>
    bytes >= 1000000000 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).toStringAsFixed(bytes < 1e7 ? 1 : 0)} MB';

/// Settings › Storage: how much audio the device keeps from songs played (on by default), what it holds now, and the
/// songs downloaded to play offline.
class StorageSettings extends StatefulWidget {
  const StorageSettings({super.key, this.cache, this.downloads});
  final AudioCache? cache;
  final DownloadStore? downloads;

  @override
  State<StorageSettings> createState() => _StorageSettingsState();
}

class _StorageSettingsState extends State<StorageSettings> {
  int? _used;
  AudioCache get _cache => widget.cache ??  AudioCache.shared;
  DownloadStore get _downloads => widget.downloads ?? DownloadStore.shared;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  void _measure() => setState(() => _used = _cache.size());

  static String _label(int mb) => mb == 0 ? 'Off' : mb >= 1000 ? '${mb ~/ 1000} GB' : '$mb MB';

  @override
  Widget build(BuildContext context) {
    final settings = Scope.of(context).settings;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Keep songs on this device'),
        subtitle: const Text('Songs you have played start at once and play offline. The least recently played are removed first.'),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: DropdownButton<int>(
            isExpanded: true,
            value: AudioCache.limitChoicesMB.contains(settings.audioCacheMB) ? settings.audioCacheMB : AudioCache.defaultLimitMB,
            onChanged: (v) async {
              if (v == null) return;
              await settings.setAudioCacheMB(v);
              _measure();
            },
            items: [for (final mb in AudioCache.limitChoicesMB) DropdownMenuItem(value: mb, child: Text(_label(mb)))],
          ),
        ),
      ),
      Row(children: [
        const Expanded(child: Text('Used')),
        Text(_used == null ? '…' : formatBytes(_used!), style: TextStyle(color: muted)),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: (_used ?? 0) == 0 ? null : () { _cache.clear(); _measure(); },
          child: const Text('Clear'),
        ),
      ]),
      ListenableBuilder(
        listenable: _downloads,
        builder: (context, _) => Row(children: [
          Expanded(child: Text('Downloads: ${_downloads.items.length} songs, ${formatBytes(_downloads.totalBytes)}')),
          // the Downloads page: a sidebar item in a wide window, and only reachable from here on a phone
          OutlinedButton(
            onPressed: _downloads.items.isEmpty ? null : () => openBrowse(context, const DownloadsTarget()),
            child: const Text('See'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _downloads.items.isEmpty ? null : _downloads.removeAll,
            child: const Text('Remove All'),
          ),
        ]),
      ),
      // a phone keeps downloads in the app's own storage: Android lets an app write only there without asking
      if (canShowInFolder) DownloadLocation(downloads: _downloads),
    ]);
  }
}

/// Settings › Storage › Download location, on a computer: the folder songs download to, and a way to choose another.
/// Choosing one moves the songs already downloaded there.
class DownloadLocation extends StatefulWidget {
  const DownloadLocation({super.key, required this.downloads});
  final DownloadStore downloads;

  @override
  State<DownloadLocation> createState() => _DownloadLocationState();
}

class _DownloadLocationState extends State<DownloadLocation> {
  String? _failed;

  /// [path] null: back to the app's own folder.
  Future<void> _moveTo(String? path) async {
    final settings = Scope.of(context).settings;
    setState(() => _failed = null);
    try {
      await widget.downloads.moveTo(path == null ? await DownloadStore.defaultFolder() : Directory(path));
      await settings.setDownloadFolder(path);
    } on FileSystemException catch (e) {
      _failed = "Couldn't move your downloads there: ${e.osError?.message ?? e.message}";
    } catch (e) {
      _failed = "Couldn't move your downloads there: $e";
    }
    if (mounted) setState(() {});
  }

  Future<void> _choose() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Download songs to',
      initialDirectory: widget.downloads.folder?.path,
    );
    if (path != null) await _moveTo(path);
  }

  @override
  Widget build(BuildContext context) {
    final settings = Scope.of(context).settings;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.downloads,
      builder: (context, _) {
        final d = widget.downloads;
        final shown = d.folder ?? d.missingFolder;
        if (shown == null) return const SizedBox.shrink(); // storage unavailable: downloads are off
        final path = Platform.isWindows ? shown.path.replaceAll('/', r'\') : shown.path;
        final busy = d.moving || d.inProgress.isNotEmpty;
        final (note, warn) = d.moving
            ? ('Moving your downloads…', false)
            : _failed != null
                ? (_failed!, true)
                : d.folder == null
                    ? ('Not found: $path. Connect its drive, or choose another folder.', true)
                    : d.inProgress.isNotEmpty
                        ? ('$path\nIt can be changed once the downloads in progress finish.', false)
                        : (path, false);
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Download location'),
            const SizedBox(height: 2),
            Text(note, style: theme.textTheme.bodySmall?.copyWith(color: warn ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: busy ? null : _choose, child: const Text('Change…')),
              if (d.folder != null) OutlinedButton(onPressed: () => openFolder(d.folder!), child: const Text('Open')),
              if (settings.downloadFolder != null)
                TextButton(onPressed: busy ? null : () => _moveTo(null), child: const Text('Use Default')),
            ]),
          ]),
        );
      },
    );
  }
}
