import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../detect.dart';
import '../errors.dart';
import '../renderer.dart';
import '../viewport.dart';
import 'meta.dart';

/// Renderer for GIF and WebP (animated or still) behind the same [GiftRenderer] contract as SVGA: per-frame durations, the file's
/// loop count, `drawFrame(i)`. Frames are decoded by the platform codec (`dart:ui`), on demand with a small look-ahead window when the
/// whole animation would not fit in [maxCacheBytes], and all at once (kept) when it fits.
class AnimatedImageRenderer extends GiftRenderer {
  AnimatedImageRenderer._(
    this._codec,
    this._meta,
    this._durations,
    this._plays,
    this._width,
    this._height,
    this._lookAhead,
    this._maxCacheBytes,
    this._onError,
    this._mode,
  );

  final ui.Codec _codec;
  final ImageMeta _meta;
  final List<double> _durations;
  final int? _plays;
  final int _width, _height;
  final int _lookAhead;
  final int _maxCacheBytes;
  final void Function(Object error) _onError;
  ContentMode _mode;

  final Map<int, ui.Image> _frames = {};
  int _nextDecode = 0; // index of the frame the codec produces next
  Future<void> _chain = Future.value(); // decode requests run one after another
  int _shown = -1; // frame on screen, or -1
  int _wanted = -1;
  bool _destroyed = false;
  final ui.Paint _paint = ui.Paint()
    ..filterQuality = ui.FilterQuality.medium
    ..isAntiAlias = true;

  /// Decodes the container header, opens the codec, and returns a renderer ready for `drawFrame`.
  static Future<AnimatedImageRenderer> create(
    Uint8List bytes, {
    ContentMode contentMode = ContentMode.aspectFit,
    int staticDurationMs = 2000,
    int lookAhead = 3,
    int maxCacheBytes = 48 * 1024 * 1024,
    void Function(Object error)? onError,
  }) async {
    final info = detectFormat(bytes);
    if (info.format != GiftFormat.gif && info.format != GiftFormat.webp) {
      throw GiftPlayerError(
        GiftErrorCode.unsupportedFormat,
        'AnimatedImageRenderer handles GIF and WebP, not ${info.format.name}.',
      );
    }
    final ImageMeta meta;
    try {
      meta = info.format == GiftFormat.gif
          ? readGifMeta(bytes)
          : readWebpMeta(bytes);
    } on GiftPlayerError {
      rethrow;
    } catch (cause) {
      throw GiftPlayerError(
        GiftErrorCode.parseFailed,
        'This image file is corrupt.',
        cause: cause,
      );
    }
    final ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (cause) {
      throw GiftPlayerError(
        GiftErrorCode.decodeFailed,
        'The platform could not decode this ${info.format.name.toUpperCase()}.',
        cause: cause,
      );
    }
    // Trust the codec's frame count if it disagrees with our container walk (a truncated file).
    var count = codec.frameCount;
    if (count < 1) count = 1;
    final single = meta.frameCount == 1 || count == 1;
    final durations = single
        ? <double>[staticDurationMs.toDouble()]
        : [
            for (var i = 0; i < count; i++)
              i < meta.durations.length
                  ? meta.durations[i]
                  : meta.durations.last,
          ];
    var w = meta.width, h = meta.height;
    final r = AnimatedImageRenderer._(
      codec,
      meta,
      durations,
      single ? 1 : meta.loopCount,
      w,
      h,
      lookAhead,
      maxCacheBytes,
      onError ?? (e) => debugPrint('[gift-player] $e'),
      contentMode,
    );
    try {
      // The first frame also gives the size of a still WebP (no VP8X).
      await r._decodeThrough(0);
      final first = r._frames[0]!;
      r._size = ui.Size(first.width.toDouble(), first.height.toDouble());
    } catch (e) {
      codec.dispose();
      throw e is GiftPlayerError
          ? e
          : GiftPlayerError(
              GiftErrorCode.decodeFailed,
              'The first frame could not be decoded.',
              cause: e,
            );
    }
    return r;
  }

  late ui.Size _size = ui.Size(_width.toDouble(), _height.toDouble());

  /// Which decoding strategy is in use.
  String get path =>
      _keepAll ? 'codec (all frames cached)' : 'codec (streaming window)';

