import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// In-place updates, as the Mac app's Sparkle does them: once per launch the app reads the latest release's
/// update.json (scripts/make-update-feeds.py), and a newer version is offered with its notes. Update downloads this
/// platform's file, checks its length and its Ed25519 signature against the release key built into the app (a file
/// not signed by it is refused and deleted), then installs it: Windows runs the setup silently, which closes the app
/// and opens the new version; Android hands the APK to its installer. The one request the app makes that does not go
/// to your server; Settings › Check for updates turns it off.
class UpdateInfo {
  const UpdateInfo(this.version, this.notes, this.file, this.page);
  final String version; // "0.4.1"
  final String notes; // what is new, as the release says it (Markdown)
  final UpdateFile? file; // this platform's, or null: then only the page
  final Uri page; // the release's page
}

class UpdateFile {
  const UpdateFile(this.name, this.url, this.length, this.signature);
  final String name;
  final Uri url;
  final int length;
  final List<int> signature; // Ed25519, 64 bytes
}

/// Why an update was not installed, worded to be shown as it is.
class UpdateRefused implements Exception {
  UpdateRefused(this.text);
  final String text;
  @override
  String toString() => text;
}

const _releases = 'https://github.com/ego004/NoNonsenseMusic/releases';
final latestFeed = Uri.parse('$_releases/latest/download/update.json');

/// The release key's public half (Sparkle's generate_keys, account nononsensemusic; the Mac app's SUPublicEDKey).
/// --dart-define=NN_UPDATE_KEY=… replaces it for a test build.
const releaseKey = String.fromEnvironment('NN_UPDATE_KEY', defaultValue: 'y+sgiLPBeRJEb6RlazvQX1I7wFl2CpuBdxUGl6eViJs=');

/// This platform's file in a release. On Windows only for the installed app (installer.iss puts it in
/// %LOCALAPPDATA%\Programs\NoNonsenseMusic): the setup installs there, so run from an unzipped folder it would leave
/// that copy as it was and install a second one. An unzipped copy gets the release page instead.
String? get platformFile {
  if (Platform.isAndroid) return 'NoNonsenseMusic-Android.apk';
  if (!Platform.isWindows) return null;
  final installed = '${Platform.environment['LOCALAPPDATA'] ?? ''}\\Programs\\NoNonsenseMusic\\'.toLowerCase();
  return Platform.resolvedExecutable.toLowerCase().startsWith(installed) ? 'NoNonsenseMusic-Setup.exe' : null;
}

/// What a look at the feed found: [update] when a newer release than the current one (and not a skipped one) is out;
/// [reached] says whether GitHub answered at all, so "up to date" can be told from "could not look".
class UpdateLookup {
  const UpdateLookup(this.update, {required this.reached});
  final UpdateInfo? update;
  final bool reached;
}

Future<UpdateLookup> lookUpUpdate(
    {required String current, String? skipped, http.Client? client, Uri? feed, String? file}) async {
  try {
    final r = await (client ?? http.Client()).get(feed ?? latestFeed).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return const UpdateLookup(null, reached: false);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final version = j['version'] as String;
    if (!isNewer(version, current) || version == skipped) return const UpdateLookup(null, reached: true);
    final files = j['files'] as Map<String, dynamic>? ?? const {};
    final mine = files[file ?? platformFile] as Map<String, dynamic>?;
    return UpdateLookup(
      UpdateInfo(
        version,
        j['notes'] as String? ?? '',
        mine == null
            ? null
            : UpdateFile(file ?? platformFile!, Uri.parse(mine['url'] as String), (mine['length'] as num).toInt(),
                base64Decode(mine['ed_signature'] as String)),
        Uri.parse('$_releases/tag/v$version'),
      ),
      reached: true,
    );
  } catch (_) {
    return const UpdateLookup(null, reached: false);
  }
}

/// A newer release than [current] that is not [skipped], or null (none, skipped, or GitHub not reachable).
Future<UpdateInfo?> checkForUpdate(
        {required String current, String? skipped, http.Client? client, Uri? feed, String? file}) async =>
    (await lookUpUpdate(current: current, skipped: skipped, client: client, feed: feed, file: file)).update;

