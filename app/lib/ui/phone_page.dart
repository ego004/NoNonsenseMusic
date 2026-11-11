import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/settings.dart';
import 'friends.dart';
import 'glass.dart';
import 'layout.dart';
import 'now_playing.dart';
import 'player_bar.dart';
import 'scope.dart';

/// A page on a phone, whatever opened it (an album, an artist, Liked Songs, a playlist, Settings): one scaffold, so every
/// page looks and behaves the same, as the iPhone's pushed pages do.
///  - A back button that can always be seen: a round button on the page's own surface. (The pages had a transparent
///    app bar over the route's black, where its dark arrow could not be seen, and some pages had no back button at all.)
///  - The page's backdrop reaches the top of the screen, behind the status bar.
///  - Now Playing is one layer over the whole page, its top included, so no page is half visible above it. (Each page had a
///    layer of its own inside its body, under its app bar, and the shell had another: two screens at once.)
///  - Back steps one layer: Now Playing first, then the page.
class PhonePage extends StatefulWidget {
  final Widget child;

  /// A title in the top row, for pages whose body has none of its own.
  final String? title;
  const PhonePage({super.key, required this.child, this.title});

  @override
  State<PhonePage> createState() => _PhonePageState();
}

class _PhonePageState extends State<PhonePage> {
  /// The dock's height, measured: the page's lists end above it (BottomArea).
  double _dock = 0;

  @override
  Widget build(BuildContext context) {
    final player = Scope.of(context).player;
    final showNav = MediaQuery.viewInsetsOf(context).bottom == 0;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => PopScope(
        canPop: !player.showNowPlaying,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) player.setShowNowPlaying(false);
        },
        child: Material(
          color: Colors.transparent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(child: PhoneBackdrop()),
              SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    SizedBox(
                      height: 56,
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const PageBackButton(),
                          if (widget.title != null) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(widget.title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(child: BottomArea(height: _dock, child: widget.child)),
                  ],
                ),
              ),
              // the same dock the shell draws over its tabs (the mini player and the tab bar), so a song can be started and
              // opened from here and a tab chosen: it goes back to that tab, as on the iPhone
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MeasureHeight(
                  onHeight: (h) {
                    if (mounted && h != _dock) setState(() => _dock = h);
                  },
                  child: ValueListenableBuilder<int>(
                    valueListenable: ShellNav.selected,
                    builder: (context, index, _) => PhoneDock(
                      selected: index,
                      showNav: showNav,
                      onSelect: (i) {
                        Navigator.of(context).popUntil((route) => route.isFirst);
                        ShellNav.tab?.call(i);
                      },
                    ),
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 320),
                layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                transitionBuilder: (child, animation) => phoneRevealTransition(child, animation, dy: 0.12),
                child: player.showNowPlaying
                    ? const NowPlaying(key: ValueKey('page-now-playing'))
                    : const SizedBox.shrink(key: ValueKey('page-now-playing-hidden')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The back button of a page: a round button with its own surface, so it shows on any backdrop, light or dark, and is as
/// large as a thumb needs (48).
class PageBackButton extends StatelessWidget {
  const PageBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Back',
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: Material(
            color: scheme.surface.withValues(alpha: 0.72),
            shape: CircleBorder(side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.10))),
            child: InkResponse(
              onTap: () => Navigator.of(context).maybePop(),
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(FluentIcons.chevron_left_24_regular, size: 22, color: scheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [page] over the shell on a phone: any page already open goes first, so pages do not pile up.
void openPhonePage(BuildContext context, Widget page, {String? title}) {
  Scope.of(context).player.setShowNowPlaying(false);
  final navigator = Navigator.of(context);
  navigator.popUntil((route) => route.isFirst);
  navigator.push(
    PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => PhonePage(title: title, child: page),
      transitionDuration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 300),
      reverseTransitionDuration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 240),
      transitionsBuilder: (_, animation, _, child) => phoneRevealTransition(child, animation, dy: 0.045),
    ),
  );
}

/// The shell's way of choosing a tab, for a page pushed over it: the page's dock calls it after going back to the shell.
class ShellNav {
  static void Function(int index)? tab;

  /// The tab the shell is on (0 Home, 1 Search, 2 Library, 3 Friends), for the dock of a page over it.
  static final selected = ValueNotifier<int>(0);
}

/// The phone's bottom area (the shell's, and every page's): messages, the mini player, the tab bar, over a soft scrim so
/// the rows of a list behind do not show in the gaps between them (they peeked between the player and the bar).
class PhoneDock extends StatelessWidget {
  final Widget? message;
  final int selected;
  final bool showNav;
  final ValueChanged<int> onSelect;
  const PhoneDock({super.key, this.message, required this.selected, required this.showNav, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scrim = scheme.brightness == Brightness.dark ? const Color(0xFF10131C) : scheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [scrim.withValues(alpha: 0), scrim.withValues(alpha: 0.82), scrim.withValues(alpha: 0.96)],
          stops: const [0, 0.35, 1],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: message),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              child: const Center(child: PlayerBar()),
            ),
          ),
          if (showNav)
            Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, MediaQuery.paddingOf(context).bottom + 6),
              child: GlassSurface(
                radius: 28,
                // Settings › Appearance › Surfaces › Bottom bar, as the player bar over it
                blur: 18 * Look.of(context).barBlur,
                solid: Look.of(context).barSolid,
                // the bar pads itself by the system's insets, top and bottom; the bottom one is already given above, and the
                // status bar's stood as an empty band over the icons (13 Oct)
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  removeBottom: true,
                  child: NavigationBar(
                    selectedIndex: selected,
                    onDestinationSelected: onSelect,
                    destinations: [
                      const NavigationDestination(icon: Icon(FluentIcons.home_24_regular), label: 'Home'),
                      const NavigationDestination(icon: Icon(FluentIcons.search_24_regular), label: 'Search'),
                      const NavigationDestination(icon: Icon(FluentIcons.library_24_regular), label: 'Library'),
                      NavigationDestination(icon: FriendsNavIcon(), label: 'Friends'),
                    ],
                  ),
                ),
              ),
            )
          else
            SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ],
      ),
    );
  }
}