  bool get _keepAll {
    final per = _size.width * _size.height * 4;
    return per * _durations.length <= _maxCacheBytes;
  }

  String get format => _meta.format;

  @override
  ui.Size get size => _size;

  @override
  int get frameCount => _durations.length;

  @override
  double frameDuration(int i) =>
      i >= 0 && i < _durations.length ? _durations[i] : _durations.last;

  @override
  int? get loopCount => _plays;

  @override
  ContentMode get contentMode => _mode;

  @override
  set contentMode(ContentMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    repaint.notify();
  }

  @override
  bool get hasFrame => _shown >= 0;

  // ---- decoding ----------------------------------------------------------------------------------------------------------

  /// Decodes sequentially until frame [i] has been produced. The codec wraps around after the last frame.
  Future<void> _decodeThrough(int i) {
    final done = _chain.then((_) async {
      if (_destroyed || _frames.containsKey(i)) return;
      final total = _codec.frameCount < 1 ? 1 : _codec.frameCount;
      var steps = i >= _nextDecode
          ? i - _nextDecode + 1
          : total - _nextDecode + i + 1;
      while (steps-- > 0) {
        final fi = await _codec.getNextFrame();
        if (_destroyed) {
          fi.image.dispose();
          return;
        }
        final idx = _nextDecode;
        _nextDecode = (_nextDecode + 1) % total;
        final old = _frames[idx];
        if (old != null && idx != _shown) old.dispose();
        _frames[idx] = fi.image;
      }
    });
    // Keep the chain alive after a failure; the failure itself goes to the caller.
    _chain = done.then((_) {}, onError: (_) {});
    return done;
  }

  void _evict(int around) {
    if (_keepAll) return;
    final keep = <int>{_shown, around};
    for (var k = 1; k <= _lookAhead; k++) {
      keep.add((around + k) % frameCount);
    }
    for (final idx in _frames.keys.toList()) {
      if (!keep.contains(idx)) _frames.remove(idx)?.dispose();
    }
  }

  void _prefetch(int from) {
    for (var k = 1; k <= _lookAhead; k++) {
      final n = (from + k) % frameCount;
      if (!_frames.containsKey(n)) {
        _decodeThrough(n).catchError((Object e) {
          if (!_destroyed) _onError(e);
        });
      }
    }
  }

  @override
  bool drawFrame(int index) {
    if (_destroyed) return false;
    final i = index < 0 ? 0 : (index >= frameCount ? frameCount - 1 : index);
    if (frameCount == 1 && _frames.containsKey(0)) {
      _shown = 0;
      repaint.notify();
      return true;
    }
    if (_frames.containsKey(i)) {
      _wanted = -1;
      _shown = i;
      _evict(i);
      repaint.notify();
      _prefetch(i);
      return true;
    }
    // Still decoding: keep showing the previous frame and show this one when it is ready (if still wanted).
    _wanted = i;
    _decodeThrough(i).then(
      (_) {
        if (!_destroyed && _wanted == i) drawFrame(i);
      },
      onError: (Object e) {
        if (!_destroyed) {
          _onError(
            GiftPlayerError(
              GiftErrorCode.decodeFailed,
              'A frame could not be decoded.',
              cause: e,
            ),
          );
        }
      },
    );
    return false;
  }

  @override
  Future<void> ready(int i) {
    final idx = i < 0 ? 0 : (i >= frameCount ? frameCount - 1 : i);
    if (_frames.containsKey(idx)) return Future.value();
    return _decodeThrough(idx);
  }

  @override
  void clear() {
    if (_destroyed) return;
    _shown = -1;
    _wanted = -1;
    repaint.notify();
  }

  @override
  void paint(ui.Canvas canvas, ui.Size box) {
    if (_destroyed || _shown < 0 || box.isEmpty) return;
    final img = _frames[_shown];
    if (img == null) return;
    canvas.save();
    applyView(canvas, box, _size.width, _size.height, _mode);
    canvas.drawImage(img, ui.Offset.zero, _paint);
    canvas.restore();
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _shown = -1;
    // Wait for a decode in flight before releasing the codec.
    _chain.whenComplete(() {
      for (final f in _frames.values) {
        f.dispose();
      }
      _frames.clear();
      _codec.dispose();
    });
    repaint.notify();
  }
}
