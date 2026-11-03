import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'errors.dart';
import 'replacement.dart';
import 'source.dart';
import 'viewport.dart';

/// Tells painters (and the PAG texture widget) that a renderer has something new to show.
class RepaintNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// The contract between a format renderer and the clock ([FrameClock]): a number of frames with a duration each, an optional loop
/// count from the file, and a way to show frame `i`. SVGA has a fixed fps, so every frame lasts `1000 / fps`; GIF and WebP carry a
/// delay per frame.
///
/// Renderers paint themselves: [paint] draws the current frame into a canvas (SVGA, GIF, WebP), while PAG renders into a native
/// texture ([textureId]) that the view shows with a `Texture` widget.
abstract class GiftRenderer {
  /// Fires after the visible content changed.
  final RepaintNotifier repaint = RepaintNotifier();

  int get frameCount;

  /// Duration of frame [i] in milliseconds (always > 0).
  double frameDuration(int i);

  /// Loop count stored in the file, normalised to the TOTAL number of plays (0 = forever). null when the format has no such field
  /// (SVGA, PAG) or the file does not specify one.
  int? get loopCount;

  /// Intrinsic size of the content (SVGA viewBox, GIF/WebP/PAG canvas).
  ui.Size get size;

  /// Puts frame [i] on screen. Returns true if it is on screen now. Returns false when the frame is still being decoded/rendered:
  /// it is then shown as soon as it is ready (if it is still the wanted frame).
  bool drawFrame(int i);

  /// Completes once frame [i] can be shown.
  Future<void> ready(int i);

  /// Blanks the output now and forgets the frame that was showing (a later [drawFrame] shows again).
  void clear();

  void destroy();

  ContentMode get contentMode;
  set contentMode(ContentMode mode);

  /// Draws the current frame into [canvas] (a box of [box] logical pixels). Does nothing for texture renderers.
  void paint(ui.Canvas canvas, ui.Size box);

  /// Native texture to show instead of calling [paint] (PAG), or null.
  int? get textureId => null;

  /// True while a frame is on screen (false after [clear] until the next [drawFrame]).
  bool get hasFrame;

  /// Called by the view with its size in physical pixels, so texture renderers can size their surface.
  void setViewSize(ui.Size pixels) {}

  // ---- dynamic replacement (SVGA and PAG) -------------------------------------------------------------------------------

  /// Whether this format has replaceable text / images (GIF and WebP do not).
  bool get supportsReplacement => false;

  List<EditableKey> getEditableKeys() => const [];

  void setText(
    String key,
    String text, [
    GiftTextStyle style = const GiftTextStyle(),
  ]) {}

  Future<void> setImage(
    String key,
    Object source, [
    GiftImageOptions options = const GiftImageOptions(),
  ]) async {}

  void setHidden(String key, bool hidden) {}

  void clearReplacement(String key) {}
}

/// Decodes encoded image bytes (PNG/JPEG/WebP/GIF first frame) into a drawable [ui.Image]. The caller owns the image.
Future<ui.Image> decodeImageBytes(Uint8List bytes) async {
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  } catch (cause) {
    throw GiftPlayerError(
      GiftErrorCode.decodeFailed,
      'The image could not be decoded.',
      cause: cause,
    );
  } finally {
    codec?.dispose();
  }
}

/// A replacement picture and whether the renderer owns (and must dispose) it.
class LoadedReplacementImage {
  LoadedReplacementImage(this.image, this.owned);
  final ui.Image image;
  final bool owned;
}

/// Resolves what `setImage` accepts: a [ui.Image] (used as is, never disposed by us), encoded bytes, or a URL / file / asset string.
Future<LoadedReplacementImage> loadReplacementImage(Object source) async {
  if (source is ui.Image) return LoadedReplacementImage(source, false);
  if (source is Uint8List) {
    return LoadedReplacementImage(await decodeImageBytes(source), true);
  }
  if (source is String || source is GiftSource) {
    final bytes = await readSource(source);
    return LoadedReplacementImage(await decodeImageBytes(bytes), true);
  }
  throw GiftPlayerError(
    GiftErrorCode.invalidInput,
    'A replacement image must be a ui.Image, encoded bytes, or a URL string.',
  );
}
