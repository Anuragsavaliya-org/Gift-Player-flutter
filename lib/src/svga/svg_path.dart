import 'dart:ui' as ui;

/// Parses SVG path data (`M L H V C S Q T A Z`, absolute and relative, with implicit repetition and compact arc flags) into a
/// [ui.Path]. Like the browser's `new Path2D(d)` it never throws: unparseable data yields the part parsed so far.
ui.Path parseSvgPath(String d) {
  final p = _PathParser(d);
  p.run();
  return p.path;
}

class _PathParser {
  _PathParser(this.s);

  final String s;
  final ui.Path path = ui.Path();
  int i = 0;

  double cx = 0, cy = 0; // current point
  double sx = 0, sy = 0; // subpath start
  double lcx = 0, lcy = 0; // last cubic control point (for S)
  double lqx = 0, lqy = 0; // last quadratic control point (for T)
  String prev = '';

  bool get _end => i >= s.length;

  void _skipSep() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 ||
          c == 0x2c ||
          c == 0x09 ||
          c == 0x0a ||
          c == 0x0d ||
          c == 0x0c) {
        i++;
      } else {
        break;
      }
    }
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  /// Reads a number or returns null (position unchanged on failure).
  double? _number() {
    _skipSep();
    final start = i;
    var j = i;
    if (j < s.length && (s.codeUnitAt(j) == 0x2b || s.codeUnitAt(j) == 0x2d)) {
      j++;
    }
    var digits = 0;
    while (j < s.length && _isDigit(s.codeUnitAt(j))) {
      j++;
      digits++;
    }
    if (j < s.length && s.codeUnitAt(j) == 0x2e) {
      j++;
      while (j < s.length && _isDigit(s.codeUnitAt(j))) {
        j++;
        digits++;
      }
    }
    if (digits == 0) return null;
    if (j < s.length && (s.codeUnitAt(j) == 0x65 || s.codeUnitAt(j) == 0x45)) {
      var k = j + 1;
      if (k < s.length &&
          (s.codeUnitAt(k) == 0x2b || s.codeUnitAt(k) == 0x2d)) {
        k++;
      }
      if (k < s.length && _isDigit(s.codeUnitAt(k))) {
        while (k < s.length && _isDigit(s.codeUnitAt(k))) {
          k++;
        }
        j = k;
      }
    }
    final v = double.tryParse(s.substring(start, j));
    if (v == null) return null;
    i = j;
    return v;
  }

  /// Arc flags are a single '0' or '1' and may be glued to the next number.
  bool? _flag() {
    _skipSep();
    if (_end) return null;
    final c = s.codeUnitAt(i);
    if (c == 0x30) {
      i++;
      return false;
    }
    if (c == 0x31) {
      i++;
      return true;
    }
    return null;
  }

  List<double>? _numbers(int n) {
    final out = <double>[];
    for (var k = 0; k < n; k++) {
      final v = _number();
      if (v == null) return null;
      out.add(v);
    }
    return out;
  }

  void run() {
    while (true) {
      _skipSep();
      if (_end) return;
      var cmd = s[i];
      final isLetter = RegExp(r'[A-Za-z]').hasMatch(cmd);
      if (isLetter) {
        i++;
      } else {
        // Implicit repetition of the previous command (M becomes L).
        if (prev.isEmpty || prev == 'Z' || prev == 'z') return;
        cmd = prev == 'M'
            ? 'L'
            : prev == 'm'
            ? 'l'
            : prev;
      }
      if (!_exec(cmd)) return;
      prev = cmd;
    }
  }

  bool _exec(String cmd) {
    final rel = cmd == cmd.toLowerCase();
    switch (cmd.toUpperCase()) {
      case 'M':
        final v = _numbers(2);
        if (v == null) return false;
        cx = rel ? cx + v[0] : v[0];
        cy = rel ? cy + v[1] : v[1];
        sx = cx;
        sy = cy;
        path.moveTo(cx, cy);
        lcx = cx;
        lcy = cy;
        lqx = cx;
        lqy = cy;
        return true;
      case 'L':
        final v = _numbers(2);
        if (v == null) return false;
        cx = rel ? cx + v[0] : v[0];
        cy = rel ? cy + v[1] : v[1];
        path.lineTo(cx, cy);
        lcx = cx;
        lcy = cy;
        lqx = cx;
        lqy = cy;
        return true;
      case 'H':
        final v = _number();
        if (v == null) return false;
        cx = rel ? cx + v : v;
        path.lineTo(cx, cy);
        lcx = cx;
        lcy = cy;
        lqx = cx;
        lqy = cy;
        return true;
      case 'V':
        final v = _number();
        if (v == null) return false;
        cy = rel ? cy + v : v;
        path.lineTo(cx, cy);
        lcx = cx;
        lcy = cy;
        lqx = cx;
        lqy = cy;
        return true;
      case 'C':
        final v = _numbers(6);
        if (v == null) return false;
        final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
        path.cubicTo(
          ox + v[0],
          oy + v[1],
          ox + v[2],
          oy + v[3],
          ox + v[4],
          oy + v[5],
        );
        lcx = ox + v[2];
        lcy = oy + v[3];
        cx = ox + v[4];
        cy = oy + v[5];
        lqx = cx;
        lqy = cy;
        return true;
      case 'S':
        final v = _numbers(4);
        if (v == null) return false;
        final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
        final smooth = 'CScs'.contains(prev) && prev.isNotEmpty;
        final c1x = smooth ? 2 * cx - lcx : cx;
        final c1y = smooth ? 2 * cy - lcy : cy;
        path.cubicTo(c1x, c1y, ox + v[0], oy + v[1], ox + v[2], oy + v[3]);
        lcx = ox + v[0];
        lcy = oy + v[1];
        cx = ox + v[2];
        cy = oy + v[3];
        lqx = cx;
        lqy = cy;
        return true;
      case 'Q':
        final v = _numbers(4);
        if (v == null) return false;
        final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
        path.quadraticBezierTo(ox + v[0], oy + v[1], ox + v[2], oy + v[3]);
        lqx = ox + v[0];
        lqy = oy + v[1];
        cx = ox + v[2];
        cy = oy + v[3];
        lcx = cx;
        lcy = cy;
        return true;
      case 'T':
        final v = _numbers(2);
        if (v == null) return false;
        final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
        final smooth = 'QTqt'.contains(prev) && prev.isNotEmpty;
        final qx = smooth ? 2 * cx - lqx : cx;
        final qy = smooth ? 2 * cy - lqy : cy;
        path.quadraticBezierTo(qx, qy, ox + v[0], oy + v[1]);
        lqx = qx;
        lqy = qy;
        cx = ox + v[0];
        cy = oy + v[1];
        lcx = cx;
        lcy = cy;
        return true;
      case 'A':
        final rx = _number();
        final ry = rx == null ? null : _number();
        final rot = ry == null ? null : _number();
        final large = rot == null ? null : _flag();
        final sweep = large == null ? null : _flag();
        final x = sweep == null ? null : _number();
        final y = x == null ? null : _number();
        if (y == null) return false;
        final ex = rel ? cx + x! : x!;
        final ey = rel ? cy + y : y;
        if (rx == 0 || ry == 0) {
          path.lineTo(ex, ey);
        } else if (ex != cx || ey != cy) {
          path.arcToPoint(
            ui.Offset(ex, ey),
            radius: ui.Radius.elliptical(rx!.abs(), ry!.abs()),
            rotation: rot!,
            largeArc: large!,
            clockwise: sweep!,
          );
        }
        cx = ex;
        cy = ey;
        lcx = cx;
        lcy = cy;
        lqx = cx;
        lqy = cy;
        return true;
      case 'Z':
        path.close();
        cx = sx;
        cy = sy;
        lcx = cx;
        lcy = cy;
        lqx = cx;
        lqy = cy;
        return true;
      default:
        return false;
    }
  }
}
