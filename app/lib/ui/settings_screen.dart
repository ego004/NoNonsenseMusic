import 'dart:io';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/discord.dart';
import '../core/settings.dart';
import 'account_settings.dart';
import 'layout.dart';
import 'scope.dart';
import 'storage_settings.dart';

/// Builds the settings screen: account and sign out, the server's address, the window's material on
/// Windows, playback choices, lyrics, and Discord presence.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TextEditingController? _field;
  TextEditingController? _deviceField;
  String? _deviceProblem;
  Future<bool>? _reachable; // the server's /health, requested when Settings opens and after each address change
  // Created once: rebuilding the controller on every dependency change discards the text the user has typed
  TextEditingController get _server => _field ??= TextEditingController(text: Scope.of(context).settings.server);
  TextEditingController get _device => _deviceField ??= TextEditingController(text: Scope.of(context).settings.deviceName);

  @override
  void dispose() {
    _field?.dispose();
    _deviceField?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final theme = Theme.of(context);
    Widget heading(String t) => Padding(padding: const EdgeInsets.only(top: 24, bottom: 8), child: Text(t, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)));
    return ListenableBuilder(
      listenable: s.settings,
      builder: (context, _) => ListView(padding: EdgeInsets.fromLTRB(gutter(context), isPhone(context) ? phoneTop : 28, gutter(context), bottomClearance(context)), children: [
        Text('Settings', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        heading('Account'),
        Row(children: [
          const Expanded(child: Text('Username')),
          Text(s.auth.user?.username ?? 'Not signed in', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TextField(
            controller: _device,
            // Name shown for this device in the device list: chosen at sign-in, changed here, saved on Enter
            decoration: InputDecoration(labelText: 'Device Name', errorText: _deviceProblem),
            onChanged: (_) { if (_deviceProblem != null) setState(() => _deviceProblem = null); },
            onSubmitted: (v) async {
              final problem = await s.auth.renameDevice(v);
              if (problem == null) await s.settings.setDeviceName(v.trim());
              if (mounted) setState(() => _deviceProblem = problem);
            },
          ),
        ),
        const RecoveryCodesSettings(),
        const SpotifyImportSettings(),
        const SizedBox(height: 16),
        // Sign-out is per device: the other devices stay signed in
        Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: s.auth.signOut, child: const Text('Sign Out'))),
        heading('Server'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TextField(
            controller: _server,
            decoration: const InputDecoration(labelText: 'Address', helperText: 'Saved when you press Enter.'),
            // A draft saved on Enter: saving each keystroke would store half-typed addresses
            onSubmitted: (v) async {
              await s.settings.setServer(v);
              _server.text = s.settings.server;
              setState(() => _reachable = Api.health());
              await s.library.refresh();
            },
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<bool>(
          future: _reachable ??= Api.health(),
          builder: (context, ok) => Row(children: [
            Icon(ok.data == null ? Icons.more_horiz : ok.data! ? Icons.check_circle : Icons.cancel, size: 18,
                color: ok.data == null ? theme.colorScheme.onSurfaceVariant : ok.data! ? Colors.green : theme.colorScheme.error),
            const SizedBox(width: 6),
            Text(ok.data == null ? 'Checking…' : ok.data! ? 'Connected' : 'Not reachable'),
          ]),
        ),
        heading('Appearance'),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, label: Text('System')),
            ButtonSegment(value: ThemeMode.light, label: Text('Light')),
            ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
          ],
          selected: {s.settings.themeShown},
          // a solid background is one colour, light or dark: it sets the theme while it is chosen
          onSelectionChanged: s.settings.material.theme == null ? (v) => s.settings.setTheme(v.first) : null,
        ),
        if (Platform.isWindows && s.settings.material.theme != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Set by the ${s.settings.material.label} background below.', style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        _slider(context, 'Text size', s.settings.textScale, 0.85, 1.4, 'Smaller', 'Larger', s.settings.setTextScale),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.settings.coverGlow,
          onChanged: s.settings.setCoverGlow,
          title: const Text('Cover glow'),
          subtitle: const Text('The window takes a soft light from the cover of the song playing.'),
        ),
        if (Platform.isWindows) ...[
          heading('Background'),
          RadioGroup<WindowMaterial>(
            groupValue: s.settings.material,
            onChanged: (m) { if (m != null) s.settings.setMaterial(m); },
            child: Column(children: [
              for (final m in WindowMaterial.values) RadioListTile<WindowMaterial>(value: m, title: Text(m.label), subtitle: Text(m.note)),
            ]),
          ),
        ],
        heading('Playback'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Preferred Source'),
          subtitle: const Text('For songs found on more than one source. Applies to lists loaded after the change.'),
          trailing: _Fit(child: DropdownButton<String>(isExpanded: true,
            value: s.settings.preferredSource,
            onChanged: (v) { if (v != null) s.settings.setPreferredSource(v); },
            items: const [
              DropdownMenuItem(value: '', child: Text('Automatic')),
              DropdownMenuItem(value: 'ytmusic', child: Text('YouTube Music')),
              DropdownMenuItem(value: 'jiosaavn', child: Text('JioSaavn')),
              DropdownMenuItem(value: 'youtube', child: Text('YouTube')),
            ],
          )),
        ),
        SwitchListTile(
          value: s.settings.autoplay,
          onChanged: (on) async {
            await s.settings.setAutoplay(on);
            if (on) s.player.upNextChanged();
          },
          title: const Text('Autoplay'),
          subtitle: const Text('When Up Next runs low, similar songs to the last one are added.'),
        ),
        SwitchListTile(
          value: s.settings.autoplaySkipsRecent,
          onChanged: s.settings.autoplay ? s.settings.setAutoplaySkipsRecent : null,
          title: const Text('Skip songs I played or skipped lately'),
          subtitle: const Text('Autoplay leaves out your last 50 songs.'),
        ),
        SwitchListTile(
          value: s.settings.checkUpdates,
          onChanged: (on) async {
            await s.settings.setCheckUpdates(on);
            setState(() {});
          },
          title: const Text('Check for updates'),
          subtitle: const Text('At launch, asks GitHub whether a newer version exists.'),
        ),
        SwitchListTile(
          value: s.settings.explicit,
          onChanged: s.settings.setExplicit,
          title: const Text('Play the explicit version'),
          subtitle: const Text('When a song has both, the explicit or the clean copy plays. Applies to lists loaded after the change.'),
        ),
        heading('Storage'),
        const StorageSettings(),
        heading('Lyrics'),
        RadioGroup<bool>(
          groupValue: s.settings.lyricsEarly,
          onChanged: (v) { if (v != null) s.settings.setLyricsEarly(v); },
          child: const Column(children: [
            RadioListTile<bool>(value: true, title: Text("When a song starts, and the next song's too")),
            RadioListTile<bool>(value: false, title: Text('Only when I open Lyrics')),
          ]),
        ),
        _slider(context, 'Line movement', s.settings.lyricsMotion, 0.3, 1.5, 'Quick', 'Slow', s.settings.setLyricsMotion),
        SwitchListTile(
          value: s.settings.geniusNotes,
          onChanged: s.settings.setGeniusNotes,
          title: const Text('Genius notes (experimental)'),
          subtitle: const Text('Underlined lines open what Genius says about them; ⓘ shows About This Song. One more lookup per song.'),
        ),
        heading('Discord'),
        const _DiscordSettings(),
      ]),
    );
  }

  /// Builds a slider for a setting on a scale: the setting's name, then the slider between words
  /// naming its two ends.
  ///
  /// The value is saved when the drag ends, not at every step of it.
  Widget _slider(BuildContext context, String label, double value, double min, double max, String low, String high,
      Future<void> Function(double) save) {
    final small = Theme.of(context).textTheme.bodySmall;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label),
        Row(children: [
          Text(low, style: small),
          Expanded(child: _Slide(value: value, min: min, max: max, save: save)),
          Text(high, style: small),
        ]),
      ]),
    );
  }
}

