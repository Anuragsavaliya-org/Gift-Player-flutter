import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incodes_gift_player/incodes_gift_player.dart';

import 'helpers/synthetic.dart';

Uint8List gift({int frames = 3}) => svga2(
  fps: 60,
  frames: frames,
  sprites: [
    sprite('a.vector', [
      for (var i = 0; i < frames; i++)
        frame(
          shapes: [
            rectShape(0, 0, 100, 100, [1, 0, 0, 1]),
          ],
        ),
    ]),
  ],
);

Future<void> settle(WidgetTester t, bool Function() cond) async {
  for (var i = 0; i < 400 && !cond(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump(const Duration(milliseconds: 16));
  }
  expect(cond(), isTrue, reason: 'timed out');
}

void main() {
  testWidgets(
    'GiftPlayerView loads, plays, reports onLoad/onEnd and clears itself',
    (tester) async {
      GiftInfo? info;
      var ended = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: GiftPlayerView(
              src: gift(),
              onLoad: (i) => info = i,
              onEnd: () => ended = true,
            ),
          ),
        ),
      );
      await settle(tester, () => ended);
      expect(info!.frameCount, 3);
      expect(info!.format, GiftFormat.svga);
      await tester.pumpWidget(const SizedBox()); // unmount destroys the player
    },
  );

  testWidgets('autoPlay: false loads but does not play', (tester) async {
    var loaded = false;
    var ended = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 100,
          height: 100,
          child: GiftPlayerView(
            src: gift(),
            autoPlay: false,
            onLoad: (_) => loaded = true,
            onEnd: () => ended = true,
          ),
        ),
      ),
    );
    await settle(tester, () => loaded);
    await tester.pump(const Duration(milliseconds: 300));
    expect(ended, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing src reloads; the first load is aborted quietly', (
    tester,
  ) async {
    final loads = <GiftInfo>[];
    final errors = <GiftPlayerError>[];
    Widget build(Uint8List src) => Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 100,
        height: 100,
        child: GiftPlayerView(
          src: src,
          loops: 0,
          onLoad: loads.add,
          onError: errors.add,
        ),
      ),
    );
    await tester.pumpWidget(build(gift(frames: 3)));
    await settle(tester, () => loads.length == 1);
    await tester.pumpWidget(build(gift(frames: 5)));
    await settle(tester, () => loads.length == 2);
    expect(loads.last.frameCount, 5);
    expect(errors, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a broken src reports a typed error through onError', (
    tester,
  ) async {
    GiftPlayerError? err;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 100,
          height: 100,
          child: GiftPlayerView(
            src: Uint8List.fromList(List.filled(32, 7)),
            onError: (e) => err = e,
          ),
        ),
      ),
    );
    await settle(tester, () => err != null);
    expect(err!.code, GiftErrorCode.unsupportedFormat);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'GiftPlayerSurface paints the gift with a CustomPaint and shows nothing when idle',
    (tester) async {
      final player = GiftPlayer();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 100,
            height: 100,
            child: GiftPlayerSurface(player: player),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(GiftPlayerSurface),
          matching: find.byType(RepaintBoundary),
        ),
        findsNothing,
      ); // idle: nothing to show
      var loaded = false;
      player.load(gift()).then((_) => loaded = true);
      await settle(tester, () => loaded);
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      player.destroy();
      await tester.pump();
    },
  );
}
