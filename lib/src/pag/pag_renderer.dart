import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../errors.dart';
import '../renderer.dart';
import '../replacement.dart';
import '../viewport.dart';
import 'pag_platform.dart';

void _warn(String msg) => debugPrint('[gift-player] $msg');

/// Scripts that need shaping (Indic, Arabic, Hebrew, Thai, Khmer, Myanmar, ...) or right-to-left ordering. libpag draws text glyph by
/// glyph without a shaper, so these render wrongly in PAG text layers (SVGA, which uses Flutter's text engine, is fine).
final RegExp complexScript = RegExp('[֐-ࣿऀ-෿฀-໿ༀ-࿿က-႟ក-៿יִ-﷿ﹰ-﻿]');

int _argb(ui.Color c) => c.toARGB32();

/// PAG (libpag) behind the same [GiftRenderer] contract as every other format. libpag renders natively (Metal/OpenGL) into a Flutter
/// texture; our own [FrameClock] drives it frame by frame (`render(progress)`), so loops, events and seeking behave exactly as for
/// SVGA / GIF / WebP.
///
/// Frames are rendered asynchronously: `drawFrame(i)` returns false and the frame appears when the native side has flushed it; if the
/// clock moves on faster than libpag can render, intermediate frames are skipped (never queued).
class PagRenderer extends GiftRenderer {
  PagRenderer._(this._info, ContentMode mode) : _mode = mode {
    _fps = _info.frameRate > 0 ? _info.frameRate : 30;
    _count = ((_info.durationUs * _fps) / 1e6).round().clamp(1, 1 << 30);
    _buildEditable();
  }

  final PagFileInfo _info;
  late final double _fps;
  late final int _count;
  ContentMode _mode;
  final List<EditableKey> _keys = [];
  final Map<String, int> _textIndexByKey = {};
  final Map<String, int> _imageIndexByKey = {};
  final Map<int, Map<String, Object?>> _originalText = {};
  final Set<int> _replacedImages = {};
  final Map<String, int> _imageTokens = {};
  final List<({int frame, Completer<void> done})> _waiters = [];
  int _wanted = 0;
  int _current = -1;
  bool _pumping = false;
  Future<void> _pumpDone = Future.value();
  bool _destroyed = false;
  bool _warnedComplexScript = false;
  ui.Size? _viewPx;
  void Function(Object error)? onError;

  /// Loads the native engine (first use only), parses [bytes], and returns a renderer ready for `drawFrame`.
  ///
  /// [viewPixels] is the size of the surface to render into, in physical pixels (the view reports it later through [setViewSize]).
  static Future<PagRenderer> create(
    Uint8List bytes, {
    ui.Size? viewPixels,
    ContentMode contentMode = ContentMode.aspectFit,
    void Function(Object error)? onError,
  }) async {
    await PagPlatform.ensureEngine();
    final w = (viewPixels?.width ?? 0) > 0 ? viewPixels!.width.round() : 0;
    final h = (viewPixels?.height ?? 0) > 0 ? viewPixels!.height.round() : 0;
    final info = await PagPlatform.create(bytes, w, h);
    final r = PagRenderer._(info, contentMode);
    r.onError = onError;
    r._viewPx = w > 0 && h > 0 ? ui.Size(w.toDouble(), h.toDouble()) : null;
    try {
      await PagPlatform.setScaleMode(info.id, _scaleOf(contentMode));
    } catch (_) {
      await PagPlatform.dispose(info.id).catchError((Object _) {});
      rethrow;
    }
    return r;
  }

  static int _scaleOf(ContentMode m) => switch (m) {
    ContentMode.aspectFit => pagScaleLetterbox,
    ContentMode.fill => pagScaleStretch,
    ContentMode.aspectFill => pagScaleZoom,
  };

  // ---- GiftRenderer -------------------------------------------------------------------------------------------------------

  @override
  int get frameCount => _count;

  @override
  double frameDuration(int i) => 1000 / _fps;

