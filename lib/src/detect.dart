import 'dart:typed_data';

import 'errors.dart';
import 'inflate.dart';
import 'svga/wire.dart';
import 'zip.dart';

/// The formats the plugin plays.
enum GiftFormat { svga, gif, webp, pag }

/// What [detectFormat] found out about a file.
class FormatInfo {
  const FormatInfo(this.format, {this.version, this.animated});

  final GiftFormat format;

  /// SVGA only: `'1.x'` or `'2.x'`.
  final String? version;

  /// WebP only: whether the file is animated.
  final bool? animated;

  @override
  String toString() =>
      'FormatInfo(${format.name}${version != null ? ' $version' : ''}${animated != null ? ' animated=$animated' : ''})';
}

bool _startsWith(Uint8List b, List<int> sig, [int offset = 0]) {
  if (b.length < offset + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[offset + i] != sig[i]) return false;
  }
  return true;
}

List<int> _ascii(String s) => s.codeUnits;

final _riff = _ascii('RIFF');
final _webp = _ascii('WEBP');
final _gif87 = _ascii('GIF87a');
final _gif89 = _ascii('GIF89a');
final _pag = _ascii('PAG');
const _zipSig = [0x50, 0x4b, 0x03, 0x04];

/// Cheap structural check that [b] is an SVGA 2.x `MovieEntity`: well-formed wire format, and field 2 `params` present with both
/// fps (3) and frames (4) as varints. Unknown fields are skipped, as protobuf decoders do.
bool _looksLikeMovieEntity(Uint8List b) {
  try {
    final r = WireReader(b);
    var hasParams = false;
    while (!r.done) {
      final (field, wt) = r.tag();
      if (field != 2 || wt != wireLen) {
        r.skip(wt);
        continue;
      }
      final params = r.message();
      var fps = false;
      var frames = false;
      while (!params.done) {
        final (f, w) = params.tag();
        if (f == 3 && w == wireVarint) fps = true;
        if (f == 4 && w == wireVarint) frames = true;
        params.skip(w);
      }
      if (fps && frames) hasParams = true;
    }
    return hasParams;
  } catch (_) {
    return false;
  }
}

/// Inflates [b] and returns the buffer if it is an SVGA 2.x MovieEntity, else null.
Uint8List? _inflateSvga2(Uint8List b, int maxInflatedBytes) {
  try {
    final inflated = inflateCapped(b, maxBytes: maxInflatedBytes);
    return inflated.isNotEmpty && _looksLikeMovieEntity(inflated)
        ? inflated
        : null;
  } on InflateLimitError {
    rethrow; // a decompression bomb is an error, not "unknown format"
  } catch (_) {
    return null;
  }
}

/// Detection result for in-package use. For SVGA 2.x it carries the inflated MovieEntity bytes so the parser does not inflate twice.
class Detected {
  const Detected(this.info, [this.inflated]);
  final FormatInfo info;

  /// Only set for svga 2.x: the zlib-inflated protobuf payload.
  final Uint8List? inflated;
}

/// Animated WebP = extended format (VP8X chunk) with the animation flag (bit 1) set.
bool _isAnimatedWebp(Uint8List b) =>
    _startsWith(b, _ascii('VP8X'), 12) && b.length > 20 && (b[20] & 0x02) != 0;

String _hexHead(Uint8List b) {
  if (b.isEmpty) return '(empty)';
  final n = b.length < 8 ? b.length : 8;
  return [
    for (var i = 0; i < n; i++) b[i].toRadixString(16).padLeft(2, '0'),
  ].join(' ');
}

/// Like [detectFormat] but keeps the inflated SVGA 2.x buffer.
Detected detectInternal(
  Uint8List bytes, {
  int maxInflatedBytes = defaultMaxInflatedBytes,
}) {
  if (_startsWith(bytes, _zipSig)) {
    if (zipHasSvgaMovie(bytes)) {
      return const Detected(FormatInfo(GiftFormat.svga, version: '1.x'));
    }
    throw GiftPlayerError(
      GiftErrorCode.unsupportedFormat,
      'ZIP archive does not contain movie.spec or movie.binary, so it is not an SVGA file.',
    );
  }
  if (_startsWith(bytes, _gif87) || _startsWith(bytes, _gif89)) {
    return const Detected(FormatInfo(GiftFormat.gif));
  }
  if (_startsWith(bytes, _riff) && _startsWith(bytes, _webp, 8)) {
    return Detected(
      FormatInfo(GiftFormat.webp, animated: _isAnimatedWebp(bytes)),
    );
  }
  if (_startsWith(bytes, _pag)) {
    return const Detected(FormatInfo(GiftFormat.pag));
  }
  final inflated = _inflateSvga2(bytes, maxInflatedBytes);
  if (inflated != null) {
    return Detected(
      const FormatInfo(GiftFormat.svga, version: '2.x'),
      inflated,
    );
  }
  throw GiftPlayerError(
    GiftErrorCode.unsupportedFormat,
    'Unsupported or corrupt file (${bytes.length} bytes, header ${_hexHead(bytes)}).',
  );
}

/// Detects the gift format from magic bytes (never from the file extension).
///
/// Throws [GiftPlayerError] (`unsupported-format`) when nothing matches.
FormatInfo detectFormat(
  Uint8List bytes, {
  int maxInflatedBytes = defaultMaxInflatedBytes,
}) => detectInternal(bytes, maxInflatedBytes: maxInflatedBytes).info;
