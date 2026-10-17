// UI concept (15 Oct): every menu, dialog and panel on the player's glass, coming in as the Genius window does
// (GlassCard.appear): the blur and the surface come up together while it grows a little past its size and settles.
// Material's were opaque grey sheets that appeared at once.
import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'concept.dart';

/// One line of a [showGlassMenu]: a choice (with a second line of [detail], and a tick when [checked] is true), a line
/// that cannot be chosen, or a divider between groups.
class GlassMenuEntry<T> {
  final T? value;
  final String? label;
  final String? detail;
  final bool? checked; // null: not a line that can be ticked
  final bool enabled;
  const GlassMenuEntry(T this.value, String this.label, {this.detail, this.checked, this.enabled = true});
  const GlassMenuEntry.disabled(String this.label)
      : value = null,
        detail = null,
        checked = null,
        enabled = false;
  const GlassMenuEntry.divider()
      : value = null,
        label = null,
        detail = null,
        checked = null,
        enabled = false;
  bool get isDivider => label == null;
  double get height => isDivider ? _dividerHeight : detail == null ? _rowHeight : _detailRowHeight;
}

const _rowHeight = 36.0, _detailRowHeight = 50.0, _dividerHeight = 9.0, _inset = 6.0, _margin = 8.0, _width = 240.0;

/// Shows a menu at [at] (a point on the screen: where the click was, or a corner of the button) and answers the chosen
/// value, or null when it was dismissed (a click outside, Esc). It opens down and to the right of the point, and up or
/// to the left where the window's edge leaves no room. [width] widens it for longer lines.
Future<T?> showGlassMenu<T>(BuildContext context, Offset at, List<GlassMenuEntry<T>> entries, {double width = _width}) {
  final screen = MediaQuery.sizeOf(context);
  final height = entries.fold(2 * _inset, (h, e) => h + e.height);
  // it grows from the corner at the point
  final left = at.dx + width > screen.width - _margin, up = at.dy + height > screen.height - _margin;
  final origin = Alignment(left ? 1 : -1, up ? 1 : -1);
  final ticks = entries.any((e) => e.checked != null);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close the menu',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 240),
    transitionBuilder: (_, _, _, child) => child, // the glass brings itself in: faded from outside, it showed black
    pageBuilder: (c, animation, _) => CustomSingleChildLayout(
      delegate: _Placement(at),
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, list) {
          final opening = animation.status != AnimationStatus.reverse;
          final appear = (opening ? Curves.easeOutCubic : Curves.easeInCubic).transform(animation.value);
          final grow = (opening ? Curves.easeOutBack : Curves.easeInCubic).transform(animation.value);
          return Transform.scale(
            scale: 0.92 + 0.08 * grow,
            alignment: origin,
            child: GlassCard(appear: appear, radius: 14, padding: const EdgeInsets.all(_inset), child: list!),
          );
        },
        child: SizedBox(
          width: width - 2 * _inset,
          child: Material(
            type: MaterialType.transparency,
            child: FocusTraversalGroup(
              // a long list (Add to Playlist with many playlists) scrolls inside the window's height
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final e in entries) e.isDivider ? const _Divider() : _Row(entry: e, ticks: ticks),
                ]),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A button that opens a [showGlassMenu] below itself: the glass menu's PopupMenuButton.
class GlassMenuButton<T> extends StatelessWidget {
  final List<GlassMenuEntry<T>> Function() entries;
  final ValueChanged<T>? onSelected;
  final String? tooltip;
  final Widget? icon; // an icon button, as PopupMenuButton's default
  final Widget? child; // or a custom face (a label), pressed as a whole
  final double width;
  final bool enabled;
  const GlassMenuButton(
      {super.key, required this.entries, this.onSelected, this.tooltip, this.icon, this.child, this.width = _width, this.enabled = true})
      : assert(icon != null || child != null);

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final chosen = await showGlassMenu<T>(context, box.localToGlobal(box.size.bottomLeft(const Offset(0, 4))), entries(), width: width);
    if (chosen != null) onSelected?.call(chosen);
  }

  @override
  Widget build(BuildContext context) {
    if (child == null) return IconButton(tooltip: tooltip, icon: icon!, onPressed: enabled ? () => _open(context) : null);
    final face = InkWell(
      borderRadius: BorderRadius.circular(6),
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onTap: enabled ? () => _open(context) : null,
      child: child,
    );
    return tooltip == null ? face : Tooltip(message: tooltip!, child: face);
  }
}

