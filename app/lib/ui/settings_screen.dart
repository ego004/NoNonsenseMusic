import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/android_sound.dart';
import '../core/api.dart';
import '../core/discord.dart';
import '../core/settings.dart';
import '../core/translation.dart';
import 'account_settings.dart';
import 'layout.dart';
import 'redesign.dart';
import 'scope.dart';
import 'storage_settings.dart';
import 'update_flow.dart';

/// Builds the settings screen: account and sign out, the server's address, the appearance (the window's material on
/// Windows, its surfaces, sizes and colours), playback choices, lyrics, and Discord presence.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _checkingUpdate = false;

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
    return ListenableBuilder(
      listenable: s.settings,
      builder: (context, _) => ListView(padding: EdgeInsets.fromLTRB(gutter(context), isPhone(context) ? phoneTop : 28, gutter(context), bottomClearance(context)), children: [
        Text('Settings', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
        ..._card(context, 'Account', [
        Row(children: [
          const Expanded(child: Text('Username')),
          Flexible(child: Text(s.auth.user?.username ?? 'Not signed in', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
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
        ]),
        ..._card(context, 'Server', [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: TextField(
            controller: _server,
            decoration: InputDecoration(labelText: 'Address', helperText: isTouchDevice ? 'Saved when you press Done.' : 'Saved when you press Enter.'),
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
            Flexible(child: Text(ok.data == null ? 'Checking…' : ok.data! ? 'Connected' : 'Not reachable')),
          ]),
        ),
        ]),
        ..._card(context, 'Appearance', [
        _scrolls(SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, label: Text('System')),
            ButtonSegment(value: ThemeMode.light, label: Text('Light')),
            ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
          ],
          selected: {s.settings.themeShown},
          // a solid background is one colour, light or dark: it sets the theme while it is chosen
          onSelectionChanged: s.settings.material.theme == null ? (v) => s.settings.setTheme(v.first) : null,
        )),
        if (Platform.isWindows && s.settings.material.theme != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Set by the ${s.settings.material.label} window, below.', style: theme.textTheme.bodySmall),
          ),
        // Settings › Appearance as on the Mac (#29): the window, its surfaces one part at a time, sizes, colours
        if (Platform.isWindows) ...[
          _subheading(context, 'Window'),
          RadioGroup<WindowMaterial>(
            groupValue: s.settings.material,
            onChanged: (m) { if (m != null) s.settings.setMaterial(m); },
            child: Column(children: [
              for (final m in WindowMaterial.values) RadioListTile<WindowMaterial>(value: m, title: Text(m.label), subtitle: Text(m.note)),
            ]),
          ),
        ],
        ]),
        ..._card(context, 'Surfaces', [
        const _Surfaces(),
        ]),
        ..._card(context, 'Sizes', [
        _slider(context, 'Text size', s.settings.textScale, 0.85, 1.4, 'Smaller', 'Larger', s.settings.setTextScale),
        _slider(context, 'Card size', s.settings.look.cardSize, 116, 210, 'Small', 'Large', (v) => s.settings.setLook(s.settings.look.copyWith(cardSize: v))),
        // the sizes, live: a card at half its size and a song's two lines, as on the Mac
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Container(
              width: s.settings.look.cardSize * 0.45,
              height: s.settings.look.cardSize * 0.45,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(colors: Collection.liked.colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Song title', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600)),
                Text('Artist', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              ]),
            ),
          ]),
        ),
        Text('Text: everywhere. Cards: the covers on Home, in the Library and in albums, shown here at half size.', style: theme.textTheme.bodySmall),
        ]),
        ..._card(context, 'Colours', [
        _ColourRow(
          title: 'Accent',
          detail: 'Buttons, selections and the playing song. System: blue',
          mode: s.settings.look.accent,
          colour: s.settings.look.accentColour,
          setMode: (m) => s.settings.setLook(s.settings.look.copyWith(accent: m)),
          setColour: (c) => s.settings.setLook(s.settings.look.copyWith(accentColour: c)),
        ),
        _ColourRow(
          title: 'Background',
          detail: 'The colour behind the lists and Now Playing. System: none',
          mode: s.settings.look.background,
          colour: s.settings.look.backgroundColour,
          setMode: (m) => s.settings.setLook(s.settings.look.copyWith(background: m)),
          setColour: (c) => s.settings.setLook(s.settings.look.copyWith(backgroundColour: c)),
        ),
        Text("Song: the playing cover's colour. Custom: type a hex code or pick a colour.", style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text('Colours, surfaces and sizes back to how they came', style: theme.textTheme.bodySmall)),
          const SizedBox(width: 8),
          Flexible(child: OutlinedButton(onPressed: s.settings.resetLook, child: const Text('Reset All', maxLines: 1))),
        ]),
        ]),
        ..._card(context, 'Playback', [
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
          subtitle: const Text('At every launch and every 4 hours, asks GitHub whether a newer version exists.'),
        ),
        ListTile(
          title: const Text('Check for Updates Now'),
          subtitle: FutureBuilder<String>(
            future: PackageInfo.fromPlatform().then((v) => v.version).catchError((_) => ''),
            builder: (_, v) => Text('Version ${v.data ?? ''}'),
          ),
          trailing: _checkingUpdate ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          onTap: _checkingUpdate
              ? null
              : () async {
                  setState(() => _checkingUpdate = true);
                  try {
                    await runUpdateFlow(context, manual: true);
                  } finally {
                    if (mounted) setState(() => _checkingUpdate = false);
                  }
                },
        ),
        SwitchListTile(
          value: s.settings.explicit,
          onChanged: s.settings.setExplicit,
          title: const Text('Play the explicit version'),
          subtitle: const Text('When a song has both, the explicit or the clean copy plays. Applies to lists loaded after the change.'),
        ),
        if (AndroidSound.available) ...[_subheading(context, 'Sound'), const _AndroidSoundSettings()],
        ]),
        ..._card(context, 'Storage', [
        const StorageSettings(),
        ]),
        ..._card(context, 'Lyrics', [
        // the question the two answers below are for: without it, "When a song starts" read as lyrics showing by
        // themselves (20 Oct). As on the Mac (Settings › Lyrics › Load lyrics)
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Load lyrics'),
          subtitle: Text("Ahead of time loads them as a song starts, and the next song's too. Downloaded songs keep theirs offline."),
        ),
        RadioGroup<bool>(
          groupValue: s.settings.lyricsEarly,
          onChanged: (v) { if (v != null) s.settings.setLyricsEarly(v); },
          child: const Column(children: [
            RadioListTile<bool>(value: true, title: Text("Ahead of time, so they're ready when I open them")),
            RadioListTile<bool>(value: false, title: Text('Only when I open Lyrics')),
          ]),
        ),
        _slider(context, 'Line movement', s.settings.lyricsMotion, 0.3, 1.5, 'Quick', 'Slow', s.settings.setLyricsMotion),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Translate into'),
          subtitle: const Text('For Translate in Lyrics. Google translates them; only their text is sent.'),
          trailing: _Fit(child: DropdownButton<String>(isExpanded: true,
            value: s.settings.translateInto,
            onChanged: (v) { if (v != null) s.settings.setTranslateInto(v); },
            items: [
              const DropdownMenuItem(value: '', child: Text('System language')),
              for (final MapEntry(key: code, value: name) in LyricsTranslations.languages.entries)
                DropdownMenuItem(value: code, child: Text(name)),
            ],
          )),
        ),
        SwitchListTile(
          value: s.settings.geniusNotes,
          onChanged: s.settings.setGeniusNotes,
          title: const Text('Genius notes (experimental)'),
          subtitle: const Text('Underlined lines open what Genius says about them; ⓘ shows About This Song. One more lookup per song.'),
        ),
        ]),
        ..._card(context, 'Discord', [
        const _DiscordSettings(),
        ]),
      ]),
    );
  }
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
        Flexible(child: Text(low, style: small, maxLines: 1, overflow: TextOverflow.ellipsis)),
        Expanded(flex: 3, child: _Slide(value: value, min: min, max: max, save: save)),
        Flexible(child: Text(high, style: small, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
    ]),
  );
}