  /// PAG files carry no loop count.
  @override
  int? get loopCount => null;

  @override
  ui.Size get size => ui.Size(_info.width.toDouble(), _info.height.toDouble());

  @override
  int? get textureId => _info.textureId;

  @override
  bool get hasFrame => _current >= 0;

  @override
  ContentMode get contentMode => _mode;

  @override
  set contentMode(ContentMode mode) {
    if (mode == _mode || _destroyed) return;
    _mode = mode;
    PagPlatform.setScaleMode(
      _info.id,
      _scaleOf(mode),
    ).then((_) => _requestRedraw(), onError: _report);
  }

  @override
  void paint(ui.Canvas canvas, ui.Size box) {}

  @override
  void setViewSize(ui.Size pixels) {
    if (_destroyed || pixels.isEmpty) return;
    final w = pixels.width.round(), h = pixels.height.round();
    if (_viewPx != null &&
        _viewPx!.width.round() == w &&
        _viewPx!.height.round() == h) {
      return;
    }
    _viewPx = ui.Size(w.toDouble(), h.toDouble());
    // libpag must have the surface at its final size; re-render the wanted frame once it is resized.
    PagPlatform.resize(
      _info.id,
      w,
      h,
    ).then((_) => _requestRedraw(), onError: _report);
  }

  void _report(Object e) {
    if (!_destroyed) (onError ?? (x) => _warn('$x'))(e);
  }

  /// progress (0..1) that libpag maps to the start of frame [i].
  double _progressOf(int i) => (((i * 1e6) / _fps + 1) / _info.durationUs)
      .clamp(0.0, 1.0); // +1 microsecond: stay inside the frame

  @override
  bool drawFrame(int index) {
    if (_destroyed) return false;
    final i = index < 0 ? 0 : (index >= _count ? _count - 1 : index);
    _wanted = i;
    if (_current == i && !_pumping) return true;
    unawaited(_pump());
    return false;
  }

  @override
  void clear() {
    if (_destroyed) return;
    _wanted = -1;
    _current = -1;
    _settle();
    repaint.notify();
  }

  @override
  Future<void> ready(int index) {
    if (_destroyed) return Future.value();
    final i = index < 0 ? 0 : (index >= _count ? _count - 1 : index);
    if (_current == i && !_pumping && _wanted == i) return Future.value();
    drawFrame(i);
    final c = Completer<void>();
    _waiters.add((frame: i, done: c));
    return c.future;
  }

  /// Marks the surface stale (after a size change or a replacement) and renders the wanted frame again.
  void _requestRedraw() {
    _current = -1;
    if (!_destroyed && _wanted >= 0) unawaited(_pump());
  }

  Future<void> _pump() {
    if (_pumping) return _pumpDone;
    _pumping = true;
    _pumpDone = () async {
      try {
        while (!_destroyed && _wanted >= 0 && _current != _wanted) {
          final i = _wanted;
          await PagPlatform.render(_info.id, _progressOf(i));
          if (_destroyed || _wanted < 0) break; // cleared while rendering
          _current = i;
          repaint.notify();
          _settle();
        }
      } catch (e) {
        _report(e);
      } finally {
        _pumping = false;
        _settle(all: true);
      }
    }();
    return _pumpDone;
  }

  /// Completes `ready()` waiters whose frame is on screen, or was skipped because a later frame was requested.
  void _settle({bool all = false}) {
    for (var k = _waiters.length - 1; k >= 0; k--) {
      final w = _waiters[k];
      if (all || _current == w.frame || _wanted != w.frame) {
        _waiters.removeAt(k);
        if (!w.done.isCompleted) w.done.complete();
      }
    }
  }

  // ---- dynamic replacement ------------------------------------------------------------------------------------------------

