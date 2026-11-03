import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal protobuf encoder + synthetic gift builders for tests (no real .svga/.webp files are needed or committed).
class Pb {
  final BytesBuilder _b = BytesBuilder();

  Uint8List done() => _b.toBytes();

  void _varint(int v) {
    var n = v & 0xffffffffffffffff;
    while (n >= 0x80) {
      _b.addByte((n & 0x7f) | 0x80);
      n >>= 7;
    }
    _b.addByte(n);
  }

  void _tag(int field, int wt) => _varint((field << 3) | wt);

  Pb varint(int field, int v) {
    _tag(field, 0);
    _varint(v < 0 ? v & 0xffffffff : v);
    return this;
  }

  Pb f32(int field, double v) {
    _tag(field, 5);
    final d = ByteData(4)..setFloat32(0, v, Endian.little);
    _b.add(d.buffer.asUint8List());
    return this;
  }

  Pb bytes(int field, List<int> data) {
    _tag(field, 2);
    _varint(data.length);
    _b.add(data);
    return this;
  }

  Pb str(int field, String s) => bytes(field, utf8.encode(s));

  Pb msg(int field, Pb m) => bytes(field, m.done());
}

Pb _floats(List<double> v) {
  final p = Pb();
  for (var i = 0; i < v.length; i++) {
    p.f32(i + 1, v[i]);
  }
  return p;
}

/// 1x1 transparent-ish red PNG.
final Uint8List tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
);

Pb frame({
  double alpha = 1,
  List<double>? layout,
  List<double>? transform,
  String? clip,
  List<Pb> shapes = const [],
}) {
  final f = Pb();
  if (alpha != 0) f.f32(1, alpha);
  if (layout != null) f.msg(2, _floats(layout));
  if (transform != null) f.msg(3, _floats(transform));
  if (clip != null) f.str(4, clip);
  for (final s in shapes) {
    f.msg(5, s);
  }
  return f;
}

/// A filled rect shape (type 1) with an RGBA fill in 0..1.
Pb rectShape(
  double x,
  double y,
  double w,
  double h,
  List<double> rgba, {
  double radius = 0,
}) => Pb()
  ..varint(1, 1)
  ..msg(3, _floats([x, y, w, h, radius]))
  ..msg(10, Pb()..msg(1, _floats(rgba)));

Pb keepShape() => Pb()..varint(1, 3);

Pb pathShape(String d, List<double> rgba) => Pb()
  ..varint(1, 0)
  ..msg(2, Pb()..str(1, d))
  ..msg(10, Pb()..msg(1, _floats(rgba)));

Pb sprite(String key, List<Pb> frames, {String? matte}) {
  final s = Pb()..str(1, key);
  for (final f in frames) {
    s.msg(2, f);
  }
  if (matte != null) s.str(3, matte);
  return s;
}

/// SVGA 2.x file: zlib(MovieEntity).
Uint8List svga2({
  double w = 100,
  double h = 100,
  int fps = 10,
  required int frames,
  Map<String, List<int>> images = const {},
  required List<Pb> sprites,
  bool compress = true,
}) {
  final m = Pb()
    ..str(1, '2.0.0')
    ..msg(
      2,
      Pb()
        ..f32(1, w)
        ..f32(2, h)
        ..varint(3, fps)
        ..varint(4, frames),
    );
  images.forEach(
    (k, v) => m.msg(
      3,
      Pb()
        ..str(1, k)
        ..bytes(2, v),
    ),
  );
  for (final s in sprites) {
    m.msg(4, s);
  }
  final raw = m.done();
  return compress ? Uint8List.fromList(zlib.encode(raw)) : raw;
}