class _Placement extends SingleChildLayoutDelegate {
  final Offset at;
  _Placement(this.at);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(const EdgeInsets.all(_margin));

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = at.dx, y = at.dy;
    if (x + child.width > size.width - _margin) x = at.dx - child.width;
    if (y + child.height > size.height - _margin) y = at.dy - child.height;
    return Offset(x.clamp(_margin, size.width - _margin - child.width), y.clamp(_margin, size.height - _margin - child.height));
  }

  @override
  bool shouldRelayout(_Placement old) => old.at != at;
}

class _Row<T> extends StatelessWidget {
  final GlassMenuEntry<T> entry;
  final bool ticks; // a column for ticks, kept on every line so the labels line up
  const _Row({super.key, required this.entry, required this.ticks});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final label = Text(entry.label!, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(color: ink.withValues(alpha: entry.enabled ? 0.92 : 0.4)));
    return SizedBox(
      height: entry.height,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        mouseCursor: entry.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        hoverColor: ink.withValues(alpha: 0.08),
        focusColor: ink.withValues(alpha: 0.12),
        onTap: entry.enabled ? () => Navigator.pop(context, entry.value) : null,
        child: Padding(
          padding: EdgeInsets.only(left: ticks ? 4 : 10, right: 10),
          child: Row(children: [
            if (ticks)
              SizedBox(
                width: 26,
                child: entry.checked == true ? Icon(FluentIcons.checkmark_20_regular, size: 16, color: ink.withValues(alpha: 0.9)) : null,
              ),
            Expanded(
              child: entry.detail == null
                  ? label
                  : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      label,
                      const SizedBox(height: 2),
                      Text(entry.detail!, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: ink.withValues(alpha: 0.55))),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: SizedBox(height: 1, child: ColoredBox(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1))),
      );
}

// ---- dialogs ----

/// How far the route showing a [GlassDialog] has opened: the dialog brings its glass in with it.
class _Opening extends InheritedWidget {
  final Animation<double> animation;
  const _Opening({required this.animation, required super.child});
  static Animation<double>? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Opening>()?.animation;
  @override
  bool updateShouldNotify(_Opening old) => old.animation != animation;
}

/// The glass dialogs' showDialog: [builder] gives a [GlassDialog], which comes in as the Genius window does.
Future<T?> showGlassDialog<T>({required BuildContext context, required WidgetBuilder builder, bool barrierDismissible = true}) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.22),
      transitionDuration: const Duration(milliseconds: 320),
      transitionBuilder: (_, _, _, child) => child, // the glass brings itself in: faded from outside, it showed black
      pageBuilder: (c, animation, _) => _Opening(animation: animation, child: Builder(builder: builder)),
    );

/// A dialog on the player's glass, in place of AlertDialog: an icon, a title, what it says or asks (scrolling when the
/// window is short or the text large), and its buttons (one above the other when they do not fit in a row).
class GlassDialog extends StatelessWidget {
  final Widget? icon, title, content;
  final List<Widget>? actions;
  final EdgeInsets insetPadding;
  const GlassDialog({super.key, this.icon, this.title, this.content, this.actions,
      this.insetPadding = const EdgeInsets.symmetric(horizontal: 32, vertical: 24)});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final animation = _Opening.of(context) ?? kAlwaysCompleteAnimation;
    return AnimatedPadding(
      // the keyboard lifts it, so a field in it stays in view
      padding: insetPadding + MediaQuery.viewInsetsOf(context),
      duration: const Duration(milliseconds: 100),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 460),
          child: AnimatedBuilder(
            animation: animation,
            builder: (_, body) {
              // opening: the glass comes up and it grows past its size and settles; closing: both go quickly
              final opening = animation.status != AnimationStatus.reverse;
              final appear = (opening ? Curves.easeOutCubic : Curves.easeInCubic).transform(animation.value);
              final grow = (opening ? Curves.easeOutBack : Curves.easeInCubic).transform(animation.value);
              return Transform.scale(
                scale: 0.94 + 0.06 * grow,
                child: GlassCard(appear: appear, radius: 22, padding: const EdgeInsets.fromLTRB(24, 22, 16, 12), child: body!),
              );
            },
            child: Material(
              type: MaterialType.transparency,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (icon != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12, right: 8),
                    child: IconTheme(data: IconThemeData(size: 26, color: theme.colorScheme.primary), child: Center(child: icon!)),
                  ),
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12, right: 8),
                    child: DefaultTextStyle(
                      style: theme.textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w700),
                      textAlign: icon != null ? TextAlign.center : TextAlign.start,
                      child: title!,
                    ),
                  ),
                if (content != null)
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(right: 8),
                      child: DefaultTextStyle(
                        style: theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.85), height: 1.4),
                        child: content!,
                      ),
                    ),
                  ),
                if (actions != null && actions!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OverflowBar(spacing: 6, overflowSpacing: 4, overflowAlignment: OverflowBarAlignment.end, children: actions!),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
