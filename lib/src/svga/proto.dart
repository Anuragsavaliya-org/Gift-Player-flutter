import 'dart:typed_data';

import 'types.dart';
import 'wire.dart';

/// Decoder for the SVGA 2.x `MovieEntity` protobuf. Field numbers follow `svga.proto`. Unknown fields and fields whose wire type
/// does not match the schema are skipped, as protobuf decoders do. Missing scalars decode as proto3 defaults (0 / ''), a missing
/// `transform` as identity, a missing `layout` as zeros.
///
/// Output is a "raw" movie in which shapes may still be `keep` (resolved in parse.dart).
class RawFrame {
  RawFrame({
    this.alpha = 0,
    this.layout = SvgaLayout.zero,
    this.transform = SvgaMatrix.identity,
    this.clipPath = '',
    List<SvgaShape>? shapes,
  }) : shapes = shapes ?? [];
  double alpha;
  SvgaLayout layout;
  SvgaMatrix transform;
  String clipPath;
  final List<SvgaShape> shapes;

  /// Frame with nothing set: hidden, no clip, no shapes.
  bool get isEmpty => alpha == 0 && clipPath == '' && shapes.isEmpty;

  bool get isDefault =>
      isEmpty &&
      layout.x == 0 &&
      layout.y == 0 &&
      layout.width == 0 &&
      layout.height == 0 &&
      transform.a == 1 &&
      transform.b == 0 &&
      transform.c == 0 &&
      transform.d == 1 &&
      transform.tx == 0 &&
      transform.ty == 0;
}

class RawSprite {
  RawSprite({this.imageKey = '', this.matteKey = ''});
  String imageKey;
  String matteKey;
  final List<RawFrame> frames = [];
}

class RawMovie {
  String version = '';
  double viewBoxWidth = 0;
  double viewBoxHeight = 0;
  int fps = 0;
  int frames = 0;

  /// Raw `images` map values: encoded image/audio bytes, or file names inside a 1.5 zip.
  final Map<String, Uint8List> images = {};
  final List<RawSprite> sprites = [];
  List<SvgaAudioTrack> audios = [];
}

/// Reads fixed32 float fields 1..[count] by index (field number - 1).
List<double> _readFloats(WireReader r, int count) {
  final out = List<double>.filled(count, 0);
  while (!r.done) {
    final (f, wt) = r.tag();
    if (f >= 1 && f <= count && wt == wireFixed32) {
      out[f - 1] = r.float();
    } else {
      r.skip(wt);
    }
  }
  return out;
}

SvgaMatrix _decodeTransform(WireReader r) {
  final v = _readFloats(r, 6);
  return SvgaMatrix(v[0], v[1], v[2], v[3], v[4], v[5]);
}

SvgaLayout _decodeLayout(WireReader r) {
  final v = _readFloats(r, 4);
  return SvgaLayout(v[0], v[1], v[2], v[3]);
}

SvgaColor _decodeColor(WireReader r) {
  final v = _readFloats(r, 4);
  return SvgaColor(v[0], v[1], v[2], v[3]);
}

SvgaShapeStyle _decodeStyle(WireReader r) {
  final s = SvgaShapeStyle();
  while (!r.done) {
    final (f, wt) = r.tag();
    if (f == 1 && wt == wireLen) {
      s.fill = _decodeColor(r.message());
    } else if (f == 2 && wt == wireLen) {
      s.stroke = _decodeColor(r.message());
    } else if (f == 3 && wt == wireFixed32) {
      s.strokeWidth = r.float();
    } else if (f == 4 && wt == wireVarint) {
      final v = r.int32();
      s.lineCap = v >= 0 && v < SvgaLineCap.values.length
          ? SvgaLineCap.values[v]
          : SvgaLineCap.butt;
    } else if (f == 5 && wt == wireVarint) {
      final v = r.int32();
      s.lineJoin = v >= 0 && v < SvgaLineJoin.values.length
          ? SvgaLineJoin.values[v]
          : SvgaLineJoin.miter;
    } else if (f == 6 && wt == wireFixed32) {
      s.miterLimit = r.float();
    } else if (f == 7 && wt == wireFixed32) {
      s.dash = r.float();
    } else if (f == 8 && wt == wireFixed32) {
      s.gap = r.float();
    } else if (f == 9 && wt == wireFixed32) {
      s.dashOffset = r.float();
    } else {
      r.skip(wt);
    }
  }
  return s;
}

