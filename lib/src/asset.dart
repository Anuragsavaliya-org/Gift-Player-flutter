import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'abort.dart';
import 'cache.dart';
import 'detect.dart';
import 'errors.dart';
import 'image/meta.dart';
import 'pag/pag_platform.dart';
import 'source.dart';
import 'svga/decode_images.dart';
import 'svga/parse.dart';
import 'svga/types.dart';

/// A gift file that is fetched, parsed and decoded as far as can be shared between players.
class LoadedGift {
  LoadedGift(this.info, this.bytes, {this.movie, this.images});
  final FormatInfo info;
  final Uint8List bytes;

  /// SVGA only: the parsed movie and its decoded images (shared and read-only; the cache disposes the images).
  final SvgaMovie? movie;
  final Map<String, ui.Image>? images;
}

/// What a resolver may return for a reference like `gift:12345`: a URL `String` to fetch, or the file itself (`Uint8List`).
typedef SourceResolver =
    FutureOr<Object> Function(String ref, AbortSignal? signal);

final Map<String, SourceResolver> _resolvers = {};

/// Registers a resolver for [scheme] (without the colon), e.g. `registerResolver('gift', (id, _) => 'https://cdn.example/$id.svga')` so
/// `player.load('gift:12345')` works. Replaces an earlier resolver for the same scheme. Returns a function that unregisters it.
/// Schemes `http`, `https`, `blob`, `data`, `file` and `asset` are reserved and cannot be registered.
void Function() registerResolver(String scheme, SourceResolver resolver) {
  final s = scheme.toLowerCase().replaceAll(RegExp(r':$'), '');
  if (!RegExp(r'^[a-z][a-z0-9+.-]*$').hasMatch(s) ||
      const ['http', 'https', 'blob', 'data', 'file', 'asset'].contains(s)) {
    throw GiftPlayerError(
      GiftErrorCode.invalidInput,
      'Cannot register a resolver for the scheme "$scheme".',
    );
  }
  _resolvers[s] = resolver;
  return () {
    if (identical(_resolvers[s], resolver)) _resolvers.remove(s);
  };
}

/// A source after resolvers have run: what to read, and the cache key (null = do not cache).
class ResolvedGift {
  ResolvedGift(this.key, this.source);
  final String? key;
  final GiftSource source;
}

final Expando<int> _byteIds = Expando<int>('gift-bytes');
int _nextByteId = 1;

/// Stable identity string for a source (used by the queue to compare items).
String sourceIdentity(Object src) {
  // A `scheme:ref` for a registered resolver is its own identity.
  final GiftSource s;
  try {
    s = GiftSource.from(src);
  } on GiftPlayerError {
    if (src is String) return src;
    rethrow;
  }
  return switch (s) {
    GiftUrlSource() => s.url,
    GiftFileSource() => 'file:${s.path}',
    GiftAssetSource() => 'asset:${s.name}',
    GiftBytesSource() => '#bytes:${_byteIds[s.bytes] ??= _nextByteId++}',
  };
}

final RegExp _scheme = RegExp(
  r'^([a-z][a-z0-9+.-]*):(.*)$',
  caseSensitive: false,
  dotAll: true,
);

/// Runs the resolver for [src] (if its scheme is registered) and works out the cache key.
Future<ResolvedGift> resolveSource(Object src, [AbortSignal? signal]) async {
  if (src is String) {
    final m = _scheme.firstMatch(src);
    final resolver = m == null ? null : _resolvers[m.group(1)!.toLowerCase()];
    if (resolver != null && m != null) {
      final Object out;
      try {
        // Race the resolver against the abort signal, so a cancelled load never waits for a resolver that ignores the signal.
        final pending = Future<Object>.value(
          resolver(m.group(2) ?? '', signal),
        );
        if (signal == null) {
          out = await pending;
        } else {
          final aborted = Completer<Never>();
          final off = signal.onAbort(
            () => aborted.completeError(
              GiftPlayerError(GiftErrorCode.aborted, 'The load was aborted.'),
            ),
          );
          aborted.future.ignore();
          pending.ignore();
          try {
            out = await Future.any<Object>([pending, aborted.future]);
          } finally {
            off();
          }
        }
      } catch (cause) {
        if (signal?.aborted ?? false) {
          throw GiftPlayerError(
            GiftErrorCode.aborted,
            'The load was aborted.',
            cause: cause,
          );
        }
        if (cause is GiftPlayerError) rethrow;
        throw GiftPlayerError(
          GiftErrorCode.network,
          'The "${m.group(1)}" resolver failed for "$src".',
          cause: cause,
        );
      }
      if (out is String) {
        final s = GiftSource.from(out);
        return ResolvedGift(sourceIdentity(s), s);
      }
      return ResolvedGift(src, GiftSource.from(out));
    }
  }
  final s = GiftSource.from(src);
  if (s is GiftBytesSource) {
    return ResolvedGift(null, s); // files handed over directly are not cached
  }
  return ResolvedGift(sourceIdentity(s), s);
}

// ---- loading --------------------------------------------------------------------------------------------------------------

/// Isolate entry: detect + parse. Errors travel as values because exceptions with arbitrary causes are not sendable.
typedef _ParseResult = ({
  FormatInfo? info,
  SvgaMovie? movie,
  String? code,
  String? message,
});

