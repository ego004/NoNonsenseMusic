import 'package:flutter/material.dart';

import '../core/audio_cache.dart';
import '../core/download_store.dart';
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
    ]);
  }
}
