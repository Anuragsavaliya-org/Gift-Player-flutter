import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'abort.dart';
import 'asset.dart' hide registerResolver;
import 'asset.dart' as asset_lib show registerResolver;
import 'cache.dart';
import 'detect.dart';
import 'emitter.dart';
import 'errors.dart';
import 'frame_clock.dart';
import 'image/image_renderer.dart';
import 'pag/pag_renderer.dart';
import 'renderer.dart';
import 'replacement.dart';
import 'svga/svga_renderer.dart';
import 'viewport.dart';

/// Options for `GiftPlayer(options)`.
class GiftPlayerOptions {
  const GiftPlayerOptions({
    this.contentMode = ContentMode.aspectFit,
    this.loops,
    this.clearOnEnd = true,
    this.pauseWhenHidden = true,
    this.cache,
    this.staticDurationMs = 2000,
  });

  /// How the gift fits the view. Default [ContentMode.aspectFit].
  final ContentMode contentMode;

  /// Number of plays; 0 = forever. Default: the file's own count, else once. `load()` can override per gift.
  final int? loops;

  /// Clear the view when the last play ends (after the `end` event), so a finished gift never stays frozen over the video. Default
  /// true. `false` keeps the last frame on screen. Can be overridden per `load()`.
  final bool clearOnEnd;

  /// Pause while the app is in the background and continue from the same frame afterwards. Default true.
  final bool pauseWhenHidden;

  /// Share decoded gifts with other players through this cache. Default: the module-wide cache (64 MB).
  final AssetCache<LoadedGift>? cache;

  /// How long a still GIF / WebP is shown, ms. Default 2000.
  final int staticDurationMs;

  GiftPlayerOptions copyWith({
    ContentMode? contentMode,
    int? loops,
    bool? clearOnEnd,
    bool? pauseWhenHidden,
    int? staticDurationMs,
  }) => GiftPlayerOptions(
    contentMode: contentMode ?? this.contentMode,
    loops: loops ?? this.loops,
    clearOnEnd: clearOnEnd ?? this.clearOnEnd,
    pauseWhenHidden: pauseWhenHidden ?? this.pauseWhenHidden,
    cache: cache,
    staticDurationMs: staticDurationMs ?? this.staticDurationMs,
  );
}

/// Options for `player.load(src, options)`.
class LoadOptions {
  const LoadOptions({
    this.replacements,
    this.signal,
    this.loops,
    this.clearOnEnd,
  });

  /// Applied before the first frame is drawn, so the original text never flashes. Unknown keys warn and are skipped.
  final Replacements? replacements;

  /// Aborting rejects `load()` with code `aborted`.
  final AbortSignal? signal;

  /// Number of plays for this gift (overrides the player option and the file). 0 = forever.
  final int? loops;

  /// Overrides the player's `clearOnEnd` for this gift.
  final bool? clearOnEnd;
}

/// What `load()` resolves to.
class GiftInfo {
  const GiftInfo({
    required this.format,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.durationMs,
    required this.editableKeys,
  });

  final GiftFormat format;
  final double width, height;
  final int frameCount;

  /// Length of one play in milliseconds.
  final double durationMs;

  /// Layers that `setText` / `setImage` / `setHidden` accept (empty for GIF and WebP).
  final List<EditableKey> editableKeys;

  @override
  String toString() =>
      'GiftInfo(${format.name} ${width}x$height, $frameCount frames, ${durationMs}ms, ${editableKeys.length} editable)';
}

/// Outcome of preloading one source: `cached`, `skipped` (not a cacheable source), or `failed` with the error.
enum PreloadStatus { cached, skipped, failed }

class PreloadResult {
  const PreloadResult(this.src, this.status, [this.error]);
  final Object src;
  final PreloadStatus status;
  final GiftPlayerError? error;
}

GiftPlayerError _aborted(String why) =>
    GiftPlayerError(GiftErrorCode.aborted, why);

GiftPlayerError _toError(Object e) => e is GiftPlayerError
    ? e
    : GiftPlayerError(GiftErrorCode.decodeFailed, e.toString(), cause: e);

void _warn(String msg) => debugPrint('[gift-player] $msg');

AssetCache<LoadedGift>? _defaultCache;

/// The module-wide cache, created on first use.
AssetCache<LoadedGift> getDefaultCache() =>
    _defaultCache ??= AssetCache<LoadedGift>();

class _Pending {
  final Completer<void> completer = Completer<void>();
}

