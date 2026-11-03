import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';

const int wireVarint = 0;
const int wireFixed64 = 1;
const int wireLen = 2;
const int wireStartGroup = 3;
const int wireEndGroup = 4;
const int wireFixed32 = 5;

const int _maxGroupDepth = 32;

Never parseFail(String message, [Object? cause]) =>
    throw GiftPlayerError(GiftErrorCode.parseFailed, message, cause: cause);

/// Bounds-checked protobuf wire reader. Every failure is a [GiftPlayerError] (`parse-failed`), never a RangeError.
class WireReader {
  WireReader(this.buf, [int start = 0, int? end, ByteData? view])
    : pos = start,
      end = end ?? buf.length,
      _view = view ?? ByteData.sublistView(buf);

  final Uint8List buf;
  int pos;
  final int end;
  final ByteData _view;

  bool get done => pos >= end;

  /// Reads a varint of up to 10 bytes and returns its low 32 bits as an unsigned number.
  /// (The schema has no 64-bit fields, so the high word is validated for length but dropped.)
  int varint() {
    var lo = 0;
    for (var i = 0; i < 10; i++) {
      if (pos >= end) parseFail('Truncated varint at byte $pos');
      final b = buf[pos++];
      if (i < 5) lo |= (b & 0x7f) << (7 * i);
      if ((b & 0x80) == 0) return lo & 0xffffffff;
    }
    return parseFail('Varint longer than 10 bytes ending at byte $pos');
  }

  int int32() {
    final v = varint();
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  /// Reads a field key; returns (fieldNumber, wireType).
  (int, int) tag() {
    final at = pos;
    final key = varint();
    final field = key >> 3;
    if (field == 0) parseFail('Invalid field number 0 at byte $at');
    return (field, key & 7);
  }

  /// fixed32 little-endian IEEE float.
  double float() {
    if (pos + 4 > end) parseFail('Truncated float at byte $pos');
    final v = _view.getFloat32(pos, Endian.little);
    pos += 4;
    return v;
  }

  /// Length-delimited payload as a view (no copy).
  Uint8List bytes() {
    final len = varint();
    if (len > end - pos) {
      parseFail(
        'Length $len at byte $pos runs past the end of the message (${end - pos} bytes left)',
      );
    }
    final out = Uint8List.sublistView(buf, pos, pos + len);
    pos += len;
    return out;
  }

  String string() => utf8.decode(bytes(), allowMalformed: true);

  /// Reader over the next length-delimited payload, sharing the same buffer.
  WireReader message() {
    final len = varint();
    if (len > end - pos) {
      parseFail(
        'Length $len at byte $pos runs past the end of the message (${end - pos} bytes left)',
      );
    }
    final sub = WireReader(buf, pos, pos + len, _view);
    pos += len;
    return sub;
  }

  /// Skips an unknown/mismatched field with the given wire type (including legacy groups).
  void skip(int wireType, [int depth = 0]) {
    switch (wireType) {
      case wireVarint:
        varint();
      case wireFixed64:
        _advance(8);
      case wireLen:
        bytes();
      case wireFixed32:
        _advance(4);
      case wireStartGroup:
        if (depth >= _maxGroupDepth) parseFail('Groups nested too deeply');
        for (;;) {
          if (done) parseFail('Unterminated group');
          final (_, wt) = tag();
          if (wt == wireEndGroup) return;
          skip(wt, depth + 1);
        }
      default:
        parseFail('Unsupported wire type $wireType at byte $pos');
    }
  }

  void _advance(int n) {
    if (pos + n > end) parseFail('Truncated field at byte $pos');
    pos += n;
  }
}
