import 'dart:typed_data';

/// Classifies raw bytes by magic number. Audio must never reach the image codec.
class MediaKind {
  const MediaKind.image(this.mime) : isImage = true;
  const MediaKind.audio(this.mime) : isImage = false;
  final bool isImage;
  final String mime;
}

bool _at(Uint8List b, int offset, String text) {
  if (b.length < offset + text.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (b[offset + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

MediaKind? classifyMedia(Uint8List b) {
  if (b.length >= 8 && b[0] == 0x89 && _at(b, 1, 'PNG\r\n')) {
    return const MediaKind.image('image/png');
  }
  if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) {
    return const MediaKind.image('image/jpeg');
  }
  if (_at(b, 0, 'RIFF') && _at(b, 8, 'WEBP')) {
    return const MediaKind.image('image/webp');
  }
  if (_at(b, 0, 'RIFF') && _at(b, 8, 'WAVE')) {
    return const MediaKind.audio('audio/wav');
  }
  if (_at(b, 0, 'ID3')) return const MediaKind.audio('audio/mpeg');
  // MPEG audio frame sync: 11 set bits.
  if (b.length >= 2 && b[0] == 0xff && (b[1] & 0xe0) == 0xe0) {
    return const MediaKind.audio('audio/mpeg');
  }
  if (_at(b, 0, 'OggS')) return const MediaKind.audio('audio/ogg');
  if (_at(b, 0, 'fLaC')) return const MediaKind.audio('audio/flac');
  if (_at(b, 4, 'ftyp')) return const MediaKind.audio('audio/mp4');
  return null;
}
