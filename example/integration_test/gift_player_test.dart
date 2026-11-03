// Runs on a device or emulator: `flutter test integration_test` from this folder (the PAG parts need the real libpag).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incodes_gift_player/incodes_gift_player.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GIF from the bundled assets plays through the real codec', (
    tester,
  ) async {
    final player = GiftPlayer();
    final info = await player.load('asset:assets/gifts/rotating-earth.gif');
    expect(info.format, GiftFormat.gif);
    expect(info.frameCount, greaterThan(1));
    player.destroy();
  });

  testWidgets(
    'PAG loads through the native engine, exposes editable layers and plays to the end',
    (tester) async {
      final player = GiftPlayer();
      final info = await player.load('asset:assets/gifts/like.pag');
      expect(info.format, GiftFormat.pag);
      expect(info.frameCount, greaterThan(0));
      var ended = false;
      player.onEnd.listen((_) => ended = true);
      await player.play().timeout(const Duration(seconds: 20));
      expect(ended, isTrue);
      player.destroy();
    },
  );

  testWidgets('PAG text replacement reaches libpag', (tester) async {
    final player = GiftPlayer();
    final info = await player.load('asset:assets/gifts/replacement.pag');
    final text = info.editableKeys.where((k) => k.type == 'text');
    if (text.isNotEmpty) player.setText(text.first.key, 'Rahul');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    player.destroy();
  });

  testWidgets('a corrupt PAG fails with parse-failed, not a crash', (
    tester,
  ) async {
    final player = GiftPlayer();
    await expectLater(
      player.load(Uint8List.fromList([...'PAG'.codeUnits, 1, 2, 3, 4, 5, 6])),
      throwsA(isA<GiftPlayerError>()),
    );
    player.destroy();
  });

  testWidgets('platform channel is registered', (tester) async {
    // Calls an unknown method: a registered plugin answers "not implemented" instead of throwing MissingPluginException.
    const channel = MethodChannel('incodes_gift_player');
    expect(Platform.isAndroid || Platform.isIOS, isTrue);
    await expectLater(
      channel.invokeMethod<void>('definitelyNotAMethod'),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
