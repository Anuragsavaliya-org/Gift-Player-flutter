import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'inflate.dart';

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xffffffff;

/// One entry of a zip central directory.
class ZipEntry {
  ZipEntry(
    this.name,
    this.method,
    this.compressedSize,
    this.size,
    this.localOffset,
  );
  final String name;
  final int method;
  final int compressedSize;
  final int size;
  final int localOffset;
}

/// Index of the end-of-central-directory record, or -1. The record is 22 bytes plus up to 65535 bytes of comment.
int _findEocd(Uint8List b) {
  final stop = b.length - 22 - 0xffff > 0 ? b.length - 22 - 0xffff : 0;
  for (var i = b.length - 22; i >= stop; i--) {
    if (b[i] == 0x50 &&
        b[i + 1] == 0x4b &&
        b[i + 2] == 0x05 &&
        b[i + 3] == 0x06) {
      return i;
    }
  }
  return -1;
}

/// Lists the central directory. Returns null if it is not a readable zip. Entry order is arbitrary.
List<ZipEntry>? readZipDirectory(Uint8List b) {
  final eocd = _findEocd(b);
  if (eocd < 0) return null;
  final count = _u16(b, eocd + 10);
  var pos = _u32(b, eocd + 16);
  final out = <ZipEntry>[];
  for (var n = 0; n < count; n++) {
    if (pos + 46 > b.length || _u32(b, pos) != 0x02014b50) return null;
    final method = _u16(b, pos + 10);
    final compSize = _u32(b, pos + 20);
    final size = _u32(b, pos + 24);
    final nameLen = _u16(b, pos + 28);
    final extraLen = _u16(b, pos + 30);
    final commentLen = _u16(b, pos + 32);
    final local = _u32(b, pos + 42);
    if (pos + 46 + nameLen > b.length) return null;
    final name = utf8.decode(
      Uint8List.sublistView(b, pos + 46, pos + 46 + nameLen),
      allowMalformed: true,
    );
    out.add(ZipEntry(name, method, compSize, size, local));
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

/// True if the zip's central directory lists `movie.spec` or `movie.binary`.
bool zipHasSvgaMovie(Uint8List b) {
  final dir = readZipDirectory(b);
  if (dir == null) return false;
  return dir.any((e) => e.name == 'movie.spec' || e.name == 'movie.binary');
}

/// Extracts every file. The declared uncompressed sizes are checked against [maxBytes] before anything is inflated.
///
/// Throws [InflateLimitError] over the limit and [GiftPlayerError] (`parse-failed`) for an unreadable archive.
Map<String, Uint8List> unzip(
  Uint8List b, {
  int maxBytes = defaultMaxInflatedBytes,
}) {
  final dir = readZipDirectory(b);
  if (dir == null) {
    throw GiftPlayerError(
      GiftErrorCode.parseFailed,
      'Not a valid SVGA file: could not read the zip archive.',
    );
  }
  var declared = 0;
  for (final e in dir) {
    declared += e.size;
    if (e.size > maxBytes || declared > maxBytes) {
      throw InflateLimitError(
        maxBytes,
        'Zip entry "${e.name}" (declared ${e.size} bytes; $declared in total)',
      );
    }
  }
  final files = <String, Uint8List>{};
  for (final e in dir) {
    if (e.name.endsWith('/')) continue;
    final lo = e.localOffset;
    if (lo + 30 > b.length || _u32(b, lo) != 0x04034b50) {
      throw GiftPlayerError(
        GiftErrorCode.parseFailed,
        'Not a valid SVGA file: bad zip local header for "${e.name}".',
      );
    }
    final start = lo + 30 + _u16(b, lo + 26) + _u16(b, lo + 28);
    final end = start + e.compressedSize;
    if (end > b.length) {
      throw GiftPlayerError(
        GiftErrorCode.parseFailed,
        'Not a valid SVGA file: zip entry "${e.name}" is truncated.',
      );
    }
    final data = Uint8List.sublistView(b, start, end);
    if (e.method == 0) {
      files[e.name] = data;
    } else if (e.method == 8) {
      try {
        files[e.name] = e.size == 0
            ? Uint8List(0)
            : inflateCapped(data, maxBytes: maxBytes, raw: true);
      } on GiftPlayerError {
        rethrow;
      } catch (cause) {
        throw GiftPlayerError(
          GiftErrorCode.parseFailed,
          'Not a valid SVGA file: could not inflate zip entry "${e.name}".',
          cause: cause,
        );
      }
    } else {
      throw GiftPlayerError(
        GiftErrorCode.parseFailed,
        'Not a valid SVGA file: zip entry "${e.name}" uses unsupported compression method ${e.method}.',
      );
    }
  }
  return files;
}
