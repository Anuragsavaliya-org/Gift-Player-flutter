import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';

import '../renderer.dart';
import '../replacement.dart';
import '../viewport.dart';
import 'svg_path.dart';
import 'types.dart';

void _warn(String msg) => debugPrint('[gift-player] $msg');

class _ImageRepl {
  _ImageRepl(this.image, this.owned, this.fit);
  final ui.Image image;
  final bool owned;
  final GiftImageFit fit;
}

class _TextRepl {
  _TextRepl(this.fill, this.stroke, this.align);
  final TextPainter fill;
  final TextPainter? stroke;
  final GiftTextAlign align;
}

class _Runtime {
  _Runtime(this.sprite, this.bitmap);
  final SvgaSprite sprite;
  final ui.Image? bitmap;
  _ImageRepl? image;
  _TextRepl? text;
  bool hidden = false;
}

/// One step of the draw list, computed at load time. Either a single unmasked sprite, or a *run*: a maximal sequence of consecutive
/// masked sprites sharing one matteKey, which is composited together and masked ONCE, like the official players do. Per-run gives
/// (A over B) x m; per-sprite would give (A x m) over (B x m).
class _DrawItem {
  _DrawItem.single(this.rt) : run = null, matte = null;
  _DrawItem.masked(this.run, this.matte) : rt = null;
  final _Runtime? rt;
  final List<_Runtime>? run;
  final _Runtime? matte;
}

class _Compiled {
  _Compiled(
    this.path,
    this.fill,
    this.stroke,
    this.lineWidth,
    this.cap,
    this.join,
    this.miter,
  );
  final ui.Path path;
  final SvgaColor? fill;
  final SvgaColor? stroke;
  final double lineWidth;
  final ui.StrokeCap cap;
  final ui.StrokeJoin join;
  final double miter;
}

/// Canvas renderer for a parsed SVGA movie. `drawFrame(i)` selects the frame and [paint] draws it: the same frame always yields the
/// same pixels (no time or randomness involved).
///
/// Ownership: the renderer disposes [bitmaps] on `destroy()` unless [sharedImages] is set (the asset cache owns them then), and always
/// disposes images it created itself for `setImage` replacements. `ui.Image`s the caller passes to `setImage` are never disposed.
class SvgaRenderer extends GiftRenderer {
  SvgaRenderer(
    this.movie,
    this.bitmaps, {
    this.sharedImages = false,
    ContentMode contentMode = ContentMode.aspectFit,
  }) : _mode = contentMode {
    final matteByKey = <String, _Runtime>{};
    for (final sprite in movie.sprites) {
      // Matte bitmaps are stored under the key without the ".matte" suffix.
      final bmp =
          bitmaps[sprite.imageKey] ??
          (sprite.isMatte
              ? bitmaps[sprite.imageKey.substring(
                  0,
                  sprite.imageKey.length - '.matte'.length,
                )]
              : null);
      final rt = _Runtime(sprite, bmp);
      _runtimes.add(rt);
      _byKey.putIfAbsent(sprite.imageKey, () => []).add(rt);
      if (sprite.isMatte && !matteByKey.containsKey(sprite.imageKey)) {
        matteByKey[sprite.imageKey] = rt;
      }
    }
    // Matte sprites are skipped and do not break a run. An unmasked sprite, or a matteKey that matches no matte sprite (dangling),
    // ends the current run and is drawn directly.
    List<_Runtime>? run;
    var runKey = '';
    for (final rt in _runtimes) {
      if (rt.sprite.isMatte) continue;
      final key = rt.sprite.matteKey;
      final matte = key == null ? null : matteByKey[key];
      if (key != null && matte != null) {
        if (run != null && runKey == key) {
          run.add(rt);
        } else {
          run = [rt];
          runKey = key;
          _items.add(_DrawItem.masked(run, matte));
        }
      } else {
        run = null;
        runKey = '';
        _items.add(_DrawItem.single(rt));
      }
    }
  }

  final SvgaMovie movie;
  final Map<String, ui.Image> bitmaps;
  final bool sharedImages;

  final List<_Runtime> _runtimes = [];
  final List<_DrawItem> _items = [];
  final Map<String, List<_Runtime>> _byKey = {};
  final Map<String, ui.Path> _paths = {};
  final Map<SvgaShape, _Compiled?> _compiled = Map.identity();
  final Map<String, _ImageRepl> _replacementImages = {};
  final Map<String, int> _imageTokens = {};
  ContentMode _mode;
  int _current = -1;
  bool _destroyed = false;
  final ui.Paint _paint = ui.Paint();

