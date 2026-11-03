import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'abort.dart';
import 'asset.dart';
import 'emitter.dart';
import 'errors.dart';
import 'player.dart';
import 'replacement.dart';
import 'source.dart';

/// Options for `GiftQueue(player, options)`.
class GiftQueueOptions {
  const GiftQueueOptions({
    this.maxLength,
    this.preloadAhead = 2,
    this.coalesce = false,
    this.defaultLoops = 1,
  });

  /// Most items waiting at once (the one playing does not count). Default: unlimited.
  final int? maxLength;

  /// How many of the next items to fetch, parse and decode while the current one plays. Default 2.
  final int preloadAhead;

  /// Merge identical consecutive waiting items into one with a `count`. Default false.
  final bool coalesce;

  /// Plays per gift when the item does not say. Default 1: a GIF/WebP that loops forever would otherwise hold the queue for good.
  /// Pass `loops: 0` on an item to loop it forever on purpose.
  final int defaultLoops;
}

/// Where an item is in its life: waiting, playing, or one of the final states.
enum QueueItemStatus { pending, playing, done, failed, cancelled, dropped }

/// Why an item left the queue without playing: the queue was full, it was cancelled, or the queue was cleared.
enum DropReason { overflow, cancelled, cleared }

/// Describes an item in events.
class QueueItemInfo {
  const QueueItemInfo({
    required this.id,
    required this.src,
    required this.priority,
    required this.count,
  });
  final int id;
  final Object src;
  final int priority;

  /// Number of merged adds (the "x10" of a combo).
  final int count;
}

class QueueItemEnd {
  const QueueItemEnd(this.item, this.status);
  final QueueItemInfo item;
  final QueueItemStatus status;
}

class QueueItemError {
  const QueueItemError(this.item, this.error);
  final QueueItemInfo item;
  final GiftPlayerError error;
}

class QueueItemDropped {
  const QueueItemDropped(this.item, this.reason);
  final QueueItemInfo item;
  final DropReason reason;
}

/// Payload of the `change` event: anything changed (waiting count, playing, paused).
class QueueChange {
  const QueueChange({
    required this.pending,
    required this.playing,
    required this.paused,
  });
  final int pending;
  final bool playing;
  final bool paused;
}

/// Running totals and transition timings of a queue (`queue.stats`).
class QueueStats {
  int played = 0;
  int failed = 0;
  int cancelled = 0;
  int dropped = 0;

  /// Time from one gift ending to the next gift's first frame being on screen, for gifts that were already waiting.
  final List<double> gapsMs = [];

  /// Time the view was blank between two gifts (previous removed, next first frame drawn) for the same transitions.
  final List<double> blankMs = [];
}

/// Returned by `add()`.
abstract class QueueHandle {
  int get id;
  QueueItemStatus get status;

  /// How many `add()` calls were merged into the item this handle belongs to (1 unless `coalesce`).
  int get count;

  /// Removes this gift from the queue, or stops it if it is playing. No effect once it is finished.
  void cancel();

  /// Completes with the final status; never fails.
  Future<QueueItemStatus> get done;
}

class _Item {
  _Item({
    required this.id,
    required this.src,
    required this.priority,
    required this.seq,
    required this.replacements,
    required this.loops,
    required this.signature,
  });
  final int id;
  final Object src;
  final int priority;
  final int seq;
  final Replacements? replacements;
  final int? loops;
  final String signature;
  final List<_Handle> handles = [];
  QueueItemStatus status = QueueItemStatus.pending;
  GiftLease? hold;
  Future<void>? holding;
  AbortController? holdAbort;
  GiftPlayerError? preloadError;
  AbortController? abort;
}

class _Handle implements QueueHandle {
  _Handle(this.id, this._queue, this.item);
  @override
  final int id;
  final GiftQueue _queue;
  _Item item;
  QueueItemStatus _status = QueueItemStatus.pending;
  final Completer<QueueItemStatus> _done = Completer<QueueItemStatus>();

  @override
  QueueItemStatus get status => _status;
  set status(QueueItemStatus s) => _status = s;

  @override
  int get count => item.handles.length;

  @override
  void cancel() => _queue._cancelHandle(this);

  @override
  Future<QueueItemStatus> get done => _done.future;

  void finish(QueueItemStatus s) {
    if (_status == QueueItemStatus.done ||
        _status == QueueItemStatus.failed ||
        _status == QueueItemStatus.cancelled ||
        _status == QueueItemStatus.dropped) {
      return;
    }
    _status = s;
    _done.complete(s);
  }
}

