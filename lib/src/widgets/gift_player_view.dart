import 'dart:async';

import 'package:flutter/widgets.dart';

import '../abort.dart';
import '../asset.dart';
import '../errors.dart';
import '../player.dart';
import '../queue.dart';
import '../replacement.dart';
import '../viewport.dart';
import 'gift_surface.dart';

bool _sameStyle(GiftTextStyle? a, GiftTextStyle? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.font == b.font &&
      a.size == b.size &&
      a.weight == b.weight &&
      a.color == b.color &&
      a.align == b.align &&
      a.stroke?.color == b.stroke?.color &&
      a.stroke?.width == b.stroke?.width;
}

/// True when two replacements would show the same thing (images are compared by identity).
bool sameReplacement(Replacement a, Replacement b) {
  switch (a) {
    case TextReplacement():
      return b is TextReplacement &&
          a.text == b.text &&
          _sameStyle(a.style, b.style);
    case ImageReplacement():
      return b is ImageReplacement &&
          (identical(a.image, b.image) || a.image == b.image) &&
          a.options?.fit == b.options?.fit;
    case HiddenReplacement():
      return b is HiddenReplacement && a.hidden == b.hidden;
  }
}

/// What has to be applied to go from [prev] to [next]: the keys whose replacement is new or different, and the keys that went away.
({List<MapEntry<String, Replacement>> changed, List<String> cleared})
diffReplacements(Replacements? prev, Replacements? next) {
  final changed = <MapEntry<String, Replacement>>[];
  final cleared = <String>[];
  next?.forEach((key, r) {
    final before = prev?[key];
    if (before == null || !sameReplacement(before, r)) {
      changed.add(MapEntry(key, r));
    }
  });
  prev?.forEach((key, _) {
    if (next == null || !next.containsKey(key)) cleared.add(key);
  });
  return (changed: changed, cleared: cleared);
}

/// Plays one gift in the box it is given. Disposing the widget destroys the player, changing [src] reloads (aborting the load in
/// flight), changing [replacements] updates in place, and changing [contentMode] re-fits without a reload.
///
/// ```dart
/// SizedBox(width: 360, height: 360, child: GiftPlayerView(src: 'https://cdn.example/rocket.svga', replacements: {'name': Replacement.text('Rahul')}))
/// ```
class GiftPlayerView extends StatefulWidget {
  const GiftPlayerView({
    super.key,
    required this.src,
    this.replacements,
    this.loops,
    this.contentMode = ContentMode.aspectFit,
    this.autoPlay = true,
    this.clearOnEnd = true,
    this.onLoad,
    this.onEnd,
    this.onError,
    this.playerOptions = const GiftPlayerOptions(),
  });

  /// What to play: a URL / `file://` / `asset:` string, a registered `scheme:ref`, or the file's bytes. Changing it loads the new gift.
  final Object src;

  /// Text / image / visibility replacements by key. Changing them updates the gift in place, without a reload.
  final Replacements? replacements;

  /// Number of plays (0 = forever). Changing it reloads.
  final int? loops;

  /// How the gift fits the box. Changing it re-fits, without a reload. Default aspectFit.
  final ContentMode contentMode;

  /// Start playing as soon as the gift is loaded. Default true.
  final bool autoPlay;

  /// Clear the view after the last play. Default true. Changing it reloads.
  final bool clearOnEnd;

  /// Called when the gift is loaded and its first frame is on screen.
  final void Function(GiftInfo info)? onLoad;

  /// Called when the last play ended.
  final VoidCallback? onEnd;

  /// Called with load and render errors (aborts are not errors).
  final void Function(GiftPlayerError error)? onError;

  /// Other player options (cache, static duration, ...). Read once when the view is created.
  final GiftPlayerOptions playerOptions;

  @override
  State<GiftPlayerView> createState() => _GiftPlayerViewState();
}

