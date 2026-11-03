import '../errors.dart';
import 'proto.dart';
import 'types.dart';

/// Normalises an SVGA 1.x `movie.spec` JSON document into the same raw shape the protobuf decoder produces. Missing numbers are 0,
/// a missing `transform` is identity and a missing `layout` zeros (the same proto3 rules as 2.x). Shapes accept both numeric and
/// string types, `args` or `shape`/`rect`/`ellipse` argument objects, colours as `[r,g,b,a]` or `{r,g,b,a}`, and `lineDash` as
/// `[dash, gap, offset]` or `lineDashI/II/III`.
typedef _Json = Map<String, dynamic>;

bool _isObj(Object? v) => v is Map;
_Json _obj(Object? v) => (v as Map).cast<String, dynamic>();

double _num(Object? v) {
  final n = v is num
      ? v.toDouble()
      : v is String
      ? double.tryParse(v.trim()) ?? 0
      : 0.0;
  return n.isFinite ? n : 0;
}

String _str(Object? v) => v is String ? v : '';

SvgaMatrix _matrix(Object? v) {
  if (!_isObj(v)) return SvgaMatrix.identity;
  final o = _obj(v);
  return SvgaMatrix(
    _num(o['a']),
    _num(o['b']),
    _num(o['c']),
    _num(o['d']),
    _num(o['tx']),
    _num(o['ty']),
  );
}

SvgaLayout _layout(Object? v) {
  if (!_isObj(v)) return SvgaLayout.zero;
  final o = _obj(v);
  return SvgaLayout(
    _num(o['x']),
    _num(o['y']),
    _num(o['width']),
    _num(o['height']),
  );
}

SvgaColor? _color(Object? v) {
  if (v is List) {
    return SvgaColor(
      _num(v.elementAtOrNull(0)),
      _num(v.elementAtOrNull(1)),
      _num(v.elementAtOrNull(2)),
      _num(v.elementAtOrNull(3)),
    );
  }
  if (_isObj(v)) {
    final o = _obj(v);
    return SvgaColor(_num(o['r']), _num(o['g']), _num(o['b']), _num(o['a']));
  }
  return null;
}

T _pick<T extends Enum>(Object? v, List<T> values, T fallback) {
  if (v is num) {
    final i = v.toInt();
    return i >= 0 && i < values.length ? values[i] : fallback;
  }
  if (v is String) {
    for (final e in values) {
      if (e.name == v) return e;
    }
  }
  return fallback;
}

SvgaShapeStyle? _style(Object? v) {
  if (!_isObj(v)) return null;
  final o = _obj(v);
  double dash, gap, offset;
  final ld = o['lineDash'];
  if (ld is List) {
    dash = _num(ld.elementAtOrNull(0));
    gap = _num(ld.elementAtOrNull(1));
    offset = _num(ld.elementAtOrNull(2));
  } else {
    dash = _num(o['lineDashI']);
    gap = _num(o['lineDashII']);
    offset = _num(o['lineDashIII']);
  }
  return SvgaShapeStyle(
    fill: _color(o['fill']),
    stroke: _color(o['stroke']),
    strokeWidth: _num(o['strokeWidth']),
    lineCap: _pick(o['lineCap'], SvgaLineCap.values, SvgaLineCap.butt),
    lineJoin: _pick(o['lineJoin'], SvgaLineJoin.values, SvgaLineJoin.miter),
    miterLimit: _num(o['miterLimit']),
    dash: dash,
    gap: gap,
    dashOffset: offset,
  );
}

SvgaShape? _shape(Object? v) {
  if (!_isObj(v)) return null;
  final o = _obj(v);
  final type = _pick(o['type'], SvgaShapeType.values, SvgaShapeType.shape);
  final transform = _matrix(o['transform']);
  if (type == SvgaShapeType.keep) {
    return SvgaShape(type: SvgaShapeType.keep, transform: transform);
  }
  final Object? argsRaw = _isObj(o['args'])
      ? o['args']
      : (_isObj(o[type.name]) ? o[type.name] : null);
  final args = argsRaw == null ? <String, dynamic>{} : _obj(argsRaw);
  final st = _style(o['styles']);
  switch (type) {
    case SvgaShapeType.rect:
      return SvgaShape(
        type: type,
        x: _num(args['x']),
        y: _num(args['y']),
        width: _num(args['width']),
        height: _num(args['height']),
        cornerRadius: _num(args['cornerRadius']),
        style: st,
        transform: transform,
      );
    case SvgaShapeType.ellipse:
      return SvgaShape(
        type: type,
        x: _num(args['x']),
        y: _num(args['y']),
        radiusX: _num(args['radiusX']),
        radiusY: _num(args['radiusY']),
        style: st,
        transform: transform,
      );
    default:
      return SvgaShape(
        type: SvgaShapeType.shape,
        d: _str(args['d']),
        style: st,
        transform: transform,
      );
  }
}

RawFrame _frame(Object? v) {
  final o = _isObj(v) ? _obj(v) : <String, dynamic>{};
  final f = RawFrame(
    alpha: _num(o['alpha']),
    layout: _layout(o['layout']),
    transform: _matrix(o['transform']),
    clipPath: _str(o['clipPath']),
  );
  final shapes = o['shapes'];
  if (shapes is List) {
    for (final s in shapes) {
      final sh = _shape(s);
      if (sh != null) f.shapes.add(sh);
    }
  }
  return f;
}

RawSprite _sprite(Object? v) {
  final o = _isObj(v) ? _obj(v) : <String, dynamic>{};
  final s = RawSprite(
    imageKey: _str(o['imageKey']),
    matteKey: _str(o['matteKey']),
  );
  final frames = o['frames'];
  if (frames is List) s.frames.addAll(frames.map(_frame));
  return s;
}

class SpecResult {
  SpecResult(this.raw, this.imageNames);
  final RawMovie raw;

  /// `images` map of the spec: image key -> file name stem inside the zip (`<name>.png`).
  final Map<String, String> imageNames;
}

SpecResult fromSpecJson(Object? spec) {
  if (!_isObj(spec)) {
    throw GiftPlayerError(
      GiftErrorCode.parseFailed,
      'movie.spec is not a JSON object.',
    );
  }
  final s = _obj(spec);
  final movie = _isObj(s['movie']) ? _obj(s['movie']) : <String, dynamic>{};
  final viewBox = _isObj(movie['viewBox'])
      ? _obj(movie['viewBox'])
      : <String, dynamic>{};
  final raw = RawMovie()
    ..version = _str(s['ver'])
    ..viewBoxWidth = _num(viewBox['width'])
    ..viewBoxHeight = _num(viewBox['height'])
    ..fps = _num(movie['fps']).truncate()
    ..frames = _num(movie['frames']).truncate();
  final audios = s['audios'];
  if (audios is List) {
    raw.audios = [
      for (final a in audios.where(_isObj).map(_obj))
        SvgaAudioTrack(
          audioKey: _str(a['audioKey']),
          startFrame: _num(a['startFrame']).truncate(),
          endFrame: _num(a['endFrame']).truncate(),
          startTime: _num(a['startTime']).truncate(),
          totalTime: _num(a['totalTime']).truncate(),
        ),
    ];
  }
  final names = <String, String>{};
  final images = s['images'];
  if (images is Map) {
    images.forEach((k, v) => names[k.toString()] = _str(v));
  }
  final sprites = s['sprites'];
  if (sprites is List) raw.sprites.addAll(sprites.map(_sprite));
  return SpecResult(raw, names);
}