bool _isAborted(Object e) =>
    e is GiftPlayerError && e.code == GiftErrorCode.aborted;

String _replacementsSignature(Replacements? r) {
  if (r == null) return '';
  final b = StringBuffer();
  r.forEach((key, v) {
    b.write('$key=');
    switch (v) {
      case TextReplacement():
        final s = v.style;
        b.write(
          't:${v.text}|${s?.font}|${s?.size}|${s?.weight}|${s?.color?.toARGB32()}|${s?.align}|${s?.stroke?.color.toARGB32()}|${s?.stroke?.width}',
        );
      case ImageReplacement():
        final img = v.image;
        final id = img is String
            ? img
            : (img is Uint8List
                  ? sourceIdentity(img)
                  : (img is ui.Image
                        ? '#img:${identityHashCode(img)}'
                        : '$img'));
        b.write('i:$id|${v.options?.fit}');
      case HiddenReplacement():
        b.write('h:${v.hidden}');
    }
    b.write(';');
  });
  return b.toString();
}

/// Plays gifts one at a time on a [GiftPlayer]: priorities, a length limit, preloading of the next gifts, optional merging of
/// repeats, and a queue that never stalls (a gift that fails is reported and skipped).
///
/// ```dart
/// final queue = GiftQueue(player, const GiftQueueOptions(maxLength: 50, preloadAhead: 2, coalesce: true));
/// queue.onItemStart.listen((i) => showBadge(i.count));
/// queue.add('https://cdn.example/rocket.svga', priority: 5, replacements: {'name': Replacement.text('Rahul')});
/// ```
class GiftQueue {
  GiftQueue(this.player, [GiftQueueOptions options = const GiftQueueOptions()])
    : _maxLength = options.maxLength ?? 1 << 62,
      _preloadAhead = options.preloadAhead,
      _coalesce = options.coalesce,
      _defaultLoops = options.defaultLoops {
    _unsubscribe = player.onStart.listen((_) => _onFirstFrame());
  }

  final GiftPlayer player;
  final int _maxLength;
  final int _preloadAhead;
  final bool _coalesce;
  final int _defaultLoops;

  final GiftEvent<QueueItemInfo> onItemBegin = GiftEvent();
  final GiftEvent<QueueItemInfo> onItemStart = GiftEvent();
  final GiftEvent<QueueItemEnd> onItemEnd = GiftEvent();
  final GiftEvent<QueueItemError> onItemError = GiftEvent();
  final GiftEvent<QueueItemDropped> onItemDropped = GiftEvent();
  final GiftEvent<QueueChange> onChange = GiftEvent();
  final GiftEvent<void> onIdle = GiftEvent();

  final List<_Item> _waiting = []; // kept in play order
  _Item? _current;
  bool _running = false;
  bool _kicked = false;
  bool _paused = false;
  bool _destroyed = false;
  int _nextId = 1;
  int _seq = 0;
  final Stopwatch _clock = Stopwatch()..start();
  double? _lastEndAt;

  /// True once something was processed since the last `idle`.
  bool _sinceIdle = false;
  late final void Function() _unsubscribe;
  final QueueStats stats = QueueStats();

  // ---- adding ------------------------------------------------------------------------------------------------------------

  /// Queues a gift. Returns a handle to cancel it or to wait for its outcome.
  QueueHandle add(
    Object src, {
    int priority = 0,
    Replacements? replacements,
    int? loops,
  }) {
    final signature =
        '${sourceIdentity(src)}|$priority|${loops ?? ''}|${_replacementsSignature(replacements)}';
    final handleId = _nextId++;
    final placeholder = _Item(
      id: handleId,
      src: src,
      priority: priority,
      seq: -1,
      replacements: replacements,
      loops: loops,
      signature: signature,
    );
    final handle = _Handle(handleId, this, placeholder);
    if (_destroyed) {
      handle.finish(QueueItemStatus.dropped);
      return handle;
    }
    // Where the new item would go: after every waiting item of equal or higher priority.
    var at = _waiting.length;
    while (at > 0 && _waiting[at - 1].priority < priority) {
      at--;
    }
    final before = at > 0 ? _waiting[at - 1] : null;
    if (_coalesce && before != null && before.signature == signature) {
      handle.item = before;
      before.handles.add(handle);
      _emitChange();
      return handle;
    }
    final item = _Item(
      id: handleId,
      src: src,
      priority: priority,
      seq: _seq++,
      replacements: replacements,
      loops: loops,
      signature: signature,
    );
    item.handles.add(handle);
    handle.item = item;
    if (_waiting.length >= _maxLength) {
      // Full: the lowest priority goes, the oldest first. The new item is the newest, so it only goes when it is the lowest.
      _Item? victim;
      for (final w in _waiting) {
        if (victim == null ||
            w.priority < victim.priority ||
            (w.priority == victim.priority && w.seq < victim.seq)) {
          victim = w;
        }
      }
      if (victim == null || priority <= victim.priority) {
        _finishItem(item, QueueItemStatus.dropped, DropReason.overflow);
        return handle;
      }
      _waiting.remove(victim);
      _finishItem(victim, QueueItemStatus.dropped, DropReason.overflow);
      at = _waiting.length;
      while (at > 0 && _waiting[at - 1].priority < priority) {
        at--;
      }
    }
    _waiting.insert(at, item);
    _emitChange();
    _updatePreloads();
    _kick();
    return handle;
  }