/// Plays one gift at a time (SVGA, GIF, WebP or PAG). Show it with a `GiftPlayerSurface(player: player)` widget (or use the
/// declarative `GiftPlayerView`). One player can `load()` many gifts in a row.
///
/// ```dart
/// final player = GiftPlayer(const GiftPlayerOptions(contentMode: ContentMode.aspectFit));
/// // in build(): SizedBox(width: 360, height: 360, child: GiftPlayerSurface(player: player))
/// await player.load('https://cdn.example/rocket.svga', options: LoadOptions(replacements: {'name': Replacement.text('Rahul')}));
/// await player.play(); // completes when the last play ends
/// player.destroy();
/// ```
class GiftPlayer with WidgetsBindingObserver {
  GiftPlayer([GiftPlayerOptions options = const GiftPlayerOptions()])
    : _options = options,
      _cache = options.cache ?? getDefaultCache() {
    _mode = options.contentMode;
    if (options.pauseWhenHidden) {
      WidgetsFlutterBinding.ensureInitialized();
      WidgetsBinding.instance.addObserver(this);
    }
  }

  GiftPlayerOptions _options;
  final AssetCache<LoadedGift> _cache;
  late ContentMode _mode;

  // ---- events ------------------------------------------------------------------------------------------------------------

  /// A gift is loaded and its first frame is on screen.
  final GiftEvent<GiftInfo> onLoaded = GiftEvent();

  /// The first frame of a `play()` is on screen.
  final GiftEvent<void> onStart = GiftEvent();

  /// A play finished and another begins; `count` = plays completed so far.
  final GiftEvent<int> onLoop = GiftEvent();

  /// The last play finished.
  final GiftEvent<void> onEnd = GiftEvent();

  /// A load or render error (also thrown by the call that caused it). Aborts are not errors.
  final GiftEvent<GiftPlayerError> onError = GiftEvent();

  /// The frame index changed (opt-in: only produced while a listener exists).
  final GiftEvent<int> onFrame = GiftEvent();

  /// Fires when the visible renderer changes (a new gift was loaded or the current one was removed). Views listen to it.
  final ValueNotifier<GiftRenderer?> surface = ValueNotifier<GiftRenderer?>(
    null,
  );

  GiftRenderer? _renderer;
  GiftLease? _lease;
  FrameClock? _clock;
  GiftInfo? _info;
  int _token = 0;
  AbortController? _loadAbort;
  Future<void> _tail = Future.value();
  _Pending? _pending;
  bool _userPaused = false;
  bool _autoPaused = false;
  bool _hidden = false;
  bool _destroyed = false;
  bool _started = false;
  int _lastFrame = -1;
  int _loopsDone = 0;
  double _swapMs = 0;
  bool _clearAtEnd = true;
  ui.Size? _viewPx;

  // ---- loading -----------------------------------------------------------------------------------------------------------

