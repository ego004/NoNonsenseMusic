import 'package:flutter/material.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';

import '../core/models.dart';
import 'layout.dart';

const _plain = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ú': 'u',
  'ù': 'u', 'û': 'u', 'ü': 'u', 'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
};

String _fold(String s) => s.toLowerCase().split('').map((c) => _plain[c] ?? c).join();

/// Whether a song matches what was typed in a list's Search: every word in its title, artists or album, ignoring case
/// and accents ("beyonce" finds "Beyoncé"), as the Mac app does.
bool songMatches(Track t, String query) {
  final words = _fold(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final text = _fold([t.best.title, t.best.album ?? '', ...t.best.artists].join(' '));
  return words.every(text.contains);
}

/// A list's Search: narrows the songs shown to those matching what is typed (Liked Songs, Recently Played, a playlist).
/// Called Search, not Filter: it finds by words (13 Oct)
class FilterField extends StatelessWidget {
  const FilterField({super.key, required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 40,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => TextField(
          controller: controller,
          decoration: InputDecoration(
            isDense: true,
            // a phone's fields are padded for a taller box than this one: the hint stood above the icon's line
            contentPadding: isPhone(context) ? const EdgeInsets.symmetric(vertical: 10) : null,
            hintText: 'Search',
            prefixIcon: const Icon(FluentIcons.search_24_regular, size: 18),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(icon: const Icon(FluentIcons.dismiss_24_regular, size: 16), tooltip: 'Clear', onPressed: controller.clear),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
          ),
        ),
      ),
    );
  }
}