class _GiftPlayerViewState extends State<GiftPlayerView> {
  late final GiftPlayer _player;
  void Function()? _offError;
  AbortController? _loadCtl;
  Replacements? _applied;
  bool _ready = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _player = GiftPlayer(
      widget.playerOptions.copyWith(
        contentMode: widget.contentMode,
        clearOnEnd: widget.clearOnEnd,
      ),
    );
    _offError = _player.onError.listen((e) => widget.onError?.call(e));
    _start();
  }

  void _start() {
    _loadCtl?.abort();
    final ctl = _loadCtl = AbortController();
    final gen = ++_generation;
    _ready = false;
    final given = widget.replacements;
    _applied = given;
    _player
        .load(
          widget.src,
          options: LoadOptions(
            replacements: given,
            loops: widget.loops,
            clearOnEnd: widget.clearOnEnd,
            signal: ctl.signal,
          ),
        )
        .then((info) {
          if (gen != _generation) return null;
          _ready = true;
          _sync(widget.replacements); // changed while it was loading
          widget.onLoad?.call(info);
          if (!widget.autoPlay) return null;
          return _player.play().then((_) {
            if (gen == _generation) widget.onEnd?.call();
          });
        })
        .catchError((Object e) {
          if (gen != _generation) return;
          if (e is GiftPlayerError && e.code == GiftErrorCode.aborted) return;
          // load() already reported load errors through onError; playback failures other than abort are reported here.
        });
  }

  void _sync(Replacements? next) {
    final d = diffReplacements(_applied, next);
    for (final key in d.cleared) {
      _player.clearReplacement(key);
    }
    for (final e in d.changed) {
      final r = e.value;
      switch (r) {
        case TextReplacement():
          _player.setText(e.key, r.text, style: r.style);
        case ImageReplacement():
          unawaited(
            _player
                .setImage(e.key, r.image, options: r.options)
                .catchError((Object _) {}),
          );
        case HiddenReplacement():
          _player.setHidden(e.key, r.hidden);
      }
    }
    _applied = next;
  }

  @override
  void didUpdateWidget(GiftPlayerView old) {
    super.didUpdateWidget(old);
    if (sourceIdentity(old.src) != sourceIdentity(widget.src) ||
        old.loops != widget.loops ||
        old.clearOnEnd != widget.clearOnEnd) {
      _start();
    } else if (_ready && !identical(old.replacements, widget.replacements)) {
      _sync(widget.replacements);
    }
    if (old.contentMode != widget.contentMode) {
      _player.setContentMode(widget.contentMode);
    }
  }

  @override
  void dispose() {
    _generation++;
    _loadCtl?.abort();
    _offError?.call();
    _player.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GiftPlayerSurface(player: _player);
}

/// Live numbers of a queue, updated on every change.
class GiftQueueState {
  const GiftQueueState({
    this.pending = 0,
    this.playing = false,
    this.paused = false,
    this.played = 0,
    this.failed = 0,
    this.cancelled = 0,
    this.dropped = 0,
  });

  /// Gifts waiting.
  final int pending;
  final bool playing;
  final bool paused;
  final int played, failed, cancelled, dropped;
}

/// Creates a [GiftPlayer] and a [GiftQueue] on it, and exposes live [stats]. Create it in `initState`, show it with
/// `GiftPlayerSurface(player: controller.player)`, call `controller.queue.add(...)` from event handlers, and `dispose()` it.
class GiftQueueController {
  GiftQueueController({
    GiftPlayerOptions playerOptions = const GiftPlayerOptions(),
    GiftQueueOptions queueOptions = const GiftQueueOptions(),
  }) : player = GiftPlayer(playerOptions) {
    queue = GiftQueue(player, queueOptions);
    GiftQueueState snapshot() => GiftQueueState(
      pending: queue.length,
      playing: queue.isPlaying,
      paused: _paused,
      played: queue.stats.played,
      failed: queue.stats.failed,
      cancelled: queue.stats.cancelled,
      dropped: queue.stats.dropped,
    );
    _offs = [
      queue.onChange.listen((c) {
        _paused = c.paused;
        stats.value = snapshot();
      }),
      queue.onItemEnd.listen((_) => stats.value = snapshot()),
    ];
  }

  final GiftPlayer player;
  late final GiftQueue queue;

  /// Live numbers; rebuild with `ValueListenableBuilder`.
  final ValueNotifier<GiftQueueState> stats = ValueNotifier(
    const GiftQueueState(),
  );
  bool _paused = false;
  late final List<void Function()> _offs;

  void dispose() {
    for (final off in _offs) {
      off();
    }
    queue.destroy();
    player.destroy();
    stats.dispose();
  }
}
