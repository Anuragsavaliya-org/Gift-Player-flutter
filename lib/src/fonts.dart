import 'dart:io';

import 'package:flutter/services.dart';

import 'errors.dart';
import 'pag/pag_platform.dart';

/// Fonts for dynamic text. SVGA's `setText` draws with Flutter's text engine and PAG's text layers are rasterised by libpag, so each
/// has its own font registry; [registerFont] fills both, so a family name works for either format.
///
/// Makes a font file ([data]: TTF/OTF bytes) available under [family] for `setText`. Completes once it is loaded and usable.
///
/// Flutter cannot unload a font once it is registered, so there is no "remove" function (the web package returns one).
Future<void> registerFont(String family, Uint8List data) async {
  if (family.trim().isEmpty) {
    throw GiftPlayerError(
      GiftErrorCode.invalidInput,
      'registerFont needs a family name.',
    );
  }
  // SVGA text (Flutter text engine).
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(data)));
  try {
    await loader.load();
  } catch (cause) {
    throw GiftPlayerError(
      GiftErrorCode.decodeFailed,
      'The font "$family" could not be loaded.',
      cause: cause,
    );
  }
  // PAG text (libpag): it reads fonts from a file. A platform without the PAG engine simply skips this.
  try {
    final dir = await Directory.systemTemp.createTemp('gift_player_font_');
    final file = File(
      '${dir.path}/${family.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.ttf',
    );
    await file.writeAsBytes(data, flush: true);
    await PagPlatform.registerFont(file.path, family);
  } on GiftPlayerError catch (e) {
    if (e.code != GiftErrorCode.engineLoadFailed) rethrow;
  }
}
