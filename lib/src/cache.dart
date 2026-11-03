import 'dart:async';

import 'package:flutter/foundation.dart';

import 'abort.dart';
import 'errors.dart';

/// What a loader hands to the cache.
class CacheLoaded<T> {
  CacheLoaded({
    required this.asset,
    required this.bytes,
    required this.dispose,
  });
  final T asset;

  /// Estimated decoded size in bytes (images: width x height x 4). Counts against the budget.
  final int bytes;

  /// Frees the asset's resources (disposes images). Called exactly once, when the entry is evicted/cleared with no users.
  final void Function() dispose;
}

/// A hold on a cached asset. While any lease is open the asset is never evicted.
abstract class Lease<T> {
  T get asset;

  /// Gives the asset back. Idempotent.
  void release();
}

/// Snapshot of a cache (`cache.stats`).
class CacheStats {
  const CacheStats({
    required this.bytes,
    required this.maxBytes,
    required this.entries,
    required this.inUse,
    required this.hits,
    required this.misses,
    required this.evictions,
    required this.disposed,
    required this.loading,
  });

  /// Estimated decoded bytes held (in use + idle).
  final int bytes;

  /// Budget. In-use assets can push [bytes] above it; they are never evicted.
  final int maxBytes;
  final int entries;

  /// Entries with at least one open lease.
  final int inUse;
  final int hits, misses, evictions;

  /// How many times an asset's `dispose` ran.
  final int disposed;

  /// Loads currently in flight.
  final int loading;

  @override
  String toString() =>
      'CacheStats(bytes: $bytes/$maxBytes, entries: $entries, inUse: $inUse, hits: $hits, misses: $misses, '
      'evictions: $evictions, disposed: $disposed, loading: $loading)';
}

/// Default cache budget: 64 MB of estimated decoded bytes.
const int defaultCacheBytes = 64 * 1024 * 1024;

class _Entry<T> {
  _Entry(this.key, this.controller);
  final String key;
  CacheLoaded<T>? loaded;
  int refs = 0;

  /// Callers still waiting for the load (the load is aborted when the last one gives up).
  int waiters = 0;
  final AbortController controller;
  Future<CacheLoaded<T>>? promise;
  int bytes = 0;
}

GiftPlayerError _aborted() =>
    GiftPlayerError(GiftErrorCode.aborted, 'The operation was aborted.');

/// LRU cache of loaded (parsed and decoded) assets, keyed by resolved source, with a budget in estimated decoded bytes and reference
/// counting: an asset any player holds is never evicted, and two players showing the same gift share one copy. Concurrent requests
/// for a key share one load; the load is aborted only when every requester has aborted.
class AssetCache<T> {
  AssetCache({this._maxBytes = defaultCacheBytes});

  int _maxBytes;
  // Insertion order = recency (oldest first); LinkedHashMap is Dart's default Map.
  final Map<String, _Entry<T>> _entries = {};
  int _hits = 0, _misses = 0, _evictions = 0, _disposed = 0;

  /// Changes the budget and evicts idle assets until it fits.
  void setMaxBytes(int maxBytes) {
    _maxBytes = maxBytes;
    _evict();
  }

