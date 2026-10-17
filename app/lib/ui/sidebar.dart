import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import 'concept.dart';

/// A sidebar entry styled after the Windows 11 navigation rail.
///
/// The row is transparent until the pointer enters it, when it takes a faint fill. The selected row takes a stronger
/// fill, a short accent bar at its left edge rather than a coloured pill, and a heavier label. Icons are 18 px and
/// labels 13.5 px.
class SideItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  /// Shown at the row's end, for a count.
  final Widget? trailing;
  const SideItem({super.key, required this.icon, required this.label, required this.selected, required this.onTap, this.trailing});
  @override
  State<SideItem> createState() => _SideItemState();
}

class _SideItemState extends State<SideItem> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // the concept (13 Oct): the fill fades, and the accent bar springs up beside the chosen entry
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 36,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            // Selected fill outweighs hover fill so the current entry stays visible while the pointer moves.
            color: widget.selected ? ink.withValues(alpha: 0.075) : hover ? ink.withValues(alpha: 0.04) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            // The bar is laid out even when hidden so the label does not shift between states.
            AnimatedContainer(
              duration: const Duration(milliseconds: 340),
              // the spring overshoots its end: on the way down to nothing it would ask for a height below zero
              curve: widget.selected ? spring : Curves.easeOutCubic,
              width: 3,
              height: widget.selected ? 16 : 0,
              decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 10),
            Icon(widget.icon, size: 18, color: widget.selected ? theme.colorScheme.primary : ink.withValues(alpha: 0.7)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500, color: widget.selected ? ink : ink.withValues(alpha: 0.82))),
            ),
            if (widget.trailing != null) widget.trailing!,
          ]),
        ),
      ),
    );
  }
}

/// A group heading rendered above a run of [SideItem]s.
///
/// The text is uppercased and set at 11 px with wide letter spacing. The 20 px of space above it separates a new
/// group from the entry above.
class SideHeading extends StatelessWidget {
  final String text;
  const SideHeading(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(13, 20, 0, 6),
        child: Text(text.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45))),
      );
}

const homeIcon = FluentIcons.home_24_regular;
