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

/// One screen, two buttons: Sign In, or Create Account with the same name and password. The server's reason is shown
/// as it comes ("Wrong username or password", "That username is taken"): it is written to be shown.
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
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _go({required bool create}) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    final error = await widget.auth.signIn(_username.text.trim(), _password.text, create: create);
    if (mounted) setState(() { _busy = false; _error = error; });
  }

  /// The server's address, reachable from here too: a wrong one would otherwise lock you out of Settings.
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
    final notice = widget.auth.notice;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: AutofillGroup(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('NoNonsense', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Sign in to your library.', style: theme.textTheme.bodyMedium),
              if (notice != null) ...[
                const SizedBox(height: 16),
                Text(notice, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
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
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Password', helperText: 'A new account: 3–32 characters for the name, 8–64 for the password.'),
                onSubmitted: (_) => _go(create: false),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, key: const ValueKey('signInError'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: FilledButton(onPressed: _busy ? null : () => _go(create: false), child: Text(_busy ? 'One moment…' : 'Sign In'))),
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _go(create: true), child: const Text('Create Account'))),
              ]),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _busy ? null : _changeServer,
                  child: Text('Server: ${widget.settings.server}', style: theme.textTheme.bodySmall),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