  void _buildEditable() {
    void add(
      List<int> indices,
      List<String> names,
      String kind,
      Map<String, int> map,
    ) {
      final entries = [
        for (var k = 0; k < indices.length; k++)
          (index: indices[k], name: k < names.length ? names[k] : ''),
      ];
      for (final e in entries) {
        final unique =
            e.name != '' && entries.where((x) => x.name == e.name).length == 1;
        final key = unique ? e.name : '#${e.index}';
        _keys.add(
          EditableKey(key: key, type: kind, index: e.index, name: e.name),
        );
        map[key] = e.index;
        map['#${e.index}'] = e.index;
        if (e.name != '' && !map.containsKey(e.name)) {
          map[e.name] = e.index; // ambiguous names still resolve (first wins)
        }
      }
    }

    add(_info.textIndices, _info.textNames, 'text', _textIndexByKey);
    add(_info.imageIndices, _info.imageNames, 'image', _imageIndexByKey);
  }

  @override
  bool get supportsReplacement => true;

  /// The layers `setText` / `setImage` / `setHidden` can address: editable text and image layers (by name or `#index`).
  @override
  List<EditableKey> getEditableKeys() => List.unmodifiable(_keys);

  /// Replaces the text of an editable text layer (by layer name or `#index`). If the key is not an editable layer but names an ordinary
  /// text layer, that layer's text is set directly. Unknown keys log a warning and do nothing.
  @override
  void setText(
    String key,
    String text, [
    GiftTextStyle style = const GiftTextStyle(),
  ]) {
    if (_destroyed) return;
    if (!_warnedComplexScript && complexScript.hasMatch(text)) {
      _warnedComplexScript = true; // once per renderer
      _warn(
        'PAG text layers cannot shape complex scripts: Devanagari, Gujarati and other Indic scripts, Arabic, Hebrew, Thai, ... '
        'are drawn glyph by glyph (wrong or missing marks, no joining, no right-to-left order). Latin, CJK and emoji are fine. '
        'Use an SVGA gift for personalised names in these scripts.',
      );
    }
    unawaited(_setText(key, text, style).catchError(_report));
  }

  Future<void> _setText(String key, String text, GiftTextStyle style) async {
    final idx = _textIndexByKey[key];
    if (idx != null) {
      final doc = await PagPlatform.getTextData(_info.id, idx);
      if (_destroyed) return;
      _originalText.putIfAbsent(idx, () => Map<String, Object?>.of(doc));
      doc['text'] = text;
      if (style.size != null) doc['fontSize'] = style.size;
      if (style.font != null) {
        doc['fontFamily'] = style.font!.split(',').first.trim();
      }
      if (style.weight != null) {
        final bold =
            style.weight == 'bold' ||
            (int.tryParse('${style.weight}') ?? 0) >= 600;
        doc['fauxBold'] = bold;
        doc['fontStyle'] = bold ? 'Bold' : 'Regular';
      }
      if (style.color != null) {
        doc['fillColor'] = _argb(style.color!);
        doc['applyFill'] = true;
      }
      if (style.align != null) doc['justification'] = style.align!.index;
      if (style.stroke != null) {
        doc['strokeColor'] = _argb(style.stroke!.color);
        doc['strokeWidth'] = style.stroke!.width;
        doc['applyStroke'] = style.stroke!.width > 0;
      }
      await PagPlatform.replaceText(_info.id, idx, doc);
      _requestRedraw();
      return;
    }
    final n = await PagPlatform.setLayerText(
      _info.id,
      key,
      text,
      size: style.size,
      color: style.color == null ? null : _argb(style.color!),
    );
    if (_destroyed) return;
    if (n == 0) {
      final names = _keys
          .where((k) => k.type == 'text')
          .map((k) => k.key)
          .join(', ');
      _warn(
        'unknown text key "$key": not an editable text layer (editable: ${names.isEmpty ? 'none' : names}).',
      );
      return;
    }
    _requestRedraw();
  }

