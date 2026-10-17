import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/account_api.dart';
import '../core/api.dart';
import '../core/auth.dart';
import 'glass_menu.dart';

/// Shows the dialog with the account's recovery codes once, when [Auth.codesToShow] has some (a new account). It sits
/// above the signed-in app and cannot be dismissed until the codes are copied.
class RecoveryCodesHost extends StatefulWidget {
  final Auth auth;
  final Widget child;
  const RecoveryCodesHost({super.key, required this.auth, required this.child});
  @override
  State<RecoveryCodesHost> createState() => _RecoveryCodesHostState();
}

class _RecoveryCodesHostState extends State<RecoveryCodesHost> {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.auth.removeListener(_check);
    super.dispose();
  }

  Future<void> _check() async {
    final codes = widget.auth.codesToShow;
    if (_showing || codes == null || !mounted) return;
    _showing = true;
    await showRecoveryCodes(context, codes, widget.auth.user?.username ?? '');
    _showing = false;
    widget.auth.codesShown();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The ten recovery codes, shown once: after sign-up, and after Settings › Account makes a new set. The server keeps
/// only their hashes, so this dialog is the only place they can be read. It cannot be dismissed, and Done is enabled
/// once the codes are copied, so it is not closed before they are kept somewhere.
Future<void> showRecoveryCodes(BuildContext context, List<String> codes, String username) => showGlassDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RecoveryCodesDialog(codes: codes, username: username),
    );

class RecoveryCodesDialog extends StatefulWidget {
  final List<String> codes;
  final String username;
  const RecoveryCodesDialog({super.key, required this.codes, required this.username});
  @override
  State<RecoveryCodesDialog> createState() => _RecoveryCodesDialogState();
}

class _RecoveryCodesDialogState extends State<RecoveryCodesDialog> {
  bool _copied = false;

  /// The codes as a short text: the app, the account, then one code per line.
  String get text => 'NoNonsenseMusic recovery codes for ${widget.username}\n\n${widget.codes.join('\n')}\n';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codes = widget.codes;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13);
    return PopScope(
      canPop: false,
      child: GlassDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        icon: Icon(FluentIcons.key_24_regular, color: theme.colorScheme.primary),
        title: const Text('Save Your Recovery Codes', textAlign: TextAlign.center),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                'If you forget your password, a code lets you set a new one. Each code works once, and they are not shown again.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
                // scaled down on a narrow screen rather than cut: a code must be read whole
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Table(
                    defaultColumnWidth: const IntrinsicColumnWidth(),
                    children: [
                      for (var i = 0; i < codes.length; i += 2)
                        TableRow(children: [
                          Padding(padding: const EdgeInsets.fromLTRB(0, 4, 28, 4), child: SelectableText(codes[i], style: mono)),
                          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: SelectableText(i + 1 < codes.length ? codes[i + 1] : '', style: mono)),
                        ]),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: Icon(_copied ? FluentIcons.checkmark_24_regular : FluentIcons.copy_24_regular, size: 18),
            label: Text(_copied ? 'Copied' : 'Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (mounted) setState(() => _copied = true);
            },
          ),
          FilledButton(
            onPressed: _copied ? () => Navigator.of(context).pop() : null,
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

/// Settings › Account › New Recovery Codes: the password again, then the new set. Returns the new codes, or null when
/// cancelled.
Future<List<String>?> askNewRecoveryCodes(BuildContext context) => showGlassDialog<List<String>>(
      context: context,
      builder: (_) => const _NewCodesDialog(),
    );

class _NewCodesDialog extends StatefulWidget {
  const _NewCodesDialog();
  @override
  State<_NewCodesDialog> createState() => _NewCodesDialogState();
}

class _NewCodesDialogState extends State<_NewCodesDialog> {
  final _password = TextEditingController();
  String? _problem;
  bool _working = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_password.text.isEmpty || _working) return;
    setState(() { _working = true; _problem = null; });
    try {
      final codes = await AccountApi.newCodes(_password.text);
      if (mounted) Navigator.of(context).pop(codes);
    } on ApiError catch (e) {
      if (mounted) setState(() { _working = false; _problem = e.toString(); }); // a 401 is "Wrong password.", not a sign-out
    } catch (_) {
      if (mounted) setState(() { _working = false; _problem = "Can't connect to the server."; });
    }
  }

  @override
  Widget build(BuildContext context) => GlassDialog(
        title: const Text('New Recovery Codes'),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Your current codes stop working.', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: true,
              enabled: !_working,
              decoration: const InputDecoration(labelText: 'Password'),
              onChanged: (_) { if (_problem != null) setState(() => _problem = null); },
              onSubmitted: (_) => _go(),
            ),
            if (_problem != null) ...[
              const SizedBox(height: 10),
              Text(_problem!, key: const ValueKey('codesProblem'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: _working ? null : _go, child: Text(_working ? 'Making…' : 'Make New Codes')),
        ],
      );
}
