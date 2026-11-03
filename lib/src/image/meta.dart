import 'dart:typed_data';

import '../errors.dart';

/// Timing/size metadata for GIF and WebP, read from the container without decoding any pixels (pixels are decoded by the
/// platform codec through `dart:ui`).
///
/// Rules (identical to the web package):
/// * Delay clamping: a delay of 10 ms or less is shown as 100 ms (browsers do this because 0-delay GIFs were meant to be "as fast as
///   possible"). Applied to every frame, whatever the codec reports.
/// * Loop count is normalised to the TOTAL number of plays (0 = forever): GIF NETSCAPE loop N -> N + 1 plays (N = 0 forever), no
///   extension -> 1 play; WebP ANIM loop N -> N plays (N = 0 forever).
const int minDelayMs = 10;
const int clampedDelayMs = 100;

double clampDelay(num ms) =>
    ms <= minDelayMs ? clampedDelayMs.toDouble() : ms.toDouble();

class ImageMeta {
  ImageMeta({
    required this.format,
    required this.width,
    required this.height,
    required this.animated,
    required this.frameCount,
    required this.durations,
    required this.loopCount,
  });

  final String format; // 'gif' | 'webp'

  /// Intrinsic canvas size; 0 for a still WebP without VP8X (the decoder reports it).
  final int width, height;

  /// false for a still image.
  final bool animated;
  final int frameCount;

  /// Clamped durations in ms, one per frame.
  final List<double> durations;

  /// Total plays from the file (0 = forever), or null for stills.
  final int? loopCount;
}

Never _fail(String fmt, String msg) =>
    throw GiftPlayerError(GiftErrorCode.parseFailed, '$fmt: $msg');

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

ImageMeta readGifMeta(Uint8List b) {
  if (b.length < 13 || b[0] != 0x47 || b[1] != 0x49 || b[2] != 0x46) {
    _fail('GIF', 'missing GIF header');
  }
  final width = _u16(b, 6), height = _u16(b, 8);
  if (width == 0 || height == 0) {
    _fail('GIF', 'invalid logical screen size ${width}x$height');
  }
  final flags = b[10];
  var pos = 13;
  if ((flags & 0x80) != 0) {
    final n = 3 * (1 << ((flags & 7) + 1));
    if (pos + n > b.length) _fail('GIF', 'truncated global colour table');
    pos += n;
  }
  final delays = <int>[];
  int? netscape;
  var delayCs = 0;

  int skipSubBlocks(int p) {
    while (p < b.length) {
      final len = b[p];
      p += 1 + len;
      if (len == 0) return p;
    }
    return b.length + 1; // ran off the end: truncated
  }

  while (pos < b.length) {
    final tag = b[pos];
    if (tag == 0x3b) break; // trailer
    if (tag == 0x21) {
      final label = pos + 1 < b.length ? b[pos + 1] : -1;
      if (label == 0xf9 && pos + 6 < b.length && b[pos + 2] == 4) {
        delayCs = _u16(b, pos + 4);
      } else if (label == 0xff && pos + 17 < b.length && b[pos + 2] == 11) {
        final id = String.fromCharCodes(b.sublist(pos + 3, pos + 14));
        if ((id == 'NETSCAPE2.0' || id == 'ANIMEXTS1.0') &&
            b[pos + 14] == 3 &&
            b[pos + 15] == 1) {
          netscape = _u16(b, pos + 16);
        }
      }
      pos = skipSubBlocks(pos + 2);
      continue;
    }
    if (tag == 0x2c) {
      if (pos + 10 > b.length) break;
      final fl = b[pos + 9];
      pos += 10;
      if ((fl & 0x80) != 0) {
        final n = 3 * (1 << ((fl & 7) + 1));
        if (pos + n > b.length) break;
        pos += n;
      }
      if (pos >= b.length) break;
      final end = skipSubBlocks(pos + 1);
      delays.add(delayCs);
      delayCs = 0;
      if (end > b.length) {
        break; // truncated image data: keep the frame, stop parsing
      }
      pos = end;
      continue;
    }
    break; // unknown block: stop
  }
  if (delays.isEmpty) _fail('GIF', 'no image data');
  return ImageMeta(
    format: 'gif',
    width: width,
    height: height,
    animated: delays.length > 1,
    frameCount: delays.length,
    durations: [for (final d in delays) clampDelay(d * 10)],
    loopCount: netscape == null ? 1 : (netscape == 0 ? 0 : netscape + 1),
  );
}

String _fourcc(Uint8List b, int o) => String.fromCharCodes(b.sublist(o, o + 4));
int _u24(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);
int _u32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xffffffff;

ImageMeta readWebpMeta(Uint8List b) {
  if (b.length < 20 || _fourcc(b, 0) != 'RIFF' || _fourcc(b, 8) != 'WEBP') {
    _fail('WebP', 'missing RIFF/WEBP header');
  }
  final end = b.length < _u32(b, 4) + 8 ? b.length : _u32(b, 4) + 8;
  final top = <(String, int, int)>[]; // type, payload start, size
  var p = 12;
  while (p + 8 <= end) {
    final size = _u32(b, p + 4);
    final payload = p + 8;
    if (payload + size > end) break; // truncated: ignore the partial chunk
    top.add((_fourcc(b, p), payload, size));
    p = payload + size + (size & 1); // payloads are padded to even length
  }
  (String, int, int)? find(String t) {
    for (final c in top) {
      if (c.$1 == t) return c;
    }
    return null;
  }

  final vp8x = find('VP8X');
  final anim = find('ANIM');
  final flags = vp8x != null ? b[vp8x.$2] : 0;
  final animated = (flags & 0x02) != 0;
  final width = vp8x != null ? 1 + _u24(b, vp8x.$2 + 4) : 0;
  final height = vp8x != null ? 1 + _u24(b, vp8x.$2 + 7) : 0;
  if (!animated) {
    return ImageMeta(
      format: 'webp',
      width: width,
      height: height,
      animated: false,
      frameCount: 1,
      durations: [clampedDelayMs.toDouble()],
      loopCount: null,
    );
  }
  final durations = <double>[];
  for (final c in top) {
    if (c.$1 != 'ANMF') continue;
    if (c.$3 < 16) _fail('WebP', 'ANMF chunk too small');
    durations.add(clampDelay(_u24(b, c.$2 + 12)));
  }
  if (durations.isEmpty) _fail('WebP', 'animation flag set but no ANMF frames');
  final loops = anim == null ? null : (b[anim.$2 + 4] | (b[anim.$2 + 5] << 8));
  return ImageMeta(
    format: 'webp',
    width: width,
    height: height,
    animated: true,
    frameCount: durations.length,
    durations: durations,
    loopCount: loops == null || loops == 0 ? 0 : loops,
  );
}
