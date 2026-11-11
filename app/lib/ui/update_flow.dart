import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/update_check.dart';
import 'glass_menu.dart';
import 'scope.dart';

/// The update dialogs, shared by the two ways in: the shell's check at launch and every 4 hours, and Settings › Check for
/// Updates Now. "NoNonsenseMusic 0.4.1 is available", with what is new; Update downloads it, checks its signature and
/// installs it (core/update_check.dart); a platform with no file in the release opens the release page instead. Skip
/// This Version is not offered again by the automatic check (a check asked for in Settings offers it anyway).
///
/// Android asks the system's permission to install from this app before anything is downloaded. That page can restart
/// the app, so the choice to update is kept (Settings.pendingUpdate) and [resumePendingUpdate] carries on from it.
bool _busy = false;

/// Looks for an update and offers it. [manual] (Settings): works with automatic checks off, offers a skipped version, and
/// says so when there is nothing newer or GitHub could not be reached. [confirmed] goes straight to the download, as
/// someone who already said Update and came back from allowing installs.
Future<void> runUpdateFlow(BuildContext context, {bool manual = false, bool confirmed = false}) async {
  if (_busy || !context.mounted) return; // a dialog or an install is already open
  _busy = true;
  try {
    await _run(context, manual: manual, confirmed: confirmed);
  } finally {
    _busy = false;
  }
}

/// Back in the app after the permission page: if an update was chosen, it goes on.
Future<void> resumePendingUpdate(BuildContext context) async {
  final settings = Scope.of(context).settings;
  final pending = settings.pendingUpdate;
  if (pending == null) return;
  await settings.setPendingUpdate(null);
  if (!context.mounted) return;
  final allowed = await installAllowed();
  if (!context.mounted) return;
  await runUpdateFlow(context, manual: true, confirmed: allowed);
}

Future<void> _run(BuildContext context, {required bool manual, required bool confirmed}) async {
  final settings = Scope.of(context).settings;
  if (!manual && !settings.checkUpdates) return;
  final current = (await PackageInfo.fromPlatform()).version;
  final lookup = await lookUpUpdate(current: current, skipped: manual ? null : settings.skippedUpdate);
  if (!context.mounted) return;
  final update = lookup.update;
  if (update == null) {
    if (manual) {
      await _say(context, lookup.reached ? 'You’re up to date' : 'Couldn’t check',
          lookup.reached ? 'NoNonsenseMusic $current is the latest version.' : 'GitHub did not answer. Check the connection and try again.');
    }
    return;
  }
  var choice = confirmed ? 'update' : null;
  choice ??= await showGlassDialog<String>(
    context: context,
    builder: (c) => GlassDialog(
      title: Text('NoNonsenseMusic ${update.version} is available'),
      content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('You have $current.'),
        if (update.notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(plainNotes(update.notes), style: Theme.of(c).textTheme.bodySmall),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, 'skip'), child: const Text('Skip This Version')),
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Not Now')),
        FilledButton(
          onPressed: () => Navigator.pop(c, 'update'),
          child: Text(update.file == null ? 'Open Release Page' : 'Update'),
        ),
      ],
    ),
  );
  if (choice == 'skip') await settings.skipUpdate(update.version);
  if (choice != 'update' || !context.mounted) return;
  final file = update.file;
  if (file == null) {
    await launchUrl(update.page, mode: LaunchMode.externalApplication);
    return;
  }
  if (!await installAllowed()) {
    if (!context.mounted) return;
    final go = await showGlassDialog<bool>(
      context: context,
      builder: (c) => GlassDialog(
        title: const Text('Allow installing updates'),
        content: const Text('Android needs your permission before NoNonsenseMusic can install its own update. Turn on '
            '“Allow from this source” on the next page, then come back: the update carries on from there.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Not Now')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open Settings')),
        ],
      ),
    );
    if (go == true) {
      await settings.setPendingUpdate(update.version);
      await openInstallSettings();
    }
    return;
  }
  if (!context.mounted) return;
  await _install(context, update, file);
}

/// Downloads, checks and installs: a progress bar meanwhile, and why it failed when it does.
Future<void> _install(BuildContext context, UpdateInfo update, UpdateFile file) async {
  final share = ValueNotifier<double>(0);
  final navigator = Navigator.of(context);
  showGlassDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => GlassDialog(
      title: Text('Updating to ${update.version}'),
      content: ValueListenableBuilder<double>(
        valueListenable: share,
        builder: (_, value, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          LinearProgressIndicator(value: value > 0 ? value : null),
          const SizedBox(height: 8),
          Text(value < 1 ? 'Downloading… ${(value * 100).round()}%' : 'Installing…'),
        ]),
      ),
    ),
  );
  String? problem, said;
  try {
    final folder = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}nononsense-update');
    final downloaded = await downloadUpdate(file, folder, progress: (v) => share.value = v);
    share.value = 1;
    said = await installUpdate(downloaded); // Windows: the app quits here, and the new version opens
  } on UpdateRefused catch (e) {
    problem = e.text;
  } catch (e) {
    problem = 'Something went wrong: $e';
  }
  if (!context.mounted) return;
  navigator.pop();
  if (problem == null && said == null) return;
  final open = await showGlassDialog<bool>(
    context: context,
    builder: (c) => GlassDialog(
      title: Text(problem == null ? 'One more step' : 'Couldn’t update'),
      content: Text(problem ?? said!),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
        if (problem != null) FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open Release Page')),
      ],
    ),
  );
  if (open == true) await launchUrl(update.page, mode: LaunchMode.externalApplication);
}

Future<void> _say(BuildContext context, String title, String text) => showGlassDialog<void>(
      context: context,
      builder: (c) => GlassDialog(
        title: Text(title),
        content: Text(text),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );

/// The release notes as plain lines: headings and bullets without their Markdown marks.
String plainNotes(String markdown) => markdown
    .split('\n')
    .map((l) => l.startsWith('## ') ? l.substring(3) : l.startsWith('- ') ? '• ${l.substring(2)}' : l)
    .map((l) => l.replaceAll('**', '').replaceAll('`', ''))
    .join('\n')
    .trim();
