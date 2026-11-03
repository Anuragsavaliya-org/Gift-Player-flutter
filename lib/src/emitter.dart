import 'package:flutter/foundation.dart';

/// A typed event: `player.onEnd.listen((_) {...})`. A throwing listener is reported and never breaks the others.
class GiftEvent<T> {
  final List<void Function(T)> _listeners = [];

  /// Subscribes; returns the function that unsubscribes.
  void Function() listen(void Function(T payload) fn) {
    _listeners.add(fn);
    return () => _listeners.remove(fn);
  }

  void remove(void Function(T payload) fn) => _listeners.remove(fn);

  /// True when someone listens (lets hot paths skip building a payload).
  bool get hasListeners => _listeners.isNotEmpty;

  void emit(T payload) {
    if (_listeners.isEmpty) return;
    for (final fn in List<void Function(T)>.of(_listeners)) {
      try {
        fn(payload);
      } catch (e, st) {
        debugPrint('[gift-player] an event listener threw: $e\n$st');
      }
    }
  }

  void clear() => _listeners.clear();
}
