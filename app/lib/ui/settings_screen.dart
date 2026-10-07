import 'dart:io';

import 'package:flutter/material.dart';

import '../core/settings.dart';
import 'scope.dart';

/// Settings: the server's address, the window's material (Windows), which version of a song plays.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _server;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _server = TextEditingController(text: Scope.of(context).settings.server);
  }

  @override
  void dispose() {
    _server.dispose();
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