/// The parts of the window Settings › Appearance › Surfaces sets one at a time, as on the Mac (SurfacePart).
enum _Part { main, bar, nowPlaying }

/// Settings › Appearance › Surfaces: pick a part, and what can be set for it is under it. Fewer than on the Mac: Now
/// Playing fills the window here, so it has no blur or see-through of its own (its text would stand on whatever page is
/// under it, which #20's rule cannot keep readable), and the window's blur is Window, above.
class _Surfaces extends StatefulWidget {
  const _Surfaces();
  @override
  State<_Surfaces> createState() => _SurfacesState();
}

class _SurfacesState extends State<_Surfaces> {
  var _part = _Part.main;

  @override
  Widget build(BuildContext context) {
    final settings = Scope.of(context).settings;
    final look = settings.look;
    final phone = isPhone(context);
    Future<void> set(Look next) => settings.setLook(next);
    Widget note(String text) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        );
    // stretched, as the page's own controls are (the Theme picker, Text size)
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _scrolls(SegmentedButton<_Part>(
        showSelectedIcon: false,
        segments: [
          const ButtonSegment(value: _Part.main, label: Text('Main area')),
          // a phone's player bar and tabs float together over the lists
          ButtonSegment(value: _Part.bar, label: Text(phone ? 'Bottom bar' : 'Player bar')),
          const ButtonSegment(value: _Part.nowPlaying, label: Text('Now Playing')),
        ],
        selected: {_part},
        onSelectionChanged: (v) => setState(() => _part = v.first),
      )),
      const SizedBox(height: 12),
      ...switch (_part) {
        // softer only: the text on the window has nothing over the cover's colours but a light veil
        _Part.main => [
            _slider(context, 'Colour strength', look.artStrength, 0, Look.defaultStrength, 'Soft', 'Full', (v) => set(look.copyWith(artStrength: v))),
            note('Behind the lists and Home. The colour comes from Colours › Background.'),
          ],
        _Part.bar => [
            _slider(context, 'Blur', look.barBlur, 0, 1, 'Clear', 'Frosted', (v) => set(look.copyWith(barBlur: v))),
            _slider(context, 'Transparency', look.barSolid, 0, 1, 'See-through', 'Solid', (v) => set(look.copyWith(barSolid: v))),
            // measured 18 Oct, a profile build on a laptop (i5-12450HX), a list scrolled under the bar for 6 s: the median
            // frame took 0.3 ms (a phone's two bars) to 0.6 ms (a computer's) longer to draw with the blur, about a third
            note(phone
                ? 'The player bar and the tabs. Blur is drawn again with every frame the list under them moves, about a '
                    'third more drawing while you scroll: a phone starts without it, for the battery.'
                : 'Blur is drawn again with every frame the list under the bar moves: about a third more drawing while '
                    'you scroll.'),
          ],
        _Part.nowPlaying => [
            _slider(context, 'Colour strength', look.nowPlayingColour, 0, 1, 'Soft', 'Vivid', (v) => set(look.copyWith(nowPlayingColour: v))),
            note("The cover's colours behind Now Playing, kept where its text reads on them, however vivid."),
          ],
      },
    ]);
  }
}

