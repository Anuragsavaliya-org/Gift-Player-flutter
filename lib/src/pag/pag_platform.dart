import 'package:flutter/services.dart';

import '../errors.dart';

/// libpag layer types (same numbers on both platforms).
const int pagLayerText = 3;
const int pagLayerImage = 5;

/// libpag scale modes.
const int pagScaleStretch = 1;
const int pagScaleLetterbox = 2;
const int pagScaleZoom = 3;

/// What the native side reports for a loaded PAG file.
class PagFileInfo {
  PagFileInfo({
    required this.id,
    required this.textureId,
    required this.width,
    required this.height,
    required this.durationUs,
    required this.frameRate,
    required this.textIndices,
    required this.imageIndices,
    required this.textNames,
    required this.imageNames,
  });

  /// Native instance handle.
  final int id;

  /// Flutter texture the frames are rendered into.
  final int textureId;
  final int width, height;

  /// Duration in microseconds.
  final int durationUs;
  final double frameRate;
  final List<int> textIndices, imageIndices;

  /// Layer name for each editable index, in the same order ('' when unnamed).
  final List<String> textNames, imageNames;
}

/// Thin wrapper over the plugin's `MethodChannel`: native libpag (Android: `org.libpag`, iOS: `libpag` pod). Every method maps native
/// failures to a [GiftPlayerError]. The channel can be replaced in tests.
class PagPlatform {
  PagPlatform._();

  static MethodChannel channel = const MethodChannel('incodes_gift_player');

  static GiftPlayerError _map(PlatformException e, String fallback) {
    final code = switch (e.code) {
      'engine-load-failed' => GiftErrorCode.engineLoadFailed,
      'parse-failed' => GiftErrorCode.parseFailed,
      'unsupported-format' => GiftErrorCode.unsupportedFormat,
      'invalid-input' => GiftErrorCode.invalidInput,
      _ => GiftErrorCode.decodeFailed,
    };
    return GiftPlayerError(code, e.message ?? fallback, cause: e);
  }

  static Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw _map(e, 'PAG call "$method" failed.');
    } on MissingPluginException catch (e) {
      throw GiftPlayerError(
        GiftErrorCode.engineLoadFailed,
        'The native PAG engine is not available on this platform.',
        cause: e,
      );
    }
  }

  /// Loads the native libpag library (idempotent). Throws `engine-load-failed` when it cannot be loaded.
  static Future<void> ensureEngine() => _call<void>('pagInit');

  static Future<PagFileInfo> create(
    Uint8List bytes,
    int width,
    int height,
  ) async {
    final m = await _call<Map<Object?, Object?>>('pagCreate', {
      'bytes': bytes,
      'width': width,
      'height': height,
    });
    if (m == null) {
      throw GiftPlayerError(
        GiftErrorCode.parseFailed,
        'The PAG engine returned nothing for this file.',
      );
    }
    List<int> ints(Object? v) =>
        (v as List?)?.map((e) => (e as num).toInt()).toList() ?? const [];
    List<String> strs(Object? v) =>
        (v as List?)?.map((e) => e as String).toList() ?? const [];
    return PagFileInfo(
      id: (m['id'] as num).toInt(),
      textureId: (m['textureId'] as num).toInt(),
      width: (m['width'] as num).toInt(),
      height: (m['height'] as num).toInt(),
      durationUs: (m['duration'] as num).toInt(),
      frameRate: (m['frameRate'] as num).toDouble(),
      textIndices: ints(m['textIndices']),
      imageIndices: ints(m['imageIndices']),
      textNames: strs(m['textNames']),
      imageNames: strs(m['imageNames']),
    );
  }

  /// Renders the frame at [progress] (0..1) and completes once it has been flushed to the texture.
  static Future<void> render(int id, double progress) =>
      _call<void>('pagRender', {'id': id, 'progress': progress});

  static Future<void> resize(int id, int width, int height) =>
      _call<void>('pagResize', {'id': id, 'width': width, 'height': height});

  static Future<void> setScaleMode(int id, int mode) =>
      _call<void>('pagSetScaleMode', {'id': id, 'mode': mode});

  static Future<Map<String, Object?>> getTextData(int id, int index) async {
    final m = await _call<Map<Object?, Object?>>('pagGetTextData', {
      'id': id,
      'index': index,
    });
    return (m ?? const {}).map((k, v) => MapEntry(k as String, v));
  }

  static Future<void> replaceText(
    int id,
    int index,
    Map<String, Object?> doc,
  ) => _call<void>('pagReplaceText', {'id': id, 'index': index, 'doc': doc});

  /// Sets the text of ordinary (non-editable) text layers called [name]. Returns how many layers were changed.
  static Future<int> setLayerText(
    int id,
    String name,
    String text, {
    double? size,
    int? color,
  }) async =>
      (await _call<int>('pagSetLayerText', {
        'id': id,
        'name': name,
        'text': text,
        'size': size,
        'color': color,
      })) ??
      0;

  static Future<void> replaceImage(
    int id,
    int index,
    Uint8List bytes,
    int scaleMode,
  ) => _call<void>('pagReplaceImage', {
    'id': id,
    'index': index,
    'bytes': bytes,
    'scaleMode': scaleMode,
  });

  /// Shows/hides the layers called [name] (or, when none, the editable layer [index] of [type]). Returns how many were changed.
  static Future<int> setLayerVisible(
    int id, {
    String? name,
    int? index,
    int? type,
    required bool visible,
  }) async =>
      (await _call<int>('pagSetLayerVisible', {
        'id': id,
        'name': name,
        'index': index,
        'type': type,
        'visible': visible,
      })) ??
      0;

  static Future<void> dispose(int id) => _call<void>('pagDispose', {'id': id});

  /// Registers a font file with libpag under [family] (the family is read from the font itself on iOS/Android).
  static Future<void> registerFont(String path, String family) =>
      _call<void>('pagRegisterFont', {'path': path, 'family': family});
}
