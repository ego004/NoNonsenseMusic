import 'package:flutter/material.dart';

import 'command_bar.dart';
import 'jam_panel.dart';
import 'layout.dart';
import 'notifications.dart';
import 'redesign.dart';

/// Puts the top bar above [child], the screen.
///
/// On a computer (15 Oct): the search and command box at the left, where the page's content starts, and Jam with the
/// bell at the right. With no [places] (the Search page, which has its own field) the box is left out. On a phone the bar sits
/// below the status bar with Jam and the bell: one short row, so a screen keeps nearly all its height.
class TopBarFrame extends StatelessWidget {
  final Widget child;
  final CommandPlaces? places;
  const TopBarFrame({super.key, required this.child, this.places});

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
    final side = gutter(context);
    return Column(children: [
      SafeArea(
        bottom: false,
        child: phone
            ? SizedBox(
                height: 48,
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [JamButton(), NotificationsButton(), const SizedBox(width: 8)]),
              )
            : Padding(
                padding: EdgeInsets.fromLTRB(side, 14, side, 0),
                child: Row(children: [
                  if (places != null)
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: CommandBar(places: places!)),
                      ),
                    )
                  else
                    const Spacer(),
                  const SizedBox(width: 12),
                  TopActions(bell: NotificationsButton()),
                ]),
              ),
      ),
      Expanded(child: child),
    ]);
  }
}
