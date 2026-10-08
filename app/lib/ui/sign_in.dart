import 'dart:io';

import 'package:flutter/material.dart';

import '../core/auth.dart';
import '../core/settings.dart';

/// The sign-in screen until a session exists, then the app (AUTH-1). A session that ends (expired, or signed out on
/// another device) brings the screen back, saying so.
class AuthGate extends StatelessWidget {
  final Auth auth;
  final Settings settings;
  final WidgetBuilder signedIn;
  const AuthGate({super.key, required this.auth, required this.settings, required this.signedIn});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: auth,
        builder: (context, _) => switch (auth.state) {
          // a moment at launch, while the stored token is checked: nothing to draw yet
          AuthState.checking => ColoredBox(color: Theme.of(context).colorScheme.surface),
          AuthState.signedOut => SignInScreen(auth: auth, settings: settings),
          // its own key per account: the next account starts from a fresh window, not this one's screens
          AuthState.signedIn => KeyedSubtree(key: ValueKey(auth.user?.id), child: signedIn(context)),
        },
      );
}

/// Sign in, or create an account (one switch between the two), like the Mac app's (8 Oct): a title, the fields, one
/// filled button; no notes. The rules show only when broken: the server's reason ("Wrong username or password", "That
/// username is taken") is written to be shown. The device name starts as the computer's name, shown so you see what
/// is sent, and yours to change.
class SignInScreen extends StatefulWidget {
  final Auth auth;
  final Settings settings;
  const SignInScreen({super.key, required this.auth, required this.settings});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final _device = TextEditingController(text: widget.settings.deviceName);
  bool _creating = false;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _device.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    final error = await widget.auth.signIn(_username.text.trim(), _password.text, create: _creating, device: _device.text);
    if (error == null) await widget.settings.setDeviceName(_device.text.trim().isEmpty ? Auth.computerName : _device.text.trim());
    if (mounted) setState(() { _busy = false; _error = error; });
  }

  /// "127.0.0.1:8000" rather than "http://127.0.0.1:8000"; the scheme shows only when it is not plain http.
  static String _short(String address) {
    final u = Uri.tryParse(address);
    if (u == null || u.host.isEmpty) return address;
    final hostPort = u.hasPort ? '${u.host}:${u.port}' : u.host;
    return u.scheme == 'https' ? 'https://$hostPort' : hostPort;
  }

  /// The server's address, changed here or in Settings › Server. Red when it could not be reached.
  Future<void> _changeServer() async {
    final field = TextEditingController(text: widget.settings.server);
    final address = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Server'),
        content: TextField(controller: field, autofocus: true, decoration: const InputDecoration(labelText: 'Address'),
            onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, field.text), child: const Text('Save')),
        ],
      ),
    );
    if (address != null) {
      await widget.settings.setServer(address);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notice = _creating ? null : widget.auth.notice;
    final action = _creating ? (_busy ? 'Creating…' : 'Create Account') : (_busy ? 'Signing In…' : 'Sign In');
    return Scaffold(
      // the window's acrylic shows through, as in the app (shell.dart)
      backgroundColor: Platform.isWindows ? Colors.transparent : theme.colorScheme.surface,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: AutofillGroup(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(_creating ? 'Create Account' : 'Sign In',
                  textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
              if (notice != null) ...[
                const SizedBox(height: 6),
                Text(notice, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 20),
              TextField(
                controller: _username,
                autofocus: true,
                enabled: !_busy,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Username'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autofillHints: [_creating ? AutofillHints.newPassword : AutofillHints.password],
                decoration: InputDecoration(labelText: _creating ? 'Password (8 or more characters)' : 'Password'),
                onSubmitted: (_) => _go(),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _device,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Device Name', prefixIcon: Icon(Icons.computer_outlined)),
                onSubmitted: (_) => _go(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, key: const ValueKey('signInError'), textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 20),
              FilledButton(onPressed: _busy ? null : _go, child: Text(action)),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : () => setState(() { _creating = !_creating; _error = null; }),
                child: Text(_creating ? 'Sign In Instead' : 'Create Account…'),
              ),
              // the server: yours to choose before signing in (8 Oct); Settings › Server changes it later
              TextButton(
                onPressed: _busy ? null : _changeServer,
                child: Text('Server: ${_short(widget.settings.server)}',
                    style: theme.textTheme.bodySmall?.copyWith(color: widget.auth.unreachable ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