_ParseResult _detectAndParse(Uint8List bytes) {
  try {
    final d = detectInternal(bytes);
    if (d.info.format == GiftFormat.svga) {
      return (
        info: d.info,
        movie: parseSvga(bytes, inflated: d.inflated),
        code: null,
        message: null,
      );
    }
    return (info: d.info, movie: null, code: null, message: null);
  } on GiftPlayerError catch (e) {
    return (info: null, movie: null, code: e.code.id, message: e.message);
  } catch (e) {
    return (
      info: null,
      movie: null,
      code: GiftErrorCode.parseFailed.id,
      message: '$e',
    );
  }
}

/// Files bigger than this are detected and parsed in a background isolate so the UI thread keeps drawing.
const int isolateThresholdBytes = 64 * 1024;

Future<_ParseResult> _parseOffThread(Uint8List bytes) async {
  if (bytes.length < isolateThresholdBytes || kIsWeb) {
    return _detectAndParse(bytes);
  }
  try {
    return await Isolate.run(() => _detectAndParse(bytes));
  } catch (_) {
    return _detectAndParse(bytes); // isolates unavailable: do it here
  }
}

int _imageBytes(ui.Image b) => b.width * b.height * 4;

/// Fetches, detects, parses and decodes (SVGA images) one gift. Used as the cache loader.
Future<CacheLoaded<LoadedGift>> loadGift(
  GiftSource source,
  AbortSignal signal,
) async {
  final bytes = await readSource(source, signal: signal);
  signal.throwIfAborted();
  final r = await _parseOffThread(bytes);
  if (r.info == null) {
    final code = GiftErrorCode.values.firstWhere(
      (c) => c.id == r.code,
      orElse: () => GiftErrorCode.parseFailed,
    );
    throw GiftPlayerError(code, r.message ?? 'Unsupported or corrupt file.');
  }
  final info = r.info!;
  signal.throwIfAborted();
  switch (info.format) {
    case GiftFormat.svga:
      final movie = r.movie!;
      final dec = await decodeSvgaImages(movie);
      if (signal.aborted) {
        releaseSvgaImages(dec.bitmaps);
        throw GiftPlayerError(GiftErrorCode.aborted, 'The load was aborted.');
      }
      if (dec.failed.isNotEmpty && dec.bitmaps.isEmpty) {
        throw GiftPlayerError(
          GiftErrorCode.decodeFailed,
          'None of the ${dec.failed.length} images in this SVGA could be decoded.',
        );
      }
      if (dec.failed.isNotEmpty) {
        debugPrint(
          '[gift-player] ${dec.failed.length} image(s) of this SVGA could not be decoded and are skipped: ${dec.failed.join(', ')}',
        );
      }
      var size = 0;
      for (final b in dec.bitmaps.values) {
        size += _imageBytes(b);
      }
      for (final img in movie.images.values) {
        size +=
            img.data.lengthInBytes; // the parsed movie keeps the encoded copies
      }
      return CacheLoaded(
        asset: LoadedGift(
          info,
          Uint8List(0),
          movie: movie,
          images: dec.bitmaps,
        ),
        bytes: size,
        dispose: () => releaseSvgaImages(dec.bitmaps),
      );
    case GiftFormat.gif:
    case GiftFormat.webp:
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
      // One decoded frame is the working set; the encoded bytes are kept.
      final size =
          bytes.lengthInBytes +
          (meta.width < 1 ? 1 : meta.width) *
              (meta.height < 1 ? 1 : meta.height) *
              4;
      return CacheLoaded(
        asset: LoadedGift(info, bytes),
        bytes: size,
        dispose: () {},
      );
    case GiftFormat.pag:
      // The decoded layers live inside the native engine per player; here we keep the file and warm the engine, so the first frame of
      // a queued gift does not wait for the native library to load.
      await PagPlatform.ensureEngine();
      signal.throwIfAborted();
      return CacheLoaded(
        asset: LoadedGift(info, bytes),
        bytes: bytes.lengthInBytes * 4,
        dispose: () {},
      );
  }
}

/// A hold on a loaded gift. Release it when done; a cached gift then becomes evictable again.
abstract class GiftLease {
  LoadedGift get gift;
  void release();
}

class _SimpleLease implements GiftLease {
  _SimpleLease(this.gift, this._onRelease);
  @override
  final LoadedGift gift;
  final void Function() _onRelease;
  bool _open = true;
  @override
  void release() {
    if (!_open) return;
    _open = false;
    _onRelease();
  }
}

/// The cache type used for gifts.
typedef GiftCache = AssetCache<LoadedGift>;

/// Resolves [src] and returns a lease on the loaded gift: from the cache when it is a cacheable source (URL / file / asset / resolved
/// reference), otherwise loaded privately and disposed on release.
Future<GiftLease> acquireGift(
  GiftCache cache,
  Object src, [
  AbortSignal? signal,
]) async {
  final resolved = await resolveSource(src, signal);
  if (resolved.key != null) {
    final lease = await cache.acquire(
      resolved.key!,
      (s) => loadGift(resolved.source, s),
      signal: signal,
    );
    return _SimpleLease(lease.asset, lease.release);
  }
  final ctl = AbortController();
  final off = signal?.onAbort(ctl.abort);
  try {
    final loaded = await loadGift(resolved.source, ctl.signal);
    if (signal?.aborted ?? false) {
      loaded.dispose();
      throw GiftPlayerError(GiftErrorCode.aborted, 'The load was aborted.');
    }
    return _SimpleLease(loaded.asset, loaded.dispose);
  } finally {
    off?.call();
  }
}