  /// Loads a gift ([src] is a URL / `file://` / `asset:` string, a [GiftSource], `scheme:ref` for a registered resolver, or the
  /// file's bytes) and shows its first frame; call [play] to animate. A second `load()` while one is in flight aborts the first
  /// (which throws `aborted` and never reaches the screen).
  ///
  /// What is on screen meanwhile: a gift that is still PLAYING when `load()` is called keeps playing while the new one downloads, and
  /// is replaced at the moment the new one is ready. A gift that has ENDED is already gone (`clearOnEnd`, default true), so the view is
  /// blank until the new gift is ready; with `clearOnEnd: false` its last frame stays until then.
  Future<GiftInfo> load(
    Object src, {
    LoadOptions options = const LoadOptions(),
  }) async {
    if (_destroyed) throw _aborted('The player is destroyed.');
    final token = ++_token;
    _loadAbort?.abort();
    final ctl = _loadAbort = AbortController();
    final off = options.signal?.onAbort(ctl.abort);
    bool stale() => _token != token || ctl.signal.aborted || _destroyed;
    final wait = _tail;
    final done = Completer<void>();
    _tail = done.future;
    GiftLease? lease;
    try {
      if (stale()) throw _aborted('The load was aborted.');
      lease = await acquireGift(_cache, src, ctl.signal);
      await wait; // another load may still be swapping the content
      if (stale()) throw _aborted('The load was aborted.');

      // From here on the old gift is replaced; everything is synchronous or guarded by stale().
      final swapStart = Stopwatch()..start();
      _teardown(_aborted('A new gift was loaded.'));
      final renderer = await _createRenderer(lease.gift);
      if (stale()) {
        renderer.destroy();
        throw _aborted('The load was aborted.');
      }
      _renderer = renderer;
      _lease = lease;
      lease = null;
      _applyReplacements(renderer, options.replacements);
      await _awaitReplacementImages(renderer, options.replacements);
      if (stale()) {
        _teardown(_aborted('The load was aborted.'));
        throw _aborted('The load was aborted.');
      }
      _clearAtEnd = options.clearOnEnd ?? _options.clearOnEnd;
      final requested = options.loops ?? _options.loops;
      final fileLoops = renderer.loopCount;
      final n = requested ?? fileLoops ?? 1;
      final loops = n <= 0 ? 0 : n;
      _clock = FrameClock(
        frames: renderer.frameCount,
        frameDuration: renderer.frameDuration,
        loops: loops,
        onFrame: _onFrame,
        onEnd: _onEnd,
      );
      _userPaused = false;
      _autoPaused = false;
      renderer.drawFrame(0);
      await renderer.ready(0);
      if (stale()) {
        _teardown(_aborted('The load was aborted.'));
        throw _aborted('The load was aborted.');
      }
      renderer.drawFrame(0);
      surface.value = renderer;
      _swapMs = swapStart.elapsedMicroseconds / 1000;
      final info = _describe(_lease!.gift, renderer);
      _info = info;
      onLoaded.emit(info);
      return info;
    } catch (e) {
      lease?.release();
      final err = _toError(e);
      if (err.code != GiftErrorCode.aborted) onError.emit(err);
      throw err;
    } finally {
      off?.call();
      if (identical(_loadAbort, ctl)) _loadAbort = null;
      done.complete();
    }
  }

  Future<GiftRenderer> _createRenderer(LoadedGift gift) async {
    void onErr(Object e) {
      if (!_destroyed) onError.emit(_toError(e));
    }

    try {
      GiftRenderer r;
      if (gift.movie != null) {
        r = SvgaRenderer(
          gift.movie!,
          gift.images!,
          sharedImages: true,
          contentMode: _mode,
        );
      } else if (gift.info.format == GiftFormat.pag) {
        r = await PagRenderer.create(
          gift.bytes,
          viewPixels: _viewPx,
          contentMode: _mode,
          onError: onErr,
        );
      } else {
        r = await AnimatedImageRenderer.create(
          gift.bytes,
          contentMode: _mode,
          staticDurationMs: _options.staticDurationMs,
          onError: onErr,
        );
      }
      if (_viewPx != null) r.setViewSize(_viewPx!);
      return r;
    } catch (e) {
      throw _toError(e);
    }
  }

  GiftInfo _describe(LoadedGift gift, GiftRenderer r) {
    var total = 0.0;
    for (var i = 0; i < r.frameCount; i++) {
      total += r.frameDuration(i);
    }
    return GiftInfo(
      format: gift.info.format,
      width: r.size.width,
      height: r.size.height,
      frameCount: r.frameCount,
      durationMs: (total * 1000).round() / 1000,
      editableKeys: r.getEditableKeys(),
    );
  }

  void _applyReplacements(GiftRenderer r, Replacements? repl) {
    if (repl == null) return;
    repl.forEach((key, v) {
      switch (v) {
        case TextReplacement():
          _callText(r, key, v.text, v.style);
        case HiddenReplacement():
          r.setHidden(key, v.hidden);
        case ImageReplacement():
          break;
      }
    });
  }

  Future<void> _awaitReplacementImages(
    GiftRenderer r,
    Replacements? repl,
  ) async {
    if (repl == null) return;
    final jobs = <Future<void>>[];
    repl.forEach((key, v) {
      if (v is ImageReplacement) {
        jobs.add(_callImage(r, key, v.image, v.options));
      }
    });
    // A broken replacement image must not take the whole gift down: report it and show the gift without it.
    final results = await Future.wait(
      jobs.map((j) => j.then<Object?>((_) => null, onError: (Object e) => e)),
    );
    for (final res in results) {
      if (res != null) onError.emit(_toError(res));
    }
  }

  // ---- playback ----------------------------------------------------------------------------------------------------------

