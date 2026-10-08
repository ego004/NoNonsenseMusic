import 'dart:io';

import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/settings.dart';
import 'scope.dart';

/// Settings: your account (sign out), the server's address, the window's material (Windows), which version plays.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TextEditingController? _field;
  TextEditingController? _deviceField;
  String? _deviceProblem;
  Future<bool>? _reachable; // the server's /health, asked when Settings opens and after the address changes
  // made once: a new one on every dependency change lost what you were typing
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
      builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(32, 28, 32, 120), children: [
        Text('Settings', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        heading('Account'),
        Row(children: [
          Expanded(child: Text(s.auth.user == null ? 'Signed in' : 'Signed in as ${s.auth.user!.username}')),
          // this device only: the others stay signed in
          OutlinedButton(onPressed: s.auth.signOut, child: const Text('Sign Out')),
        ]),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TextField(
            controller: _device,
            // what this device is called in your list of devices: chosen at sign-in, changed here (saved on Enter)
            decoration: InputDecoration(labelText: 'Device Name', errorText: _deviceProblem),
            onChanged: (_) { if (_deviceProblem != null) setState(() => _deviceProblem = null); },
            onSubmitted: (v) async {
              final problem = await s.auth.renameDevice(v);
              if (problem == null) await s.settings.setDeviceName(v.trim());
              if (mounted) setState(() => _deviceProblem = problem);
            },
          ),
        ),
        heading('Server'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TextField(
            controller: _server,
            decoration: const InputDecoration(labelText: 'Address', helperText: 'Saved when you press Enter.'),
            // a draft, saved on Enter: a field saving every keystroke saved half-typed addresses (the Mac app, 7 Oct)
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
          selected: {s.settings.theme},
          onSelectionChanged: (v) => s.settings.setTheme(v.first),
        ),
        const SizedBox(height: 12),
        _slider(context, 'Text size', s.settings.textScale, 0.85, 1.4, 'Smaller', 'Larger', s.settings.setTextScale),
        if (Platform.isWindows) ...[
          heading('Window'),
          RadioGroup<WindowMaterial>(
            groupValue: s.settings.material,
            onChanged: (m) { if (m != null) s.settings.setMaterial(m); },
            child: Column(children: [
              for (final m in WindowMaterial.values) RadioListTile<WindowMaterial>(value: m, title: Text(m.label), subtitle: Text(m.note)),
            ]),
          ),
        ],
        heading('Playback'),
        SwitchListTile(
          value: s.settings.explicit,
          onChanged: s.settings.setExplicit,
          title: const Text('Play the explicit version'),
          subtitle: const Text('When a song has both, the explicit or the clean copy plays. Applies to lists loaded after the change.'),
        ),
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
      ]),
    );
  }

  /// A setting on a scale: its name, then the slider between its two ends' words (the Mac app's RangeSlider).
  /// Saved when the drag ends, not on every step of it.
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

/// A slider that moves freely while dragged and saves once, at the end.
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
