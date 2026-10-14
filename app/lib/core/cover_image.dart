import 'package:flutter/painting.dart';

import 'download_store.dart';

/// A cover's image for [px] pixels: the file a download keeps for it when there is one (it shows offline), else the
/// network at that size.
ImageProvider coverProvider(String url, {required int px}) {
  final kept = DownloadStore.shared.keptCover(url);
  return kept != null ? FileImage(kept) : NetworkImage(sizedImage(url, px));
}

final _googleWH = RegExp(r'=w\d+-h\d+'), _googleS = RegExp(r'=s\d+'), _saavnSize = RegExp(r'\d+x\d+(?=\.\w+$)');

/// [url] asking its host for [px] pixels. The server sends every image at its largest (1200 px from Google's hosts,
/// 500 from JioSaavn's: services/images.py, #27); a row needs far less: 300 px of a YouTube Music cover is about 40 KB,
/// 1200 px about 300 KB (measured 14 Oct). Other hosts' URLs name no size and stay as they are.
String sizedImage(String url, int px) {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.endsWith('googleusercontent.com') || host.endsWith('ggpht.com')) {
    return url.replaceAll(_googleWH, '=w$px-h$px').replaceAll(_googleS, '=s$px');
  }
  if (host.endsWith('saavncdn.com')) return url.replaceFirst(_saavnSize, px <= 150 ? '150x150' : '500x500'); // its only sizes
  return url;
}
