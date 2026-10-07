import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

/// One place in the sidebar, Windows 11 style: a quiet hover, and when selected a soft fill with a short accent bar at
/// its left edge (not a coloured pill). Icon 18, label 13.5.
class SideItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const SideItem({super.key, required this.icon, required this.label, required this.selected, required this.onTap});
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
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: widget.selected ? ink.withValues(alpha: 0.075) : hover ? ink.withValues(alpha: 0.04) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            Container(
              width: 3,
              height: 16,
              decoration: BoxDecoration(color: widget.selected ? theme.colorScheme.primary : Colors.transparent, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 10),
            Icon(widget.icon, size: 18, color: widget.selected ? ink : ink.withValues(alpha: 0.7)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500, color: widget.selected ? ink : ink.withValues(alpha: 0.82))),
            ),
          ]),
        ),
      ),
    );
  }
}

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
