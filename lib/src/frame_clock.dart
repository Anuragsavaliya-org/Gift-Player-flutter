import 'dart:typed_data';

import 'package:flutter/scheduler.dart';

/// Frame clock: driven by the display's frame callbacks. Frames have individual durations (GIF/WebP delays) or one uniform duration
/// (SVGA/PAG fps); the frame on screen is derived from elapsed time via cumulative start times (prefix sums), so it SKIPS frames when
/// the app falls behind instead of replaying them (the animation's total duration stays correct). `onFrame` only fires when the frame
/// index changes.
class FrameClock {
  FrameClock({
    required this.frames,
    double Function(int i)? frameDuration,
    double fps = 30,
    int loops = 1,
    required this.onFrame,
    this.onEnd,
    int Function(void Function(Duration now) cb)? raf,
    void Function(int handle)? caf,
    double Function()? now,
  }) : _loops = loops <= 0 ? double.infinity : loops.toDouble(),
       _raf = raf ?? _defaultRaf,
       _caf = caf ?? _defaultCaf,
       // ignore: prefer_initializing_formals
       _now = now,
       _starts = Float64List(frames + 1) {
    if (frameDuration != null) {
      for (var i = 0; i < frames; i++) {
        final d = frameDuration(i);
        _starts[i + 1] = _starts[i] + (d > _eps * 10 ? d : _eps * 10);
      }
    } else {
      // Multiplication, not repeated addition, so uniform boundaries have no accumulated error.
      final per = 1000 / fps;
      for (var i = 0; i <= frames; i++) {
        _starts[i] = i * per;
      }
    }
    _cycle = _starts[frames];
  }

  /// Floating-point slack so a time exactly on a frame boundary lands in the new frame.
  static const double _eps = 1e-6;

  final int frames;
  final void Function(int frame) onFrame;
  final void Function()? onEnd;
  final double _loops;
  final int Function(void Function(Duration now) cb) _raf;
  final void Function(int handle) _caf;
  final double Function()? _now;

  /// starts[i] = ms at which frame i begins; starts[frames] = length of one play.
  final Float64List _starts;
  late final double _cycle;

  int _handle = 0;
  bool _running = false;
  bool _destroyed = false;
  bool _finished = false;

  /// Absolute position in ms (may exceed one cycle while looping), advanced from the clock.
  double _position = 0;

  /// Clock reading at the first frame after play()/seek(); null until then (so idle time before the first frame never counts).
  double? _startedAt;
  double _startPosition = 0;
  int _emitted = -1;

  static int _defaultRaf(void Function(Duration now) cb) =>
      SchedulerBinding.instance.scheduleFrameCallback(cb);
  static void _defaultCaf(int handle) =>
      SchedulerBinding.instance.cancelFrameCallbackWithId(handle);

  bool get playing => _running;

  /// Current frame index (0 .. frames-1).
  int get frame => _frameAt(_position);

  /// Number of completed loops so far.
  int get loop => ((_position + _eps) / _cycle).floor();

  /// Length of one play in ms.
  double get duration => _cycle;

  /// Starts, resumes, or (after the end) restarts from frame 0.
  void play() {
    if (_destroyed || _running) return;
    if (_finished) {
      _finished = false;
      _position = 0;
      _emitted = -1;
    }
    _running = true;
    _startedAt = null;
    _startPosition = _position;
    _emit();
    _schedule();
  }

  void pause() {
    if (!_running) return;
    _running = false;
    _cancel();
  }

  /// Pauses and rewinds to frame 0 (does not emit `onEnd`).
  void stop() {
    _running = false;
    _cancel();
    _position = 0;
    _finished = false;
    _emitted = -1;
  }

  /// Jumps to a frame within the current loop (clamped) and emits it; keeps playing if playing.
  void seek(num frame) {
    if (_destroyed) return;
    final f = frame.floor().clamp(0, frames - 1);
    _finished = false;
    final maxLoop = _loops.isFinite ? _loops.toInt() - 1 : loop;
    final lp = loop < maxLoop ? loop : maxLoop;
    _position = lp * _cycle + _starts[f];
    _startedAt = null;
    _startPosition = _position;
    _emitted = -1;
    _emit();
  }

  void destroy() {
    _destroyed = true;
    _running = false;
    _cancel();
  }

  /// Index of the frame that is showing at absolute position [position] (ms): the last index whose start <= t (binary search).
  int _frameAt(double position) {
    final t = (position + _eps) % _cycle;
    var lo = 0;
    var hi = frames - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= t) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  void _step(Duration stamp) {
    _handle = 0;
    if (!_running) return;
    final now = _now?.call() ?? stamp.inMicroseconds / 1000;
    _startedAt ??= now;
    final pos = _startPosition + (now - _startedAt!).clamp(0, double.infinity);
    final total = _cycle * _loops;
    if (pos >= total) {
      // Show the last frame of the last play, then end.
      _position = total - _cycle + _starts[frames - 1];
      _running = false;
      _finished = true;
      _emit();
      onEnd?.call();
      return;
    }
    _position = pos;
    _emit();
    _schedule();
  }

  void _emit() {
    final f = _frameAt(_position);
    if (f == _emitted) return;
    _emitted = f;
    onFrame(f);
  }

  void _schedule() => _handle = _raf(_step);

  void _cancel() {
    if (_handle != 0) _caf(_handle);
    _handle = 0;
  }
}
