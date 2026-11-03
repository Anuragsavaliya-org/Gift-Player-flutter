import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Builds small SVGA 2.x files in code, so the example runs without shipping any third-party .svga artwork.
class _Pb {
  final BytesBuilder _b = BytesBuilder();
  Uint8List done() => _b.toBytes();

  void _varint(int v) {
    var n = v;
    while (n >= 0x80) {
      _b.addByte((n & 0x7f) | 0x80);
      n >>= 7;
    }
    _b.addByte(n);
  }

  _Pb varint(int field, int v) {
    _varint(field << 3);
    _varint(v);
    return this;
  }

  _Pb f32(int field, double v) {
    _varint((field << 3) | 5);
    _b.add((ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List());
    return this;
  }

  _Pb str(int field, String s) {
    final d = utf8.encode(s);
    _varint((field << 3) | 2);
    _varint(d.length);
    _b.add(d);
    return this;
  }

  _Pb msg(int field, _Pb m) {
    final d = m.done();
    _varint((field << 3) | 2);
    _varint(d.length);
    _b.add(d);
    return this;
  }
}

_Pb _floats(List<double> v) {
  final p = _Pb();
  for (var i = 0; i < v.length; i++) {
    p.f32(i + 1, v[i]);
  }
  return p;
}

_Pb _frame({
  double alpha = 1,
  List<double>? layout,
  List<double>? transform,
  List<_Pb> shapes = const [],
}) {
  final f = _Pb();
  if (alpha != 0) f.f32(1, alpha);
  if (layout != null) f.msg(2, _floats(layout));
  if (transform != null) f.msg(3, _floats(transform));
  for (final s in shapes) {
    f.msg(5, s);
  }
  return f;
}

_Pb _pathShape(
  String d,
  List<double> rgba, {
  List<double>? stroke,
  double strokeWidth = 0,
}) {
  final style = _Pb()..msg(1, _floats(rgba));
  if (stroke != null) style.msg(2, _floats(stroke)).f32(3, strokeWidth);
  return _Pb()
    ..varint(1, 0)
    ..msg(2, _Pb()..str(1, d))
    ..msg(10, style);
}

_Pb _ellipse(double cx, double cy, double rx, double ry, List<double> rgba) =>
    _Pb()
      ..varint(1, 2)
      ..msg(4, _floats([cx, cy, rx, ry]))
      ..msg(10, _Pb()..msg(1, _floats(rgba)));

_Pb _sprite(String key, List<_Pb> frames, {String? matte}) {
  final s = _Pb()..str(1, key);
  for (final f in frames) {
    s.msg(2, f);
  }
  if (matte != null) s.str(3, matte);
  return s;
}

Uint8List _file({
  required double w,
  required double h,
  required int fps,
  required int frames,
  required List<_Pb> sprites,
}) {
  final m = _Pb()
    ..str(1, '2.0.0')
    ..msg(
      2,
      _Pb()
        ..f32(1, w)
        ..f32(2, h)
        ..varint(3, fps)
        ..varint(4, frames),
    );
  for (final s in sprites) {
    m.msg(4, s);
  }
  return Uint8List.fromList(zlib.encode(m.done()));
}

/// A spinning gold star with a pulsing glow and an editable `name` text layer (try the name field).
Uint8List spinningStar() {
  const frames = 60;
  const star =
      'M150 30 L178 110 L265 110 L194 162 L221 245 L150 196 L79 245 L106 162 L35 110 L122 110 Z';
  final spin = <_Pb>[];
  final glow = <_Pb>[];
  for (var i = 0; i < frames; i++) {
    final a = 2 * math.pi * i / frames;
    final c = math.cos(a), s = math.sin(a);
    spin.add(
      _frame(
        alpha: 0.35 + 0.65 * math.sin(math.pi * i / frames),
        transform: [
          c,
          s,
          -s,
          c,
          150 - 150 * c + 150 * s,
          140 - 140 * s - 140 * c,
        ],
        shapes: [
          _pathShape(
            star,
            [1, 0.8, 0.1, 1],
            stroke: [1, 1, 1, 1],
            strokeWidth: 3,
          ),
        ],
      ),
    );
    final r = 90 + 25 * math.sin(2 * a);
    glow.add(
      _frame(
        alpha: 0.35,
        shapes: [
          _ellipse(150, 140, r, r, [1, 0.6, 0, 1]),
        ],
      ),
    );
  }
  final name = [
    for (var i = 0; i < frames; i++) _frame(layout: [0, 252, 300, 44]),
  ];
  return _file(
    w: 300,
    h: 300,
    fps: 30,
    frames: frames,
    sprites: [
      _sprite('glow.vector', glow),
      _sprite('star.vector', spin),
      _sprite('name', name),
    ],
  );
}

/// A pink heart that bounces, with a matte layer that wipes it in from the left (shows SVGA mattes).
Uint8List bouncingHeart() {
  const frames = 45;
  const heart =
      'M150 250 C60 180 40 110 90 80 C120 62 145 80 150 100 C155 80 180 62 210 80 C260 110 240 180 150 250 Z';
  final bounce = <_Pb>[];
  final wipe = <_Pb>[];
  for (var i = 0; i < frames; i++) {
    final dy = -40 * (math.sin(math.pi * 2 * i / frames)).abs();
    bounce.add(
      _frame(
        transform: [1, 0, 0, 1, 0, dy],
        shapes: [
          _pathShape(heart, [1, 0.25, 0.5, 1]),
        ],
      ),
    );
    final w = 300 * math.min(1.0, i / (frames * 0.4));
    wipe.add(
      _frame(
        shapes: [
          _pathShape(
            'M0 0 L${w.toStringAsFixed(1)} 0 L${w.toStringAsFixed(1)} 300 L0 300 Z',
            [0, 0, 0, 1],
          ),
        ],
      ),
    );
  }
  return _file(
    w: 300,
    h: 300,
    fps: 30,
    frames: frames,
    sprites: [
      _sprite('wipe.matte', wipe),
      _sprite('heart.vector', bounce, matte: 'wipe.matte'),
    ],
  );
}

/// Bytes that are not any gift format: shows the typed error and that the queue carries on.
Uint8List brokenFile() =>
    Uint8List.fromList(List<int>.generate(64, (i) => (i * 37 + 11) & 255));
