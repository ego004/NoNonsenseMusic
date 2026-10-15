import 'dart:io';

import 'package:flutter/material.dart';

import '../core/auth.dart';
import '../core/settings.dart';
import 'glass.dart';
import 'recovery_codes.dart';
import 'glass_menu.dart';

/// Show the sign-in screen until a session exists, then the signed-in app. A session that ends (expired, or signed
/// out on another device) brings the screen back, with a notice saying so.
class AuthGate extends StatelessWidget {
  final Auth auth;
  final Settings settings;
  final WidgetBuilder signedIn;
  const AuthGate({
    super.key,
    required this.auth,
    required this.settings,
    required this.signedIn,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: auth,
    builder: (context, _) => switch (auth.state) {
      // shown at launch while the stored token is checked: there is nothing to draw yet
      AuthState.checking => ColoredBox(
        color: Theme.of(context).colorScheme.surface,
      ),
      AuthState.signedOut => SignInScreen(auth: auth, settings: settings),
      // a key per account: the next account starts from a fresh stack, not this account's screens
      AuthState.signedIn => KeyedSubtree(
        key: ValueKey(auth.user?.id),
        child: RecoveryCodesHost(
          auth: auth,
          child: Builder(builder: signedIn),
        ),
      ),
    },
  );
}

/// Sign in or create an account, with one toggle between the two, and "Forgot Password?" for a new password with a
/// recovery code: a title, the fields, a single filled button, and no explanatory notes. Validation rules are shown
/// only when broken: the server's reason ("Wrong username or password", "That username is taken") is written to be
/// displayed as is. The device name starts as the computer's name, shown
/// so the user sees what will be sent, and the user can change it.
class SignInScreen extends StatefulWidget {
  final Auth auth;
  final Settings settings;
  const SignInScreen({super.key, required this.auth, required this.settings});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

/// Signing in, making an account, or setting a new password with a recovery code.
enum _Mode { signIn, create, recover }

class _SignInScreenState extends State<SignInScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  late final _device = TextEditingController(text: widget.settings.deviceName);
  final _code = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool get _creating => _mode == _Mode.create;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _device.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Send the form to the server, save the device name on success, and show the server's error if there is one.
  Future<void> _go() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = _username.text.trim();
    final error = _mode == _Mode.recover
        ? await widget.auth.recover(
            name,
            _code.text.trim(),
            _password.text,
            device: _device.text,
          )
        : await widget.auth.signIn(
            name,
            _password.text,
            create: _creating,
            device: _device.text,
          );
    if (error == null) {
      await widget.settings.setDeviceName(
        _device.text.trim().isEmpty ? Auth.computerName : _device.text.trim(),
      );
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  void _switchTo(_Mode next) => setState(() {
    _mode = next;
    _error = null;
    _password.clear();
  });

  /// Format an address as "127.0.0.1:8000" rather than "http://127.0.0.1:8000"; a scheme is kept only when it is
  /// https, so plain http addresses show bare host and port.
  static String _short(String address) {
    final u = Uri.tryParse(address);
    if (u == null || u.host.isEmpty) return address;
    final hostPort = u.hasPort ? '${u.host}:${u.port}' : u.host;
    return u.scheme == 'https' ? 'https://$hostPort' : hostPort;
  }

  /// Prompt for the server's address; Settings › Server sets the same address. The address is shown in red while
  /// the server cannot be reached.
  Future<void> _changeServer() async {
    final field = TextEditingController(text: widget.settings.server);
    final address = await showGlassDialog<String>(
      context: context,
      builder: (c) => GlassDialog(
        title: const Text('Server'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Address'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, field.text),
            child: const Text('Save'),
          ),
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
    final notice = _mode == _Mode.signIn ? widget.auth.notice : null;
    final title = switch (_mode) {
      _Mode.signIn => 'Sign In',
      _Mode.create => 'Create Account',
      _Mode.recover => 'Reset Password',
    };
    final action = switch (_mode) {
      _Mode.signIn => _busy ? 'Signing In…' : 'Sign In',
      _Mode.create => _busy ? 'Creating…' : 'Create Account',
      _Mode.recover => _busy ? 'Resetting…' : 'Reset Password',
    };
    final mobile = Platform.isAndroid || Platform.isIOS;
    final form = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: mobile ? 390 : 300),
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (notice != null) ...[
              const SizedBox(height: 6),
              Text(
                notice,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
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
            if (_mode == _Mode.recover) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _code,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'Recovery Code',
                  hintText: 'XXXX-XXXX-XXXX-XXXX',
                ),
                textInputAction: TextInputAction.next,
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              autofillHints: [
                _mode == _Mode.signIn
                    ? AutofillHints.password
                    : AutofillHints.newPassword,
              ],
              decoration: InputDecoration(
                labelText: switch (_mode) {
                  _Mode.signIn => 'Password',
                  _Mode.create => 'Password (8 or more characters)',
                  _Mode.recover => 'New Password (8 or more characters)',
                },
              ),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _device,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Device Name',
                prefixIcon: Icon(Icons.computer_outlined),
              ),
              onSubmitted: (_) => _go(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const ValueKey('signInError'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _go, child: Text(action)),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _switchTo(
                          _mode == _Mode.signIn ? _Mode.create : _Mode.signIn,
                        ),
                  child: Text(
                    _mode == _Mode.signIn
                        ? 'Create Account…'
                        : 'Sign In Instead',
                  ),
                ),
                if (_mode == _Mode.signIn)
                  TextButton(
                    onPressed: _busy ? null : () => _switchTo(_Mode.recover),
                    child: const Text('Forgot Password?'),
                  ),
              ],
            ),
            // the server: the user picks it before signing in; Settings › Server changes it later
            TextButton(
              onPressed: _busy ? null : _changeServer,
              child: Text(
                'Server: ${_short(widget.settings.server)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: widget.auth.unreachable
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Scaffold(
      backgroundColor: Platform.isWindows || mobile
          ? Colors.transparent
          : theme.colorScheme.surface,
      body: mobile
          ? Stack(
              children: [
                const Positioned.fill(child: PhoneBackdrop()),
                SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: GlassSurface(
                        radius: 28,
                        padding: const EdgeInsets.all(24),
                        child: form,
                      ),
                    ),
                  ),
                ),
              ],
            )
          // scrolls when the window is shorter than the form, which overflowed it
          : Center(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: form)),
    );
  }
}