  // ---- control -----------------------------------------------------------------------------------------------------------

  /// Stops starting new gifts and pauses the current one.
  void pause() {
    if (_paused) return;
    _paused = true;
    if (_current != null) player.pause();
    _emitChange();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_current != null && player.current != null) player.resume();
    _emitChange();
    _kick();
  }

  /// Removes every waiting gift (the current one keeps playing; use [skip] to stop it too).
  void clear() {
    final all = List<_Item>.of(_waiting);
    _waiting.clear();
    for (final item in all) {
      _finishItem(item, QueueItemStatus.dropped, DropReason.cleared);
    }
    _emitChange();
  }

  /// Stops the current gift and moves on to the next.
  void skip() {
    final item = _current;
    if (item == null) return;
    item.abort?.abort();
    player.stop();
  }

  /// Detaches from the player (which is not destroyed): drops all waiting gifts, stops the current one, releases preloads.
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _unsubscribe();
    clear();
    skip();
    for (final e in <GiftEvent<Object?>>[
      onItemBegin,
      onItemStart,
      onItemEnd,
      onItemError,
      onItemDropped,
      onChange,
      onIdle,
    ]) {
      e.clear();
    }
  }

  /// Gifts waiting (the one playing does not count).
  int get length => _waiting.length;

  bool get isPlaying => _current != null;

  // ---- internals ---------------------------------------------------------------------------------------------------------

  QueueItemInfo _info(_Item item) => QueueItemInfo(
    id: item.id,
    src: item.src,
    priority: item.priority,
    count: item.handles.length,
  );

  void _emitChange() => onChange.emit(
    QueueChange(
      pending: _waiting.length,
      playing: _current != null,
      paused: _paused,
    ),
  );

  void _cancelHandle(_Handle handle) {
    final item = handle.item;
    if (handle.status != QueueItemStatus.pending &&
        handle.status != QueueItemStatus.playing) {
      return;
    }
    if (item.handles.length > 1) {
      item.handles.remove(handle);
      handle.finish(QueueItemStatus.cancelled);
      stats.cancelled++;
      _emitChange();
      return;
    }
    if (identical(item, _current)) {
      item.abort?.abort();
      player.stop();
      return; // _process() reports the status
    }
    _waiting.remove(item);
    _finishItem(item, QueueItemStatus.cancelled, DropReason.cancelled);
    _emitChange();
  }

  /// Marks an item that never played as finished, releases its preload, and tells listeners.
  void _finishItem(_Item item, QueueItemStatus status, DropReason reason) {
    item.status = status;
    _releaseHold(item);
    final info = _info(item);
    for (final h in item.handles) {
      h.finish(status);
    }
    if (status == QueueItemStatus.dropped) {
      stats.dropped += 1;
    } else {
      stats.cancelled += 1;
    }
    onItemDropped.emit(QueueItemDropped(info, reason));
    _updatePreloads();
  }

  void _releaseHold(_Item item) {
    item.holdAbort?.abort();
    item.holdAbort = null;
    item.hold?.release();
    item.hold = null;
    item.holding = null;
  }

  /// Keeps exactly the next `preloadAhead` waiting gifts fetched, parsed and decoded (and released when they leave that window).
  void _updatePreloads() {
    if (_destroyed) return;
    final wanted = _waiting.take(_preloadAhead).toSet();
    for (final item in List<_Item>.of(_waiting)) {
      if (!wanted.contains(item)) {
        if (item.hold != null || item.holding != null) _releaseHold(item);
        continue;
      }
      if (item.hold != null ||
          item.holding != null ||
          item.preloadError != null) {
        continue;
      }
      if (item.src is! String && GiftSource.from(item.src) is GiftBytesSource) {
        continue; // direct files are not cached; they are decoded when their turn comes
      }
      final ctl = item.holdAbort = AbortController();
      item.holding = player
          .hold(item.src, ctl.signal)
          .then(
            (lease) {
              if (!identical(item.holdAbort, ctl) ||
                  item.status != QueueItemStatus.pending) {
                lease.release();
              } else {
                item.hold = lease;
              }
            },
            onError: (Object e) {
              if (!_isAborted(e) && identical(item.holdAbort, ctl)) {
                item.preloadError = e is GiftPlayerError
                    ? e
                    : GiftPlayerError(
                        GiftErrorCode.decodeFailed,
                        '$e',
                        cause: e,
                      );
              }
            },
          );
    }
  }

  /// Starts the loop after the current synchronous block, so a burst of `add()` calls is ordered by priority before the first gift
  /// starts.
  void _kick() {
    if (_kicked || _running) return;
    _kicked = true;
    scheduleMicrotask(() {
      _kicked = false;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    if (_running || _destroyed) return;
    _running = true;
    try {
      while (!_paused && !_destroyed && _waiting.isNotEmpty) {
        final item = _waiting.removeAt(0);
        _sinceIdle = true;
        await _process(item);
      }
    } finally {
      _running = false;
    }
    if (_sinceIdle &&
        !_paused &&
        _current == null &&
        _waiting.isEmpty &&
        !_destroyed) {
      _sinceIdle = false;
      _emitChange();
      onIdle.emit(null);
    }
  }

  Future<void> _process(_Item item) async {
    item.status = QueueItemStatus.playing;
    for (final h in item.handles) {
      h.status = QueueItemStatus.playing;
    }
    _current = item;
    _updatePreloads();
    _emitChange();
    onItemBegin.emit(_info(item));
    final ctl = item.abort = AbortController();
    final gapStart = _lastEndAt;
    var outcome = QueueItemStatus.done;
    GiftPlayerError? error;
    try {
      if (item.preloadError != null) throw item.preloadError!;
      await player.load(
        item.src,
        options: LoadOptions(
          replacements: item.replacements,
          loops: item.loops ?? _defaultLoops,
          clearOnEnd: false,
          signal: ctl.signal,
        ),
      );
      _releaseHold(item); // the player now holds the gift itself
      if (gapStart != null && item.status == QueueItemStatus.playing) {
        stats.gapsMs.add(_clock.elapsedMicroseconds / 1000 - gapStart);
        stats.blankMs.add(player.lastSwapMs);
      }
      final playing = player.play();
      if (_paused) player.pause();
      await playing;
    } catch (e) {
      if (_isAborted(e)) {
        outcome = QueueItemStatus.cancelled;
      } else {
        outcome = QueueItemStatus.failed;
        error = e is GiftPlayerError
            ? e
            : GiftPlayerError(GiftErrorCode.decodeFailed, '$e', cause: e);
      }
    }
    _releaseHold(item);
    item.status = outcome;
    switch (outcome) {
      case QueueItemStatus.done:
        stats.played++;
      case QueueItemStatus.failed:
        stats.failed++;
      default:
        stats.cancelled++;
    }
    final info = _info(item);
    for (final h in item.handles) {
      h.finish(outcome);
    }
    _current = null;
    // Hand-over: when the next gift is already prepared (held in the cache) its load swaps the view within a few ms, so the last
    // frame stays until then. Otherwise (nothing waiting, or the next one still downloading, or this one failed) the view goes blank.
    final next = _waiting.isEmpty ? null : _waiting.first;
    if (!(outcome == QueueItemStatus.done &&
        next != null &&
        next.hold != null &&
        !_paused)) {
      player.clear();
    }
    _lastEndAt = outcome == QueueItemStatus.done && _waiting.isNotEmpty
        ? _clock.elapsedMicroseconds / 1000
        : null;
    if (error != null) onItemError.emit(QueueItemError(info, error));
    onItemEnd.emit(QueueItemEnd(info, outcome));
    _updatePreloads();
    _emitChange();
  }

  void _onFirstFrame() {
    final item = _current;
    if (item != null && item.status == QueueItemStatus.playing) {
      onItemStart.emit(_info(item));
    }
  }
}