  /// Returns a lease on the asset for [key], loading it with [load] when it is not cached (or in flight). [load] receives an
  /// [AbortSignal] that fires when every requester has aborted.
  Future<Lease<T>> acquire(
    String key,
    Future<CacheLoaded<T>> Function(AbortSignal signal) load, {
    AbortSignal? signal,
  }) async {
    if (signal?.aborted ?? false) throw _aborted();
    var entry = _entries[key];
    if (entry?.loaded != null) {
      _hits++;
      _touch(entry!);
      return _lease(entry);
    }
    if (entry == null) {
      _misses++;
      final controller = AbortController();
      final e = _Entry<T>(key, controller);
      e.promise = load(controller.signal).then(
        (loaded) {
          if (controller.signal.aborted) {
            // Everyone gave up while it loaded: do not keep it.
            _disposed++;
            loaded.dispose();
            throw _aborted();
          }
          e.loaded = loaded;
          e.bytes = loaded.bytes;
          return loaded;
        },
        onError: (Object err) {
          if (identical(_entries[key], e)) _entries.remove(key);
          throw err;
        },
      );
      e.promise!.then(
        (_) {},
        onError: (_) {},
      ); // failures are reported to the waiters, never as an unhandled error
      _entries[key] = e;
      entry = e;
    } else {
      _hits++; // joined a load in flight
    }
    final e = entry;
    e.waiters++;
    void Function()? off;
    try {
      final abortFuture = Completer<void>();
      if (signal != null) {
        off = signal.onAbort(() {
          if (!abortFuture.isCompleted) abortFuture.completeError(_aborted());
        });
        abortFuture.future.then((_) {}, onError: (_) {});
      }
      await Future.any<Object?>([
        e.promise!,
        if (signal != null) abortFuture.future,
      ]);
    } catch (err) {
      e.waiters--;
      if (e.waiters == 0 && e.loaded == null) {
        e.controller.abort();
        if (identical(_entries[key], e)) _entries.remove(key);
      }
      rethrow;
    } finally {
      off?.call();
    }
    e.waiters--;
    if (signal?.aborted ?? false) {
      // Aborted at the same moment the load finished: keep the asset cached, hand nothing out.
      _evict();
      throw _aborted();
    }
    _touch(e);
    final lease = _lease(e);
    _evict();
    return lease;
  }

  /// Loads [key] into the cache without keeping a lease (the asset may be evicted later).
  Future<void> preload(
    String key,
    Future<CacheLoaded<T>> Function(AbortSignal signal) load, {
    AbortSignal? signal,
  }) async {
    (await acquire(key, load, signal: signal)).release();
  }

  bool has(String key) => _entries[key]?.loaded != null;

  /// Disposes every idle asset. Assets in use stay until their leases are released (then they are evicted if over budget).
  void clear() {
    for (final e in _entries.values.toList()) {
      if (e.loaded != null && e.refs == 0) _drop(e, false);
    }
  }

  /// Disposes everything idle and aborts loads in flight. Leased assets are disposed when their last lease is released.
  void destroy() {
    _maxBytes = 0;
    for (final e in _entries.values.toList()) {
      if (e.loaded == null) {
        e.controller.abort();
      } else if (e.refs == 0) {
        _drop(e, false);
      }
    }
  }

  CacheStats get stats {
    var bytes = 0, inUse = 0, loading = 0, entries = 0;
    for (final e in _entries.values) {
      if (e.loaded != null) {
        bytes += e.bytes;
        entries++;
      } else {
        loading++;
      }
      if (e.refs > 0) inUse++;
    }
    return CacheStats(
      bytes: bytes,
      maxBytes: _maxBytes,
      entries: entries,
      inUse: inUse,
      hits: _hits,
      misses: _misses,
      evictions: _evictions,
      disposed: _disposed,
      loading: loading,
    );
  }

  Lease<T> _lease(_Entry<T> e) {
    e.refs++;
    return _CacheLease<T>(e.loaded!.asset, () {
      e.refs--;
      if (e.refs == 0) _evict();
    });
  }

  void _touch(_Entry<T> e) {
    _entries.remove(e.key);
    _entries[e.key] = e;
  }

  void _evict() {
    var bytes = 0;
    for (final e in _entries.values) {
      if (e.loaded != null) bytes += e.bytes;
    }
    if (bytes <= _maxBytes) return;
    for (final e in _entries.values.toList()) {
      // oldest first
      if (bytes <= _maxBytes) break;
      if (e.loaded == null || e.refs > 0) continue;
      bytes -= e.bytes;
      _drop(e, true);
    }
  }

  void _drop(_Entry<T> e, bool eviction) {
    _entries.remove(e.key);
    if (eviction) _evictions++;
    _disposed++;
    final loaded = e.loaded!;
    e.loaded = null;
    try {
      loaded.dispose();
    } catch (err) {
      debugPrint('[gift-player] disposing a cached asset failed: $err');
    }
  }
}

class _CacheLease<T> implements Lease<T> {
  _CacheLease(this.asset, this._onRelease);
  @override
  final T asset;
  final void Function() _onRelease;
  bool _open = true;

  @override
  void release() {
    if (!_open) return;
    _open = false;
    _onRelease();
  }
}
