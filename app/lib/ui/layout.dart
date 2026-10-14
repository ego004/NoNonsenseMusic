import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Phone windows use bottom navigation rather than the desktop sidebar. This threshold leaves
/// enough room for a readable search field and song rows on compact Android devices.
const phoneWidth = 700.0;

bool isPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).width < phoneWidth;

/// The space between the window's edge and a screen's content. Every screen uses it, so headings, cards and rows
/// start on one line: on a phone they stood at 12, 16, 20, 22, 24 and 32 (13 Oct).
double gutter(BuildContext context) => isPhone(context) ? 20 : 32;

/// The side padding of a list of song rows. A computer's row keeps 10 inside itself, so its cover lines up with the
/// headings; a phone's row is a card, and the card's edge is what lines up.
double rowGutter(BuildContext context) =>
    isPhone(context) ? gutter(context) : gutter(context) - 10;

/// The space above a screen's heading on a phone, where the top bar already stands between it and the status bar.
/// A computer's screens keep their own.
const phoneTop = 12.0;

/// The gap under a song row in a list: a phone's rows are cards, which need air between them.
double songRowGap(BuildContext context) => isPhone(context) ? 8 : 2;

/// The height one song row takes in a list, the gap to the next row included: a row of 56 at the usual text size,
/// taller as Settings › Text size grows, so two lines of larger text still fit.
double songRowExtent(BuildContext context) {
  const lines = 14.0 + 12.5; // the title and the artists
  return 56 + songRowGap(context) + (MediaQuery.textScalerOf(context).scale(lines) - lines).clamp(0, 40) * 1.4;
}
/// "1 song", "12 songs".
String songCount(int n) => n == 1 ? '1 song' : '$n songs';

/// A touch screen: one tap plays and a long-press opens a song's menu, where a mouse double-clicks and right-clicks.
/// By platform, not width: a narrow window on a computer still has a mouse (a phone needed two taps to play, 13 Oct).
bool get isTouchDevice => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// How tall the floating bottom area is (a phone's messages, player bar and bottom bar), so lists can end above it.
/// The shell measures it and puts it here; nothing above the shell has one.
class BottomArea extends InheritedWidget {
  const BottomArea({super.key, required this.height, required super.child});
  final double height;
  @override
  bool updateShouldNotify(BottomArea old) => old.height != height;
}

/// The space a scrolling list leaves after its last row, so that row is not under the player bar. A phone's floating
/// area is measured (its height changes with the gesture strip, larger text, a message); 120 was too little on a
/// phone and the last song sat under the bar (13 Oct). A computer's bar floats at a known height.
double bottomClearance(BuildContext context, {double extra = 0}) {
  final area = context.dependOnInheritedWidgetOfExactType<BottomArea>()?.height ?? 0;
  return area > 0 ? area + 16 + extra : 120 + extra;
}

/// Reports its child's height after each layout that changes it.
class MeasureHeight extends SingleChildRenderObjectWidget {
  const MeasureHeight({super.key, required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;
  @override
  RenderObject createRenderObject(BuildContext context) => RenderMeasureHeight(onHeight);
  @override
  void updateRenderObject(BuildContext context, RenderMeasureHeight renderObject) => renderObject.onHeight = onHeight;
}

class RenderMeasureHeight extends RenderProxyBox {
  RenderMeasureHeight(this.onHeight);
  ValueChanged<double> onHeight;
  double? _last;
  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h != _last) {
      _last = h;
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h)); // not during layout
    }
  }
}
