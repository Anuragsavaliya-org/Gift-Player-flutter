import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';

/// Default ceiling for decompressed data (files come from untrusted sources).
const int defaultMaxInflatedBytes = 64 * 1024 * 1024;

String _mb(int n) =>
    '${(n / (1024 * 1024)).toStringAsFixed(n < 1024 * 1024 ? 2 : 0)} MB';

/// Thrown when decompressed data passes the limit: a corrupt file or a decompression bomb.
class InflateLimitError extends GiftPlayerError {
  InflateLimitError(int limit, [String what = 'Decompressed data'])
    : super(
        GiftErrorCode.parseFailed,
        '$what exceeds the limit of ${_mb(limit)} (maxInflatedBytes); the file is corrupt or a decompression bomb.',
      );
}

/// Input is fed in slices this big so the output overshoot past the cap stays small (deflate expands <= ~1032x).
const int _inputSlice = 16 * 1024;

class _CapSink extends ByteConversionSinkBase {
  _CapSink(this.max);

  final int max;
  final List<Uint8List> chunks = [];
  int total = 0;

  @override
  void add(List<int> chunk) {
    total += chunk.length;
    if (total > max) throw InflateLimitError(max);
    chunks.add(
      chunk is Uint8List
          ? Uint8List.fromList(chunk)
          : Uint8List.fromList(chunk),
    );
  }

  @override
  void close() {}
}

/// zlib (or raw deflate when [raw]) inflate that aborts as soon as the output passes [maxBytes].
///
/// Throws [InflateLimitError] over the cap; a [FormatException] / [FileSystemException] for corrupt or truncated input.
Uint8List inflateCapped(
  Uint8List bytes, {
  int maxBytes = defaultMaxInflatedBytes,
  bool raw = false,
}) {
  if (bytes.isEmpty) throw const FormatException('empty zlib stream');
  final sink = _CapSink(maxBytes);
  final conv = ZLibCodec(raw: raw).decoder.startChunkedConversion(sink);
  for (var i = 0; i < bytes.length; i += _inputSlice) {
    final end = i + _inputSlice < bytes.length ? i + _inputSlice : bytes.length;
    conv.add(Uint8List.sublistView(bytes, i, end));
  }
  conv.close();
  if (sink.chunks.length == 1) return sink.chunks.first;
  final out = Uint8List(sink.total);
  var pos = 0;
  for (final c in sink.chunks) {
    out.setRange(pos, pos + c.length, c);
    pos += c.length;
  }
  return out;
}