  /// Plays the loaded gift from the start (or resumes a paused one). Completes when the last play ends; fails with `aborted` when
  /// the gift is stopped, replaced by `load()`, or the player is destroyed, and with the error when playback fails.
  Future<void> play() {
    final clock = _clock;
    if (clock == null || _renderer == null) {
      return Future.error(
        GiftPlayerError(
          GiftErrorCode.invalidInput,
          'Nothing is loaded: await load() first.',
        ),
      );
    }
    if (_pending != null) {
      resume();
      return _pending!.completer.future;
    }
    final p = _pending = _Pending();
    p.completer.future
        .ignore(); // the caller may not be awaiting; the failure is theirs to handle
    _started = false;
    _lastFrame = -1;
    _loopsDone = 0;
    _userPaused = false;
    _autoPaused = false;
    if (_hidden && _options.pauseWhenHidden) {
      _autoPaused = true;
    } else {
      clock.play();
    }
    return p.completer.future;
  }

  /// Pauses on the current frame. [play] or [resume] continues from it.
  void pause() {
    final clock = _clock;
    if (clock == null) return;
    _userPaused = true;
    clock.pause();
  }

  /// Continues after [pause] from the same frame (no catching up).
  void resume() {
    final clock = _clock;
    if (clock == null || _pending == null) return;
    _userPaused = false;
    if (_hidden && _options.pauseWhenHidden) {
      _autoPaused = true;
      return;
    }
    clock.play();
  }

  /// Stops and rewinds to the first frame, which stays on screen. A pending [play] fails with `aborted`.
  void stop() {
    final clock = _clock;
    final r = _renderer;
    if (clock == null || r == null) return;
    clock.stop();
    _userPaused = false;
    _autoPaused = false;
    r.drawFrame(0);
    _settle(_aborted('Playback was stopped.'));
  }

  /// Blanks the view now (the frame on screen is forgotten; a playing gift paints its next frame again). Use it after [stop] or with
  /// `clearOnEnd: false`.
  void clear() => _renderer?.clear();

  /// Shows frame [frame] (clamped); keeps playing if it was playing.
  void seek(int frame) => _clock?.seek(frame);

  /// Milliseconds the view was blank during the last `load()`: from the moment the previous gift was removed until the new gift's
  /// first frame was drawn. (Before that moment the previous gift stays on screen while the new one downloads.)
  double get lastSwapMs => _swapMs;

  /// True while frames are being advanced.
  bool get playing => _clock?.playing ?? false;

  /// What `load()` returned for the current gift, or null.
  GiftInfo? get current => _info;

  /// How the current and later gifts fit the view.
  ContentMode get contentMode => _mode;

  /// Changes how the current and later gifts fit the view.
  void setContentMode(ContentMode mode) {
    _mode = mode;
    _options = _options.copyWith(contentMode: mode);
    _renderer?.contentMode = mode;
  }

  /// The renderer currently shown (used by the view widgets).
  GiftRenderer? get renderer => _renderer;

  /// Called by the view with its size in physical pixels (texture based formats size their surface from it).
  void updateViewSize(ui.Size pixels) {
    if (pixels.isEmpty) return;
    _viewPx = pixels;
    _renderer?.setViewSize(pixels);
  }

  void _onFrame(int f) {
    final r = _renderer;
    if (r == null) return;
    final drawn = r.drawFrame(f);
    if (_lastFrame >= 0 && f < _lastFrame) {
      _loopsDone++;
      onLoop.emit(_loopsDone);
    }
    _lastFrame = f;
    if (!_started) {
      _started = true;
      if (drawn) {
        onStart.emit(null);
      } else {
        r.ready(f).then((_) {
          if (!_destroyed && identical(_renderer, r)) onStart.emit(null);
        });
      }
    }
    if (onFrame.hasListeners) onFrame.emit(f);
  }

  void _onEnd() {
    onEnd.emit(null); // listeners still see the last frame
    if (_clearAtEnd) _renderer?.clear();
    _settle(null);
  }

