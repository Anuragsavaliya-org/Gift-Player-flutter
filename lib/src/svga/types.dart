import 'dart:typed_data';

/// Version-independent SVGA model. SVGA 2.x (protobuf) and 1.x (zip + JSON) both normalise to [SvgaMovie], so renderers never
/// need to know the source version.
///
/// Normalisation guarantees (all resolved at parse time):
/// * every sprite has exactly `movie.frames` frames;
/// * proto3 defaults applied: missing scalar = 0, missing transform = identity, missing layout = zeros;
/// * `KEEP` shapes are replaced by the previous frame's shapes, so no `keep` shape exists in the model;
/// * audio bytes are kept apart from image bytes.
class SvgaMatrix {
  const SvgaMatrix(this.a, this.b, this.c, this.d, this.tx, this.ty);
  static const identity = SvgaMatrix(1, 0, 0, 1, 0, 0);
  final double a, b, c, d, tx, ty;
}

class SvgaLayout {
  const SvgaLayout(this.x, this.y, this.width, this.height);
  static const zero = SvgaLayout(0, 0, 0, 0);
  final double x, y, width, height;
}

/// Colour components are 0..1 floats, exactly as stored in the file.
class SvgaColor {
  const SvgaColor(this.r, this.g, this.b, this.a);
  final double r, g, b, a;
}

enum SvgaLineCap { butt, round, square }

enum SvgaLineJoin { miter, round, bevel }

class SvgaShapeStyle {
  SvgaShapeStyle({
    this.fill,
    this.stroke,
    this.strokeWidth = 0,
    this.lineCap = SvgaLineCap.butt,
    this.lineJoin = SvgaLineJoin.miter,
    this.miterLimit = 0,
    this.dash = 0,
    this.gap = 0,
    this.dashOffset = 0,
  });

  /// null = no fill.
  SvgaColor? fill;

  /// null = no stroke.
  SvgaColor? stroke;
  double strokeWidth;
  SvgaLineCap lineCap;
  SvgaLineJoin lineJoin;
  double miterLimit;

  /// Raw dash parameters from the file (dash length, gap length, offset); 0 = unset.
  double dash, gap, dashOffset;
}

enum SvgaShapeType { shape, rect, ellipse, keep }

/// One vector shape. Which fields matter depends on [type]: `shape` uses [d]; `rect` uses x/y/width/height/cornerRadius;
/// `ellipse` uses x/y/radiusX/radiusY. A `keep` shape only exists in the raw (pre-normalisation) form.
class SvgaShape {
  SvgaShape({
    required this.type,
    this.style,
    this.transform = SvgaMatrix.identity,
    this.d = '',
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
    this.cornerRadius = 0,
    this.radiusX = 0,
    this.radiusY = 0,
  });

  final SvgaShapeType type;

  /// null when the shape carries no style message.
  final SvgaShapeStyle? style;
  final SvgaMatrix transform;
  final String d;
  final double x, y, width, height, cornerRadius, radiusX, radiusY;
}

class SvgaFrame {
  const SvgaFrame({
    required this.alpha,
    required this.layout,
    required this.transform,
    required this.clipPath,
    required this.shapes,
  });

  /// 0 = sprite hidden in this frame.
  final double alpha;
  final SvgaLayout layout;
  final SvgaMatrix transform;

  /// SVG path string used as a clip mask; '' = none.
  final String clipPath;
  final List<SvgaShape> shapes;
}

class SvgaSprite {
  SvgaSprite({
    required this.imageKey,
    required this.matteKey,
    required this.isMatte,
    required this.frames,
  });

  /// Bitmap key; may end in `.matte` (mask layer) or `.vector` (vector-only layer).
  final String imageKey;

  /// For a sprite that is masked: the `imageKey` of its mask sprite. null if not masked.
  final String? matteKey;

  /// True when [imageKey] ends in `.matte`: this sprite is a mask for others.
  final bool isMatte;

  /// Exactly `movie.frames` entries.
  final List<SvgaFrame> frames;
}

class SvgaBinary {
  SvgaBinary(this.data, this.mime);
  final Uint8List data;
  final String mime;
}

/// Timeline entry for an audio clip (playback is out of scope, as in the web package).
class SvgaAudioTrack {
  SvgaAudioTrack({
    this.audioKey = '',
    this.startFrame = 0,
    this.endFrame = 0,
    this.startTime = 0,
    this.totalTime = 0,
  });
  String audioKey;
  int startFrame, endFrame, startTime, totalTime;
}

enum SvgaContainer { protobuf, zipJson, zipProtobuf }

class SvgaMovie {
  SvgaMovie({
    required this.container,
    required this.version,
    required this.viewBoxWidth,
    required this.viewBoxHeight,
    required this.fps,
    required this.frames,
    required this.images,
    required this.audios,
    required this.audioTracks,
    required this.sprites,
    required this.warnings,
  });

  /// Informational only; renderers must not branch on this.
  final SvgaContainer container;

  /// Version string as declared in the file ('' if absent).
  final String version;
  final double viewBoxWidth, viewBoxHeight;
  final int fps;
  final int frames;

  /// Raw encoded images (PNG/JPEG/WebP), keyed by image key. Never contains audio.
  final Map<String, SvgaBinary> images;

  /// Raw encoded audio, keyed by audio key.
  final Map<String, SvgaBinary> audios;
  final List<SvgaAudioTrack> audioTracks;
  final List<SvgaSprite> sprites;

  /// Non-fatal oddities found while parsing (dropped entries, padded frames, ...).
  final List<String> warnings;
}
