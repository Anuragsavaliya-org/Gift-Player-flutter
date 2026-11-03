/// Every error the plugin throws or emits carries one of these codes (same ids as the web package).
///
/// * [unsupportedFormat]: the bytes are not SVGA / GIF / WebP / PAG, or the platform cannot run that format.
/// * [invalidInput]: the argument has the wrong type, or `play()` was called before `load()`.
/// * [network]: the file could not be fetched (offline, HTTP error) or a registered resolver failed.
/// * [parseFailed]: the container is corrupt or newer than the parser supports.
/// * [decodeFailed]: the file parsed but its pixels could not be decoded.
/// * [engineLoadFailed]: the native PAG engine could not be loaded or started.
/// * [aborted]: the operation was cancelled (an [AbortSignal], a newer `load()`, `stop()`, `destroy()`).
enum GiftErrorCode {
  unsupportedFormat('unsupported-format'),
  invalidInput('invalid-input'),
  network('network'),
  parseFailed('parse-failed'),
  decodeFailed('decode-failed'),
  engineLoadFailed('engine-load-failed'),
  aborted('aborted');

  const GiftErrorCode(this.id);

  /// The kebab-case id used by the web package (`'parse-failed'`, ...).
  final String id;

  @override
  String toString() => id;
}

/// The error type of the whole plugin; [code] says what went wrong.
class GiftPlayerError implements Exception {
  GiftPlayerError(this.code, this.message, {this.cause});

  final GiftErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'GiftPlayerError(${code.id}): $message';
}