  // ---- GiftRenderer: SVGA has a fixed fps and no loop count in the file --------------------------------------------------

  @override
  int get frameCount => movie.frames;

  @override
  double frameDuration(int i) => 1000 / movie.fps;

  @override
  int? get loopCount => null;

  @override
  ui.Size get size => ui.Size(movie.viewBoxWidth, movie.viewBoxHeight);

  /// Everything is already decoded, so any frame is ready.
  @override
  Future<void> ready(int i) => Future.value();

  @override
  bool get hasFrame => _current >= 0;

  int get frame => _current;

  @override
  ContentMode get contentMode => _mode;

  @override
  set contentMode(ContentMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    repaint.notify();
  }

  @override
  bool get supportsReplacement => true;

  /// Keys that `setImage` / `setText` / `setHidden` accept: the imageKey of every sprite that is not a matte layer (`.vector` keys
  /// are shape-only layers; they can take text and be hidden, and an image is drawn over their shapes).
  @override
  List<EditableKey> getEditableKeys() {
    final seen = <String>{};
    final out = <EditableKey>[];
    for (final s in movie.sprites) {
      if (s.isMatte || !seen.add(s.imageKey)) continue;
      out.add(
        EditableKey(
          key: s.imageKey,
          type: s.imageKey.endsWith('.vector') ? 'vector' : 'image',
          name: s.imageKey,
        ),
      );
    }
    return out;
  }

  /// Selects frame [index] (clamped to the movie's range). Always synchronous: returns true once selected.
  @override
  bool drawFrame(int index) {
    if (_destroyed) return false;
    _current = index < 0
        ? 0
        : (index >= movie.frames ? movie.frames - 1 : index);
    repaint.notify();
    return true;
  }

  @override
  void clear() {
    if (_destroyed) return;
    _current = -1;
    repaint.notify();
  }

  void _redraw() {
    if (_current >= 0) repaint.notify();
  }

  // ---- painting ----------------------------------------------------------------------------------------------------------

  @override
  void paint(ui.Canvas canvas, ui.Size box) {
    if (_destroyed || _current < 0 || box.isEmpty) return;
    final i = _current;
    canvas.save();
    applyView(canvas, box, movie.viewBoxWidth, movie.viewBoxHeight, _mode);
    final bounds = canvas.getLocalClipBounds();
    for (final item in _items) {
      final run = item.run;
      if (run == null) {
        final rt = item.rt!;
        if (rt.hidden) continue;
        final frame = rt.sprite.frames[i];
        if (frame.alpha > 0) _drawSprite(canvas, rt, frame);
        continue;
      }
      final matte = item.matte!;
      final matteFrame = matte.sprite.frames[i];
      // A hidden matte layer masks the whole run out (as in the official players).
      if (!(matteFrame.alpha > 0)) continue;
      var any = false;
      for (final rt in run) {
        if (!rt.hidden && rt.sprite.frames[i].alpha > 0) {
          any = true;
          break;
        }
      }
      if (!any) continue;
      canvas.saveLayer(bounds, ui.Paint());
      for (final rt in run) {
        if (rt.hidden) continue;
        final frame = rt.sprite.frames[i];
        if (frame.alpha > 0) _drawSprite(canvas, rt, frame);
      }
      canvas.saveLayer(bounds, ui.Paint()..blendMode = ui.BlendMode.dstIn);
      _drawSprite(canvas, matte, matteFrame);
      canvas.restore();
      canvas.restore();
    }
    canvas.restore();
  }

  static Float64List _matrix(SvgaMatrix t) {
    final m = Float64List(16);
    m[0] = t.a;
    m[1] = t.b;
    m[4] = t.c;
    m[5] = t.d;
    m[10] = 1;
    m[12] = t.tx;
    m[13] = t.ty;
    m[15] = 1;
    return m;
  }

  ui.Path _svg(String d) => _paths.putIfAbsent(d, () => parseSvgPath(d));

