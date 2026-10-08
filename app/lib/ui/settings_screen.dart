import 'dart:io';

import 'package:flutter/material.dart';

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
            decoration: const InputDecoration(labelText: 'Address', helperText: 'Saved when you press Enter. Your library comes from here.'),
            // a draft, saved on Enter: a field saving every keystroke saved half-typed addresses (the Mac app, 7 Oct)
            onSubmitted: (v) async {
              await s.settings.setServer(v);
              _server.text = s.settings.server;
              await s.library.refresh();
            },
          ),
        ),
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
      ]),
    );
  }
}