/// [file] downloaded into [folder], its length and signature checked against [key] (base64): the path to install, or
/// [UpdateRefused] (the file deleted). [progress] gets the share downloaded, 0 to 1.
Future<File> downloadUpdate(UpdateFile file, Directory folder,
    {String key = releaseKey, http.Client? client, void Function(double)? progress}) async {
  final publicKey = _key(key);
  await folder.create(recursive: true);
  final out = File('${folder.path}${Platform.pathSeparator}${file.name}');
  final c = client ?? http.Client();
  try {
    final response = await c.send(http.Request('GET', file.url)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw UpdateRefused('The download answered ${response.statusCode}.');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
      if (bytes.length > file.length) break;
      progress?.call(bytes.length / file.length);
    }
    final data = bytes.takeBytes();
    if (data.length != file.length) {
      throw UpdateRefused('The download is not the size the release says (${data.length} of ${file.length} bytes).');
    }
    final valid = await Ed25519().verify(data,
        signature: Signature(file.signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
    if (!valid) throw UpdateRefused('The download is not signed by NoNonsenseMusic’s release key, so it was not installed.');
    await out.writeAsBytes(data, flush: true);
    return out;
  } on UpdateRefused {
    if (await out.exists()) await out.delete();
    rethrow;
  } on TimeoutException {
    throw UpdateRefused('The download stopped answering.');
  } on SocketException catch (e) {
    throw UpdateRefused('The download failed: ${e.message}.');
  } finally {
    if (client == null) c.close();
  }
}

List<int> _key(String base64Key) {
  try {
    final bytes = base64Decode(base64Key);
    if (bytes.length == 32) return bytes;
  } on FormatException {
    // below
  }
  throw UpdateRefused('This build has no release key, so it cannot check an update. Download it from the release page.');
}

const _channel = MethodChannel('nononsense/update');

/// Android only: may this app install other apps (itself, updated)? Always true elsewhere. Asked before the download, so
/// the permission is not found missing after it.
Future<bool> installAllowed() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _channel.invokeMethod<bool>('allowed') ?? true;
  } on MissingPluginException {
    return true;
  }
}

/// Android: opens the page where "Install unknown apps" is allowed for this app.
Future<void> openInstallSettings() => _channel.invokeMethod<void>('settings');

/// Installs a checked download. Windows: the setup, silently; it closes this app and opens the new version (installer.iss),
/// so this app quits ([quit]). Android: the system's installer, which asks first (and, the first time, for permission to
/// install from this app). Returns what the user is told, or null when there is nothing to say.
Future<String?> installUpdate(File file, {void Function()? quit}) async {
  if (Platform.isWindows) {
    await Process.start(file.path, ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached);
    (quit ?? () => exit(0))();
    return null;
  }
  if (Platform.isAndroid) {
    final answer = await _channel.invokeMethod<String>('install', {'path': file.path});
    return answer == 'permission'
        ? 'Allow NoNonsenseMusic to install apps, then tap Update again.'
        : null;
  }
  return null;
}

/// A build for the update self-test (`--dart-define=NN_SELFTEST_UPDATE_FEED=<update.json>`, with NN_UPDATE_KEY the test
/// key): at launch it reads that feed and runs the update as Update does, saying each step in the log ("SELFTEST update:").
const updateSelfTestFeed = String.fromEnvironment('NN_SELFTEST_UPDATE_FEED');

Future<void> runUpdateSelfTest() async {
  void say(String text) => debugPrint('SELFTEST update: $text');
  final current = (await PackageInfo.fromPlatform()).version;
  say('this app is $current');
  final update = await checkForUpdate(current: current, feed: Uri.parse(updateSelfTestFeed));
  if (update?.file == null) return say('no update found');
  try {
    final folder = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}nononsense-update');
    final file = await downloadUpdate(update!.file!, folder);
    say('downloaded and checked ${update.version}');
    say(await installUpdate(file) ?? 'handed to the installer');
  } on UpdateRefused catch (e) {
    say('refused: ${e.text}');
  }
}

/// "0.10.0" is newer than "0.9.1": compared number by number, a missing number counting as 0.
bool isNewer(String a, String b) {
  final x = [for (final p in a.split('.')) int.tryParse(p) ?? 0], y = [for (final p in b.split('.')) int.tryParse(p) ?? 0];
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}