  void _drawSprite(ui.Canvas canvas, _Runtime rt, SvgaFrame frame) {
    final alpha = frame.alpha.clamp(0.0, 1.0);
    canvas.save();
    canvas.transform(_matrix(frame.transform));
    if (frame.clipPath != '') canvas.clipPath(_svg(frame.clipPath));

    final l = frame.layout;
    final img = rt.image;
    if (img != null) {
      _drawReplacement(canvas, img, l, alpha);
    } else if (rt.bitmap != null) {
      final b = rt.bitmap!;
      _paint
        ..color = ui.Color.fromRGBO(255, 255, 255, alpha)
        ..filterQuality = ui.FilterQuality.medium
        ..isAntiAlias = true;
      final src = ui.Rect.fromLTWH(
        0,
        0,
        b.width.toDouble(),
        b.height.toDouble(),
      );
      if (l.width > 0 && l.height > 0) {
        canvas.drawImageRect(
          b,
          src,
          ui.Rect.fromLTWH(l.x, l.y, l.width, l.height),
          _paint,
        );
      } else {
        canvas.drawImageRect(
          b,
          src,
          ui.Rect.fromLTWH(l.x, l.y, src.width, src.height),
          _paint,
        );
      }
    }

    for (final shape in frame.shapes) {
      final c = _compiled.putIfAbsent(shape, () => _compile(shape));
      if (c == null) continue;
      canvas.save();
      canvas.transform(_matrix(shape.transform));
      if (c.fill != null) {
        canvas.drawPath(
          c.path,
          ui.Paint()
            ..style = ui.PaintingStyle.fill
            ..isAntiAlias = true
            ..color = _color(c.fill!, alpha),
        );
      }
      if (c.stroke != null) {
        final p = ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..isAntiAlias = true
          ..color = _color(c.stroke!, alpha)
          ..strokeWidth = c.lineWidth
          ..strokeCap = c.cap
          ..strokeJoin = c.join;
        if (c.miter > 0) p.strokeMiterLimit = c.miter;
        canvas.drawPath(c.path, p);
      }
      canvas.restore();
    }

    final text = rt.text;
    if (text != null) _drawText(canvas, text, l, alpha);
    canvas.restore();
  }

  static ui.Color _color(SvgaColor c, double alpha) => ui.Color.from(
    alpha: (c.a * alpha).clamp(0.0, 1.0),
    red: c.r.clamp(0.0, 1.0),
    green: c.g.clamp(0.0, 1.0),
    blue: c.b.clamp(0.0, 1.0),
  );

  /// Load-time compilation of a shape into a Path and ready-to-use style values. null when the shape draws nothing.
  _Compiled? _compile(SvgaShape s) {
    final st = s.style;
    if (st == null) return null;
    final fill = st.fill;
    // A zero-width stroke draws nothing.
    final stroke = st.stroke != null && st.strokeWidth > 0 ? st.stroke : null;
    if (fill == null && stroke == null) return null;
    var path = _shapePath(s);
    if (stroke != null && (st.dash > 0 || st.gap > 0)) {
      path = _dashPath(path, st.dash, st.gap, st.dashOffset);
    }
    return _Compiled(
      path,
      fill,
      stroke,
      st.strokeWidth,
      switch (st.lineCap) {
        SvgaLineCap.butt => ui.StrokeCap.butt,
        SvgaLineCap.round => ui.StrokeCap.round,
        SvgaLineCap.square => ui.StrokeCap.square,
      },
      switch (st.lineJoin) {
        SvgaLineJoin.miter => ui.StrokeJoin.miter,
        SvgaLineJoin.round => ui.StrokeJoin.round,
        SvgaLineJoin.bevel => ui.StrokeJoin.bevel,
      },
      st.miterLimit > 0 ? st.miterLimit : 0,
    );
  }

