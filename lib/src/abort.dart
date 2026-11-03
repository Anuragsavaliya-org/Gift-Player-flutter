import 'errors.dart';

/// Read side of an [AbortController] (the Dart counterpart of the web `AbortSignal`).
class AbortSignal {
  AbortSignal._(this._controller);

  final AbortController _controller;

  bool get aborted => _controller._aborted;

  /// Calls [fn] once when the signal aborts (immediately if it already has). Returns a function that removes the listener.
  void Function() onAbort(void Function() fn) {
    if (aborted) {
      fn();
      return () {};
    }
    _controller._listeners.add(fn);
    return () => _controller._listeners.remove(fn);
  }

  /// Throws a [GiftErrorCode.aborted] error when aborted.
  void throwIfAborted([String message = 'The load was aborted.']) {
    if (aborted) throw GiftPlayerError(GiftErrorCode.aborted, message);
  }
}

/// Cancels asynchronous work: hand [signal] to the work and call [abort] to cancel it.
class AbortController {
  bool _aborted = false;
  final List<void Function()> _listeners = [];
  late final AbortSignal signal = AbortSignal._(this);

  void abort() {
    if (_aborted) return;
    _aborted = true;
    final list = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final fn in list) {
      fn();
    }
  }
}