/// Stored (uncompressed) zip with the given files; [deflate] files use raw deflate.
Uint8List zipOf(Map<String, List<int>> files, {bool deflate = false}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  int crc(List<int> d) {
    var c = 0xffffffff;
    for (final b in d) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (c >> 1) ^ 0xedb88320 : c >> 1;
      }
    }
    return (c ^ 0xffffffff) & 0xffffffff;
  }

  void u16(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  files.forEach((name, data) {
    final nameBytes = utf8.encode(name);
    final comp = deflate ? ZLibCodec(raw: true).encode(data) : data;
    final method = deflate ? 8 : 0;
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0);
    u16(out, method);
    u16(out, 0);
    u16(out, 0);
    u32(out, crc(data));
    u32(out, comp.length);
    u32(out, data.length);
    u16(out, nameBytes.length);
    u16(out, 0);
    out.add(nameBytes);
    out.add(comp);
    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0);
    u16(central, method);
    u16(central, 0);
    u16(central, 0);
    u32(central, crc(data));
    u32(central, comp.length);
    u32(central, data.length);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(nameBytes);
    count++;
  });
  final start = out.length;
  out.add(central.toBytes());
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, count);
  u16(out, count);
  u32(out, central.length);
  u32(out, start);
  u16(out, 0);
  return out.toBytes();
}

/// SVGA 1.x: zip with movie.spec JSON and PNG images.
Uint8List svga1({
  required Map<String, dynamic> spec,
  Map<String, List<int>> pngs = const {},
  bool specFirst = false,
}) {
  final files = <String, List<int>>{};
  if (specFirst) files['movie.spec'] = utf8.encode(jsonEncode(spec));
  pngs.forEach((k, v) => files['$k.png'] = v);
  if (!specFirst) files['movie.spec'] = utf8.encode(jsonEncode(spec));
  return zipOf(files, deflate: true);
}

/// Animated GIF built by hand: [delaysCs] one 1x1 frame each; [loops] is the NETSCAPE count or null for none.
Uint8List gifOf(List<int> delaysCs, {int? loops}) {
  final b = BytesBuilder();
  b.add(ascii.encode('GIF89a'));
  b.add([2, 0, 2, 0, 0x80, 0, 0]); // 2x2, global table of 2 colours
  b.add([0, 0, 0, 255, 255, 255]);
  if (loops != null) {
    b.add([0x21, 0xff, 11]);
    b.add(ascii.encode('NETSCAPE2.0'));
    b.add([3, 1, loops & 255, loops >> 8, 0]);
  }
  for (var fi = 0; fi < delaysCs.length; fi++) {
    final d = delaysCs[fi];
    b.add([0x21, 0xf9, 4, 0, d & 255, d >> 8, 0, 0]);
    b.add([0x2c, 0, 0, 0, 0, 2, 0, 2, 0, 0]);
    // LZW min code size 2, 3-bit codes: clear(4), i, 6 (= i i), i, end(5)  ->  four pixels of palette index i.
    final i = fi % 2;
    final codes = [4, i, 6, i, 5];
    var bits = 0, nbits = 0;
    final packed = <int>[];
    for (final c in codes) {
      bits |= c << nbits;
      nbits += 3;
      while (nbits >= 8) {
        packed.add(bits & 255);
        bits >>= 8;
        nbits -= 8;
      }
    }
    if (nbits > 0) packed.add(bits & 255);
    b.add([2, packed.length, ...packed, 0]);
  }
  b.addByte(0x3b);
  return b.toBytes();
}

/// Animated WebP container skeleton (frames carry dummy payloads; enough for the container parser, not for decoding).
Uint8List webpAnimOf(
  List<int> durationsMs, {
  int loops = 0,
  int w = 4,
  int h = 4,
}) {
  final body = BytesBuilder();
  void u24(BytesBuilder b, int v) =>
      b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  body.add(ascii.encode('WEBP'));
  body.add(ascii.encode('VP8X'));
  u32(body, 10);
  body.add([0x12, 0, 0, 0]);
  u24(body, w - 1);
  u24(body, h - 1);
  body.add(ascii.encode('ANIM'));
  u32(body, 6);
  body.add([0, 0, 0, 0, loops & 255, loops >> 8]);
  for (final d in durationsMs) {
    final frame = BytesBuilder();
    u24(frame, 0);
    u24(frame, 0);
    u24(frame, w - 1);
    u24(frame, h - 1);
    u24(frame, d);
    frame.addByte(0);
    frame.add(ascii.encode('VP8L'));
    u32(frame, 2);
    frame.add([0x2f, 0]);
    body.add(ascii.encode('ANMF'));
    u32(body, frame.length);
    body.add(frame.toBytes());
  }
  final out = BytesBuilder();
  out.add(ascii.encode('RIFF'));
  u32(out, body.length);
  out.add(body.toBytes());
  return out.toBytes();
}