  ui.Path _shapePath(SvgaShape s) {
    switch (s.type) {
      case SvgaShapeType.rect:
        var r = s.cornerRadius;
        if (s.width < 2 * r) r = s.width / 2;
        if (s.height < 2 * r) r = s.height / 2;
        final rect = ui.Rect.fromLTWH(s.x, s.y, s.width, s.height);
        return r > 0
            ? (ui.Path()..addRRect(
                ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(r)),
              ))
            : (ui.Path()..addRect(rect));
      case SvgaShapeType.ellipse:
        return ui.Path()..addOval(
          ui.Rect.fromCenter(
            center: ui.Offset(s.x, s.y),
            width: 2 * s.radiusX.abs(),
            height: 2 * s.radiusY.abs(),
          ),
        );
      default:
        return _svg(s.d);
    }
  }

  /// Canvas `setLineDash([dash, gap])` + `lineDashOffset`: the pattern restarts on every subpath and starts [offset] into the pattern.
  static ui.Path _dashPath(
    ui.Path src,
    double dash,
    double gap,
    double offset,
  ) {
    final out = ui.Path();
    final period = dash + gap;
    if (!(period > 0)) return src;
    for (final m in src.computeMetrics()) {
      var phase = offset % period;
      if (phase < 0) phase += period;
      var pos = 0.0;
      var drawing = phase < dash;
      var remaining = drawing ? dash - phase : period - phase;
      while (pos < m.length) {
        final end = (pos + remaining).clamp(0.0, m.length);
        if (drawing && end > pos) {
          out.addPath(m.extractPath(pos, end), ui.Offset.zero);
        }
        pos = end;
        drawing = !drawing;
        remaining = drawing ? dash : gap;
        if (remaining <= 0 && !drawing) remaining = 0;
        if (dash <= 0 && drawing) {
          // zero-length dashes: nothing visible without caps; advance by the gap to avoid looping forever
          drawing = false;
          remaining = gap > 0 ? gap : m.length;
        }
        if (remaining <= 0) remaining = period;
      }
    }
    return out;
  }

  void _drawReplacement(
    ui.Canvas canvas,
    _ImageRepl r,
    SvgaLayout l,
    double alpha,
  ) {
    final bmp = r.image;
    final bw = bmp.width.toDouble(), bh = bmp.height.toDouble();
    _paint
      ..color = ui.Color.fromRGBO(255, 255, 255, alpha)
      ..filterQuality = ui.FilterQuality.medium
      ..isAntiAlias = true;
    final full = ui.Rect.fromLTWH(0, 0, bw, bh);
    if (!(l.width > 0 && l.height > 0)) {
      canvas.drawImageRect(
        bmp,
        full,
        ui.Rect.fromLTWH(l.x, l.y, bw, bh),
        _paint,
      );
      return;
    }
    final dst = ui.Rect.fromLTWH(l.x, l.y, l.width, l.height);
    switch (r.fit) {
      case GiftImageFit.fill:
        canvas.drawImageRect(bmp, full, dst, _paint);
      case GiftImageFit.cover:
        final scale = (l.width / bw) > (l.height / bh)
            ? l.width / bw
            : l.height / bh;
        final sw = l.width / scale, sh = l.height / scale;
        canvas.drawImageRect(
          bmp,
          ui.Rect.fromLTWH((bw - sw) / 2, (bh - sh) / 2, sw, sh),
          dst,
          _paint,
        );
      case GiftImageFit.contain:
        final scale = (l.width / bw) < (l.height / bh)
            ? l.width / bw
            : l.height / bh;
        final dw = bw * scale, dh = bh * scale;
        canvas.drawImageRect(
          bmp,
          full,
          ui.Rect.fromLTWH(
            l.x + (l.width - dw) / 2,
            l.y + (l.height - dh) / 2,
            dw,
            dh,
          ),
          _paint,
        );
    }
  }

  void _drawText(ui.Canvas canvas, _TextRepl t, SvgaLayout l, double alpha) {
    final w = l.width, h = l.height;
    final tw = t.fill.width;
    final anchorX = switch (t.align) {
      GiftTextAlign.left => l.x,
      GiftTextAlign.right => l.x + w,
      GiftTextAlign.center => l.x + w / 2,
    };
    final factor = switch (t.align) {
      GiftTextAlign.left => 0.0,
      GiftTextAlign.center => 0.5,
      GiftTextAlign.right => 1.0,
    };
    // Text wider than the layout rect is squeezed horizontally to fit (canvas fillText with maxWidth).
    final k = w > 0 && tw > w ? w / tw : 1.0;
    canvas.save();
    if (alpha < 1) {
      canvas.saveLayer(
        null,
        ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, alpha),
      );
    }
    canvas.translate(anchorX, l.y + h / 2 - t.fill.height / 2);
    canvas.scale(k, 1);
    final at = ui.Offset(-tw * factor, 0);
    t.stroke?.paint(canvas, at);
    t.fill.paint(canvas, at);
    if (alpha < 1) canvas.restore();
    canvas.restore();
  }

  // ---- dynamic replacement -----------------------------------------------------------------------------------------------

  bool _knows(String key) {
    if (_byKey.containsKey(key)) return true;
    _warn('unknown key "$key": no sprite uses it, ignoring.');
    return false;
  }

  /// Replaces the bitmap of every sprite whose imageKey is [key]. The image is drawn into the sprite's layout rect; the sprite's clip
  /// and matte still apply. Survives seek and looping. Unknown keys log a warning and do nothing.
  @override
  Future<void> setImage(
    String key,
    Object source, [
    GiftImageOptions options = const GiftImageOptions(),
  ]) async {
    if (!_knows(key)) return;
    final token = (_imageTokens[key] ?? 0) + 1;
    _imageTokens[key] = token;
    final loaded = await loadReplacementImage(source);
    // A newer setImage/clear for the same key (or destroy) won the race while we were decoding.
    if (_destroyed || _imageTokens[key] != token) {
      if (loaded.owned) loaded.image.dispose();
      return;
    }
    _releaseReplacement(key);
    final repl = _ImageRepl(loaded.image, loaded.owned, options.fit);
    _replacementImages[key] = repl;
    for (final rt in _byKey[key]!) {
      rt.image = repl;
    }
    _redraw();
  }

  /// Draws [text] centred (by default) in the layout rect of every sprite whose imageKey is [key], on top of its bitmap. Text wider
  /// than the layout rect is squeezed to fit.
  @override
  void setText(
    String key,
    String text, [
    GiftTextStyle style = const GiftTextStyle(),
  ]) {
    if (!_knows(key)) return;
    final families = (style.font ?? 'sans-serif')
        .split(',')
        .map((s) => s.trim().replaceAll(RegExp('''^["']|["']\$'''), ''))
        .where((s) => s.isNotEmpty)
        .toList();
    final family = families.isEmpty ? null : _genericFamily(families.first);
    TextStyle base(Color color) => TextStyle(
      fontSize: style.size ?? 14,
      fontWeight: fontWeightOf(style.weight),
      fontFamily: family,
      fontFamilyFallback: families.length > 1
          ? families.skip(1).map(_genericFamily).whereType<String>().toList()
          : null,
      color: color,
      height: 1,
    );
    TextPainter painter(TextStyle ts) => TextPainter(
      text: TextSpan(text: text, style: ts),
      textDirection: TextDirection.ltr,
    )..layout();
    final fill = painter(base(style.color ?? const Color(0xff000000)));
    TextPainter? stroke;
    final st = style.stroke;
    if (st != null && st.width > 0) {
      stroke = painter(
        TextStyle(
          fontSize: style.size ?? 14,
          fontWeight: fontWeightOf(style.weight),
          fontFamily: family,
          fontFamilyFallback: families.length > 1
              ? families
                    .skip(1)
                    .map(_genericFamily)
                    .whereType<String>()
                    .toList()
              : null,
          height: 1,
          foreground: ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = st.width
            ..strokeJoin = ui.StrokeJoin.round
            ..color = st.color,
        ),
      );
    }
    final repl = _TextRepl(fill, stroke, style.align ?? GiftTextAlign.center);
    for (final rt in _byKey[key]!) {
      rt.text = repl;
    }
    _redraw();
  }

  static String? _genericFamily(String f) =>
      const {
        'sans-serif',
        'serif',
        'monospace',
        'system-ui',
      }.contains(f.toLowerCase())
      ? null
      : f;

  /// Hides (or shows again) every sprite whose imageKey is [key].
  @override
  void setHidden(String key, bool hidden) {
    if (!_knows(key)) return;
    for (final rt in _byKey[key]!) {
      rt.hidden = hidden;
    }
    _redraw();
  }

  /// Removes any image/text replacement and un-hides the sprites for [key].
  @override
  void clearReplacement(String key) {
    if (!_knows(key)) return;
    _imageTokens[key] =
        (_imageTokens[key] ?? 0) + 1; // cancel an in-flight setImage
    _releaseReplacement(key);
    for (final rt in _byKey[key]!) {
      rt.image = null;
      rt.text = null;
      rt.hidden = false;
    }
    _redraw();
  }

  void _releaseReplacement(String key) {
    final old = _replacementImages.remove(key);
    if (old == null) return;
    for (final rt in _byKey[key] ?? const <_Runtime>[]) {
      if (rt.image == old) rt.image = null;
    }
    if (old.owned) old.image.dispose();
  }

  // ---- lifecycle ---------------------------------------------------------------------------------------------------------

  /// Disposes every image it owns and drops all caches. Safe to call twice.
  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _current = -1;
    for (final key in _replacementImages.keys.toList()) {
      _releaseReplacement(key);
    }
    if (!sharedImages) {
      for (final b in bitmaps.values) {
        b.dispose();
      }
      bitmaps.clear();
    }
    _runtimes.clear();
    _items.clear();
    _byKey.clear();
    _paths.clear();
    repaint.notify();
  }
}