  void _settle(GiftPlayerError? error) {
    final p = _pending;
    if (p == null) return;
    _pending = null;
    if (error != null) {
      p.completer.completeError(error);
    } else {
      p.completer.complete();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final hidden =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    if (hidden == _hidden) return;
    _hidden = hidden;
    final clock = _clock;
    if (_destroyed || clock == null) return;
    if (hidden) {
      if (clock.playing) {
        clock
            .pause(); // frame and elapsed time are kept: resuming continues from this frame
        _autoPaused = true;
      }
    } else if (_autoPaused) {
      _autoPaused = false;
      if (!_userPaused && _pending != null) clock.play();
    }
  }

  // ---- replacement -------------------------------------------------------------------------------------------------------

  /// Replaces the text of a layer (SVGA sprite key, or PAG text layer name / `#index`). Survives seeking and looping.
  void setText(String key, String text, {GiftTextStyle? style}) {
    final r = _renderer;
    if (r != null) _callText(r, key, text, style);
  }

  /// Replaces a layer's picture ([source]: `ui.Image`, encoded bytes, or a URL / `file://` / `asset:` string). Completes once it is
  /// decoded and on screen.
  Future<void> setImage(
    String key,
    Object source, {
    GiftImageOptions? options,
  }) {
    final r = _renderer;
    return r == null ? Future.value() : _callImage(r, key, source, options);
  }

  void setHidden(String key, bool hidden) => _renderer?.setHidden(key, hidden);

  /// Puts the original text / picture / visibility of [key] back.
  void clearReplacement(String key) => _renderer?.clearReplacement(key);

  /// The layers `setText` / `setImage` / `setHidden` accept for the current gift.
  List<EditableKey> getEditableKeys() =>
      _renderer?.getEditableKeys() ?? const [];

  void _callText(
    GiftRenderer r,
    String key,
    String text,
    GiftTextStyle? style,
  ) {
    if (!r.supportsReplacement) {
      return _warn(
        'this format has no replaceable text (GIF and WebP are plain pictures).',
      );
    }
    r.setText(key, text, style ?? const GiftTextStyle());
  }

  Future<void> _callImage(
    GiftRenderer r,
    String key,
    Object source,
    GiftImageOptions? options,
  ) {
    if (!r.supportsReplacement) {
      _warn(
        'this format has no replaceable images (GIF and WebP are plain pictures).',
      );
      return Future.value();
    }
    return r.setImage(key, source, options ?? const GiftImageOptions());
  }

  // ---- lifecycle ---------------------------------------------------------------------------------------------------------

  /// Takes a hold on a gift in the cache without showing it (the queue uses this to prepare the next gift). Release it when done.
  Future<GiftLease> hold(Object src, [AbortSignal? signal]) =>
      acquireGift(_cache, src, signal);

  /// Stops everything, aborts a load in flight, releases the gift and the view. Safe to call more than once.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _token++;
    _loadAbort?.abort();
    WidgetsBinding.instance.removeObserver(this);
    _teardown(_aborted('The player was destroyed.'));
    for (final e in [onLoaded, onStart, onLoop, onEnd, onError, onFrame]) {
      e.clear();
    }
    surface.value = null;
    surface.dispose();
  }

  void _teardown(GiftPlayerError reason) {
    _clock?.destroy();
    _clock = null;
    _settle(reason);
    _renderer?.destroy();
    _renderer = null;
    if (!_destroyed) surface.value = null;
    _lease?.release();
    _lease = null;
    _info = null;
  }

  // ---- module level ------------------------------------------------------------------------------------------------------

  /// Fetches, parses and decodes gifts into the shared cache so a later `load()` is instant. Never fails: the result says what
  /// happened per source. Gifts handed over as bytes are not cached and are skipped.
  static Future<List<PreloadResult>> preload(
    Object srcs, {
    AssetCache<LoadedGift>? cache,
    AbortSignal? signal,
  }) {
    final c = cache ?? getDefaultCache();
    final list = srcs is List ? srcs.cast<Object>() : [srcs];
    return Future.wait(
      list.map((src) async {
        try {
          final resolved = await resolveSource(src, signal);
          if (resolved.key == null) {
            return PreloadResult(src, PreloadStatus.skipped);
          }
          (await acquireGift(c, src, signal)).release();
          return PreloadResult(src, PreloadStatus.cached);
        } catch (e) {
          return PreloadResult(src, PreloadStatus.failed, _toError(e));
        }
      }),
    );
  }

  /// Teaches `load()` a source scheme, e.g. `GiftPlayer.registerResolver('gift', (id, _) => 'https://cdn.example/$id.svga')` so
  /// `player.load('gift:12345')` works. The resolver returns a URL, or the file's bytes. Returns an unregister function.
  static void Function() registerResolver(
    String scheme,
    SourceResolver resolver,
  ) => asset_lib.registerResolver(scheme, resolver);

  /// The cache players use by default; `getCache().stats` shows bytes, hits and evictions.
  static AssetCache<LoadedGift> getCache() => getDefaultCache();

  /// Sets the budget of the default cache, in estimated decoded bytes (default 64 MB).
  static void setCacheBudget(int maxBytes) =>
      getDefaultCache().setMaxBytes(maxBytes);
}