/// Colours you can pick with a tap (the Mac's system colours); Custom's hex code takes any other.
const _picks = [
  Color(0xFF0A84FF), Color(0xFF5E5CE6), Color(0xFFBF5AF2), Color(0xFFFF375F), Color(0xFFFF453A),
  Color(0xFFFF9F0A), Color(0xFFFFD60A), Color(0xFF30D158), Color(0xFF64D2FF), Color(0xFF8E8E93),
];

/// One coloured part, as on the Mac (ThemeRow): System, Song or Custom. Song shows the colour it takes now; Custom a
/// hex code, saved on Enter, and colours to pick.
class _ColourRow extends StatefulWidget {
  final String title, detail;
  final ColourMode mode;
  final Color colour;
  final void Function(ColourMode) setMode;
  final void Function(Color) setColour;
  const _ColourRow({required this.title, required this.detail, required this.mode, required this.colour, required this.setMode, required this.setColour});
  @override
  State<_ColourRow> createState() => _ColourRowState();
}

class _ColourRowState extends State<_ColourRow> {
  late final _hex = TextEditingController(text: hexOf(widget.colour));

  @override
  void didUpdateWidget(_ColourRow old) {
    super.didUpdateWidget(old);
    if (old.colour != widget.colour) _hex.text = hexOf(widget.colour);
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final song = Look.of(context).song;
    Widget swatch(Color c, {VoidCallback? onTap, bool chosen = false}) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(color: chosen ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withValues(alpha: 0.15), width: chosen ? 2 : 1),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title),
        Text(widget.detail, style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _scrolls(SegmentedButton<ColourMode>(
            showSelectedIcon: false,
            segments: [for (final m in ColourMode.values) ButtonSegment(value: m, label: Text(m.label))],
            selected: {widget.mode},
            onSelectionChanged: (v) => widget.setMode(v.first),
          )),
          if (widget.mode == ColourMode.song)
            Tooltip(
              message: song == null ? "No colourful cover playing: the system's colour is used" : "The playing cover's colour",
              child: swatch(song ?? theme.colorScheme.onSurface.withValues(alpha: 0.3)),
            ),
          if (widget.mode == ColourMode.custom) ...[
            SizedBox(
              width: 96,
              child: TextField(
                controller: _hex,
                decoration: const InputDecoration(isDense: true, hintText: '#RRGGBB'),
                onSubmitted: (text) {
                  final c = colourFromHex(text);
                  c == null ? _hex.text = hexOf(widget.colour) : widget.setColour(c); // not a colour: back to the one set
                },
              ),
            ),
            for (final c in _picks)
              Tooltip(message: hexOf(c), child: swatch(c, onTap: () => widget.setColour(c), chosen: c == widget.colour)),
          ],
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


/// Android's own equalizer and loudness boost (core/android_sound.dart). Its bands are the phone's: their number and
/// frequencies are not the Mac app's 14. They appear once a song has played, which is when the phone reports them.
class _AndroidSoundSettings extends StatelessWidget {
  const _AndroidSoundSettings();

  @override
  Widget build(BuildContext context) {
    final sound = AndroidSound.shared;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: sound,
      builder: (context, _) {
        final found = sound.parameters;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            value: sound.on,
            onChanged: found == null ? null : sound.setOn,
            title: const Text('Equalizer'),
            subtitle: Text(found == null ? 'Available once a song has played.' : 'Your phone\'s own, not the Mac\'s 14 bands.'),
          ),
          if (found != null && sound.on)
            for (var i = 0; i < found.bands.length; i++)
              Row(children: [
                SizedBox(width: 52, child: Text(frequencyLabel(found.bands[i].centerFrequency), style: theme.textTheme.bodySmall)),
                Expanded(
                  child: Slider(
                    value: (i < sound.gains.length ? sound.gains[i] : 0).clamp(found.minDecibels, found.maxDecibels).toDouble(),
                    min: found.minDecibels,
                    max: found.maxDecibels,
                    onChanged: (v) => sound.setBand(i, v),
                  ),
                ),
                SizedBox(width: 48, child: Text('${(i < sound.gains.length ? sound.gains[i] : 0).toStringAsFixed(1)} dB', style: theme.textTheme.bodySmall)),
              ]),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(sound.boost > 0 ? 'Loudness boost: +${sound.boost.toStringAsFixed(0)} dB' : 'Loudness boost: off'),
            subtitle: const Text('Louder, up to 12 dB. Loud songs can distort.'),
          ),
          Slider(value: sound.boost, min: 0, max: AndroidSound.maxBoost, divisions: 12, onChanged: sound.setBoost),
        ]);
      },
    );
  }
}

/// A section of Settings: its heading, then its controls on one rounded card, as the iPhone's grouped Settings has them.
List<Widget> _card(BuildContext context, String title, List<Widget> children) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 0, 8),
      child: Text(title,
          style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
    ),
    // a Material, not a coloured box: the ListTiles inside paint their ink on the nearest Material
    Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: dark ? 0.38 : 0.7),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.onSurface.withValues(alpha: 0.055)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    ),
  ];
}

/// A heading inside a card, for a group within a section.
Widget _subheading(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
    );

/// A row of segments that is wider than a narrow phone at a large text size scrolls sideways instead of overflowing (at 200% the
/// three segments of Appearance and Surfaces were wider than the screen).
Widget _scrolls(Widget row) => SingleChildScrollView(scrollDirection: Axis.horizontal, child: row);