SvgaShape _decodeShape(WireReader r) {
  var type = 0;
  var d = '';
  var rect = <double>[0, 0, 0, 0, 0];
  var ellipse = <double>[0, 0, 0, 0];
  SvgaShapeStyle? style;
  var transform = SvgaMatrix.identity;
  while (!r.done) {
    final (f, wt) = r.tag();
    if (f == 1 && wt == wireVarint) {
      type = r.int32();
    } else if (f == 2 && wt == wireLen) {
      final sub = r.message();
      while (!sub.done) {
        final (sf, swt) = sub.tag();
        if (sf == 1 && swt == wireLen) {
          d = sub.string();
        } else {
          sub.skip(swt);
        }
      }
    } else if (f == 3 && wt == wireLen) {
      rect = _readFloats(r.message(), 5);
    } else if (f == 4 && wt == wireLen) {
      ellipse = _readFloats(r.message(), 4);
    } else if (f == 10 && wt == wireLen) {
      style = _decodeStyle(r.message());
    } else if (f == 11 && wt == wireLen) {
      transform = _decodeTransform(r.message());
    } else {
      r.skip(wt);
    }
  }
  switch (type) {
    case 1:
      return SvgaShape(
        type: SvgaShapeType.rect,
        x: rect[0],
        y: rect[1],
        width: rect[2],
        height: rect[3],
        cornerRadius: rect[4],
        style: style,
        transform: transform,
      );
    case 2:
      return SvgaShape(
        type: SvgaShapeType.ellipse,
        x: ellipse[0],
        y: ellipse[1],
        radiusX: ellipse[2],
        radiusY: ellipse[3],
        style: style,
        transform: transform,
      );
    case 3:
      return SvgaShape(type: SvgaShapeType.keep, transform: transform);
    default:
      // 0 = SHAPE; unknown enum values are treated as the proto3 default.
      return SvgaShape(
        type: SvgaShapeType.shape,
        d: d,
        style: style,
        transform: transform,
      );
  }
}

RawFrame _decodeFrame(WireReader r) {
  final f = RawFrame();
  while (!r.done) {
    final (n, wt) = r.tag();
    if (n == 1 && wt == wireFixed32) {
      f.alpha = r.float();
    } else if (n == 2 && wt == wireLen) {
      f.layout = _decodeLayout(r.message());
    } else if (n == 3 && wt == wireLen) {
      f.transform = _decodeTransform(r.message());
    } else if (n == 4 && wt == wireLen) {
      f.clipPath = r.string();
    } else if (n == 5 && wt == wireLen) {
      f.shapes.add(_decodeShape(r.message()));
    } else {
      r.skip(wt);
    }
  }
  return f;
}

RawSprite _decodeSprite(WireReader r) {
  final s = RawSprite();
  while (!r.done) {
    final (n, wt) = r.tag();
    if (n == 1 && wt == wireLen) {
      s.imageKey = r.string();
    } else if (n == 2 && wt == wireLen) {
      s.frames.add(_decodeFrame(r.message()));
    } else if (n == 3 && wt == wireLen) {
      s.matteKey = r.string();
    } else {
      r.skip(wt);
    }
  }
  return s;
}

SvgaAudioTrack _decodeAudio(WireReader r) {
  final a = SvgaAudioTrack();
  while (!r.done) {
    final (n, wt) = r.tag();
    if (n == 1 && wt == wireLen) {
      a.audioKey = r.string();
    } else if (n == 2 && wt == wireVarint) {
      a.startFrame = r.int32();
    } else if (n == 3 && wt == wireVarint) {
      a.endFrame = r.int32();
    } else if (n == 4 && wt == wireVarint) {
      a.startTime = r.int32();
    } else if (n == 5 && wt == wireVarint) {
      a.totalTime = r.int32();
    } else {
      r.skip(wt);
    }
  }
  return a;
}

/// `map<string, bytes>` entry: key = 1, value = 2.
(String, Uint8List) _decodeImageEntry(WireReader r) {
  var key = '';
  var value = Uint8List(0);
  while (!r.done) {
    final (n, wt) = r.tag();
    if (n == 1 && wt == wireLen) {
      key = r.string();
    } else if (n == 2 && wt == wireLen) {
      value = r.bytes();
    } else {
      r.skip(wt);
    }
  }
  return (key, value);
}

/// Decodes an (already inflated) `MovieEntity`. Throws [GiftPlayerError] (`parse-failed`).
RawMovie decodeMovieEntity(Uint8List buf) {
  final movie = RawMovie();
  final r = WireReader(buf);
  while (!r.done) {
    final (n, wt) = r.tag();
    if (n == 1 && wt == wireLen) {
      movie.version = r.string();
    } else if (n == 2 && wt == wireLen) {
      final p = r.message();
      while (!p.done) {
        final (pn, pwt) = p.tag();
        if (pn == 1 && pwt == wireFixed32) {
          movie.viewBoxWidth = p.float();
        } else if (pn == 2 && pwt == wireFixed32) {
          movie.viewBoxHeight = p.float();
        } else if (pn == 3 && pwt == wireVarint) {
          movie.fps = p.int32();
        } else if (pn == 4 && pwt == wireVarint) {
          movie.frames = p.int32();
        } else {
          p.skip(pwt);
        }
      }
    } else if (n == 3 && wt == wireLen) {
      final (k, v) = _decodeImageEntry(r.message());
      movie.images[k] = v;
    } else if (n == 4 && wt == wireLen) {
      movie.sprites.add(_decodeSprite(r.message()));
    } else if (n == 5 && wt == wireLen) {
      movie.audios.add(_decodeAudio(r.message()));
    } else {
      r.skip(wt);
    }
  }
  return movie;
}
