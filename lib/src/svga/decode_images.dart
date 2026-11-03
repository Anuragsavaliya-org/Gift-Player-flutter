import 'dart:ui' as ui;

import '../renderer.dart';
import 'types.dart';

/// Decoded images of an SVGA movie, and the keys that could not be decoded.
class DecodedSvgaImages {
  DecodedSvgaImages(this.bitmaps, this.failed);
  final Map<String, ui.Image> bitmaps;

  /// Keys whose bytes the codec could not decode (they are simply absent from [bitmaps]).
  final List<String> failed;
}

/// Decodes every raw image of a parsed movie. The caller owns the images and must release them with [releaseSvgaImages].
Future<DecodedSvgaImages> decodeSvgaImages(SvgaMovie movie) async {
  final entries = movie.images.entries.toList();
  final results = await Future.wait(
    entries.map((e) async {
      try {
        return await decodeImageBytes(e.value.data);
      } catch (_) {
        return null;
      }
    }),
  );
  final bitmaps = <String, ui.Image>{};
  final failed = <String>[];
  for (var i = 0; i < entries.length; i++) {
    final img = results[i];
    if (img == null) {
      failed.add(entries[i].key);
    } else {
      bitmaps[entries[i].key] = img;
    }
  }
  return DecodedSvgaImages(bitmaps, failed);
}

/// Disposes every image in the map and empties it.
void releaseSvgaImages(Map<String, ui.Image> bitmaps) {
  for (final b in bitmaps.values) {
    b.dispose();
  }
  bitmaps.clear();
}