  /// Replaces the picture of an editable image layer (by layer name or `#index`). Bytes and URL sources are decoded by the native
  /// side; a `ui.Image` is re-encoded to PNG first.
  @override
  Future<void> setImage(
    String key,
    Object source, [
    GiftImageOptions options = const GiftImageOptions(),
  ]) async {
    if (_destroyed) return;
    final idx = _imageIndexByKey[key];
    if (idx == null) {
      final names = _keys
          .where((k) => k.type == 'image')
          .map((k) => k.key)
          .join(', ');
      _warn(
        'unknown image key "$key": not an editable image layer (editable: ${names.isEmpty ? 'none' : names}).',
      );
      return;
    }
    final token = (_imageTokens[key] ?? 0) + 1;
    _imageTokens[key] = token;
    final Uint8List bytes;
    if (source is Uint8List) {
      bytes = source;
    } else if (source is ui.Image) {
      final data = await source.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw GiftPlayerError(
          GiftErrorCode.decodeFailed,
          'The replacement image could not be encoded.',
        );
      }
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      final loaded = await loadReplacementImage(
        source,
      ); // validates and downloads URLs
      try {
        final data = await loaded.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data == null) {
          throw GiftPlayerError(
            GiftErrorCode.decodeFailed,
            'The replacement image could not be encoded.',
          );
        }
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        if (loaded.owned) loaded.image.dispose();
      }
    }
    if (_destroyed || _imageTokens[key] != token) return;
    final scale = switch (options.fit) {
      GiftImageFit.fill => pagScaleStretch,
      GiftImageFit.contain => pagScaleLetterbox,
      GiftImageFit.cover => pagScaleZoom,
    };
    await PagPlatform.replaceImage(_info.id, idx, bytes, scale);
    if (_destroyed) return;
    _replacedImages.add(idx);
    _requestRedraw();
  }

  /// Hides (or shows) the layer(s) with this name, or the editable layer `#index`.
  @override
  void setHidden(String key, bool hidden) {
    if (_destroyed) return;
    unawaited(_setHidden(key, hidden).catchError(_report));
  }

  Future<void> _setHidden(String key, bool hidden) async {
    final textIdx = _textIndexByKey[key];
    final imgIdx = _imageIndexByKey[key];
    final n = await PagPlatform.setLayerVisible(
      _info.id,
      name: key,
      index: textIdx ?? imgIdx,
      type: textIdx != null
          ? pagLayerText
          : (imgIdx != null ? pagLayerImage : null),
      visible: !hidden,
    );
    if (_destroyed) return;
    if (n == 0) {
      _warn('unknown key "$key": no layer has this name.');
      return;
    }
    _requestRedraw();
  }

  /// Restores an edited text layer and shows hidden layers. A replaced image cannot be restored (PAG has no API for it): set another
  /// image instead.
  @override
  void clearReplacement(String key) {
    if (_destroyed) return;
    unawaited(_clearReplacement(key).catchError(_report));
  }

  Future<void> _clearReplacement(String key) async {
    final idx = _textIndexByKey[key];
    if (idx != null && _originalText.containsKey(idx)) {
      final orig = _originalText.remove(idx)!;
      await PagPlatform.replaceText(_info.id, idx, orig);
    }
    final imgIdx = _imageIndexByKey[key];
    if (imgIdx != null && _replacedImages.contains(imgIdx)) {
      _warn(
        'cannot restore the original image of "$key" (PAG has no API for it); set another image instead.',
      );
    }
    await PagPlatform.setLayerVisible(_info.id, name: key, visible: true);
    if (_destroyed) return;
    _requestRedraw();
  }

  // ---- lifecycle ----------------------------------------------------------------------------------------------------------

  /// Releases the native player, surface and texture. A frame that is being rendered finishes first (libpag must not be torn down in
  /// the middle of a flush).
  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _settle(all: true);
    _pumpDone.then((_) {}, onError: (_) {}).whenComplete(() {
      PagPlatform.dispose(_info.id).catchError((Object e) {
        (onError ?? (x) => _warn('$x'))(e);
      });
    });
    repaint.notify();
  }
}