/// A slider that moves freely while dragged and calls [save] once, when the drag ends.
class _Slide extends StatefulWidget {
  final double value, min, max;
  final Future<void> Function(double) save;
  const _Slide({required this.value, required this.min, required this.max, required this.save});
  @override
  State<_Slide> createState() => _SlideState();
}

class _SlideState extends State<_Slide> {
  double? _dragging;
  @override
  Widget build(BuildContext context) => Slider(
        value: (_dragging ?? widget.value).clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        onChanged: (v) => setState(() => _dragging = v),
        onChangeEnd: (v) async {
          await widget.save(v);
          if (mounted) setState(() => _dragging = null);
        },
      );
}


/// Configures Discord presence as in the Mac app's Settings › Discord: what is shared, and how it
/// shows. Off by default.
class _DiscordSettings extends StatelessWidget {
  const _DiscordSettings();
  @override
  Widget build(BuildContext context) {
    final d = Presence.shared;
    return ListenableBuilder(listenable: d, builder: (context, _) {
      Widget share(String label, String key, bool value, void Function(bool) assign) =>
          SwitchListTile(value: value, onChanged: d.enabled ? (v) => d.set(key, v, () => assign(v)) : null, title: Text(label));
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SwitchListTile(value: d.enabled, onChanged: d.setEnabled, title: const Text('Show what I play on Discord'), subtitle: Text(d.status)),
        share('The song', 'discordShareSong', d.shareSong, (v) => d.shareSong = v),
        share('The artist', 'discordShareArtist', d.shareArtist, (v) => d.shareArtist = v),
        share('The cover', 'discordShareArt', d.shareArt, (v) => d.shareArt = v),
        share('The time bar', 'discordShareTime', d.shareTime, (v) => d.shareTime = v),
        share('The NoNonsenseMusic logo', 'discordShareLogo', d.shareLogo, (v) => d.shareLogo = v),
        share('The playlist it plays from', 'discordSharePlaylist', d.sharePlaylist, (v) => d.sharePlaylist = v),
        ListTile(
          title: const Text('In the member list'),
          trailing: _Fit(child: DropdownButton<int>(isExpanded: true,
            value: d.statusLine,
            onChanged: d.enabled ? (v) { if (v != null) d.set('discordStatusLine', v, () => d.statusLine = v); } : null,
            items: const [
              DropdownMenuItem(value: 2, child: Text('The song')),
              DropdownMenuItem(value: 1, child: Text('The artist')),
              DropdownMenuItem(value: 0, child: Text('NoNonsenseMusic')),
            ],
          )),
        ),
        ListTile(
          title: const Text('When paused'),
          trailing: _Fit(child: DropdownButton<String>(isExpanded: true,
            value: d.whenPaused,
            onChanged: d.enabled ? (v) { if (v != null) d.set('discordWhenPaused', v, () => d.whenPaused = v); } : null,
            items: const [
              DropdownMenuItem(value: 'message', child: Text('Show my message')),
              DropdownMenuItem(value: 'keep', child: Text('Keep the song')),
              DropdownMenuItem(value: 'clear', child: Text('Show nothing')),
            ],
          )),
        ),
        if (d.whenPaused == 'message')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextFormField(
              initialValue: d.pausedMessage,
              enabled: d.enabled,
              decoration: const InputDecoration(labelText: 'Message'),
              onFieldSubmitted: (v) => d.set('discordPausedMessage', v, () => d.pausedMessage = v),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton(onPressed: d.enabled ? d.sendTest : null, child: const Text('Send a Test Status')),
        ),
      ]);
    });
  }
}

/// A setting's dropdown at the end of its row: as wide as the row allows, at most 200 points, its choice shortened
/// with an ellipsis. Sized by its longest item, it overflowed the row on a phone (103 points past a 153-point slot).
class _Fit extends StatelessWidget {
  const _Fit({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: child);
}
