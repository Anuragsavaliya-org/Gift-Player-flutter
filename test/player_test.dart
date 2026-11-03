import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incodes_gift_player/incodes_gift_player.dart';
import 'package:incodes_gift_player/src/pag/pag_platform.dart';

import 'helpers/synthetic.dart';

/// A tiny vector-only gift: [frames] frames at 100 fps (10 ms each), no images (so nothing needs a real codec).
Uint8List tinyGift({
  int frames = 3,
  Map<String, List<int>> images = const {},
}) => svga2(
  fps: 60,
  frames: frames,
  images: images,
  sprites: [
    sprite('name', [
      for (var i = 0; i < frames; i++)
        frame(
          layout: [0, 0, 50, 20],
          shapes: [
            rectShape(0, 0, 10, 10, [1, 0, 0, 1]),
          ],
        ),
    ]),
  ],
);

Future<void> pumpUntil(
  WidgetTester t,
  bool Function() cond, {
  int max = 600,
}) async {
  for (var i = 0; i < max && !cond(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump(const Duration(milliseconds: 16));
  }
  expect(cond(), isTrue, reason: 'timed out waiting');
}

void main() {
  final files = <String, Uint8List>{};
  final off = <void Function()>[];

  setUp(() {
    files
      ..clear()
      ..['ok'] = tinyGift()
      ..['ok2'] = tinyGift(frames: 2)
      ..['bad'] = Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9, 9]);
    off.add(
      registerResolver('t', (ref, _) {
        final f = files[ref];
        if (f == null) {
          throw GiftPlayerError(
            GiftErrorCode.network,
            'no such test file $ref',
          );
        }
        return f;
      }),
    );
    GiftPlayer.getCache().clear();
  });

  tearDown(() {
    for (final o in off) {
      o();
    }
    off.clear();
  });

  group('GiftPlayer', () {
    testWidgets(
      'load -> play: events fire in order, play completes, the view is cleared at the end',
      (tester) async {
        final player = GiftPlayer();
        final log = <String>[];
        player.onLoaded.listen(
          (i) => log.add('loaded ${i.format.name} ${i.frameCount}'),
        );
        player.onStart.listen((_) => log.add('start'));
        player.onEnd.listen((_) => log.add('end'));
        player.onError.listen((e) => log.add('error ${e.code}'));
        GiftInfo? info;
        player.load('t:ok').then((i) => info = i);
        await pumpUntil(tester, () => info != null);
        expect(info!.format, GiftFormat.svga);
        expect(info!.width, 100);
        expect(info!.frameCount, 3);
        expect(info!.durationMs, closeTo(50, 0.001));
        expect(info!.editableKeys.map((k) => k.key), ['name']);
        expect(
          player.renderer!.hasFrame,
          isTrue,
        ); // the first frame is shown after load
        var done = false;
        player.play().then((_) => done = true);
        await pumpUntil(tester, () => done);
        expect(log, ['loaded svga 3', 'start', 'end']);
        expect(player.renderer!.hasFrame, isFalse); // clearOnEnd
        player.destroy();
      },
    );

    testWidgets('clearOnEnd: false keeps the last frame', (tester) async {
      final player = GiftPlayer(const GiftPlayerOptions(clearOnEnd: false));
      var loaded = false;
      player.load('t:ok').then((_) => loaded = true);
      await pumpUntil(tester, () => loaded);
      var done = false;
      player.play().then((_) => done = true);
      await pumpUntil(tester, () => done);
      expect(player.renderer!.hasFrame, isTrue);
      player.clear();
      expect(player.renderer!.hasFrame, isFalse);
      player.destroy();
    });

    testWidgets(
      'loops: N plays, onLoop counts completed plays, onFrame is opt-in',
      (tester) async {
        final player = GiftPlayer();
        final loops = <int>[];
        final frames = <int>[];
        player.onLoop.listen(loops.add);
        var loaded = false;
        player
            .load('t:ok', options: const LoadOptions(loops: 3))
            .then((_) => loaded = true);
        await pumpUntil(tester, () => loaded);
        player.onFrame.listen(frames.add);
        var done = false;
        player.play().then((_) => done = true);
        await pumpUntil(tester, () => done);
        expect(loops, [1, 2]);
        expect(frames, isNotEmpty);
        player.destroy();
      },
    );

    testWidgets('play() before load() fails with invalid-input', (
      tester,
    ) async {
      final player = GiftPlayer();
      await expectLater(
        player.play(),
        throwsA(
          isA<GiftPlayerError>().having(
            (e) => e.code,
            'code',
            GiftErrorCode.invalidInput,
          ),
        ),
      );
      player.destroy();
    });

    testWidgets('a bad file fails with a typed error and emits onError once', (
      tester,
    ) async {
      final player = GiftPlayer();
      final errors = <GiftPlayerError>[];
      player.onError.listen(errors.add);
      Object? thrown;
      player.load('t:bad').catchError((Object e) {
        thrown = e;
        return Future<GiftInfo>.error(e);
      }).ignore();
      await pumpUntil(tester, () => thrown != null);
      expect((thrown as GiftPlayerError).code, GiftErrorCode.unsupportedFormat);
      expect(errors.map((e) => e.code), [GiftErrorCode.unsupportedFormat]);
      player.destroy();
    });

    testWidgets(
      'a failing resolver is a network error; an unknown scheme is invalid-input',
      (tester) async {
        final player = GiftPlayer();
        final results = <GiftErrorCode>[];
        for (final src in ['t:missing', 'zzz:what']) {
          player
              .load(src)
              .then(
                (_) {},
                onError: (Object e) {
                  results.add((e as GiftPlayerError).code);
                },
              );
        }
        await pumpUntil(tester, () => results.length == 2);
        expect(
          results,
          containsAll([GiftErrorCode.network, GiftErrorCode.invalidInput]),
        );
        player.destroy();
      },
    );

    testWidgets('a newer load() aborts the one in flight, quietly', (
      tester,
    ) async {
      final gate = Completer<Uint8List>();
      off.add(registerResolver('slow', (ref, _) => gate.future));
      final player = GiftPlayer();
      final errors = <GiftPlayerError>[];
      player.onError.listen(errors.add);
      GiftErrorCode? first;
      player
          .load('slow:x')
          .then(
            (_) {},
            onError: (Object e) {
              first = (e as GiftPlayerError).code;
            },
          );
      GiftInfo? second;
      player.load('t:ok').then((i) => second = i);
      await pumpUntil(tester, () => first != null && second != null);
      expect(first, GiftErrorCode.aborted);
      expect(errors, isEmpty);
      gate.complete(tinyGift());
      player.destroy();
    });

    testWidgets('an AbortSignal cancels load()', (tester) async {
      final gate = Completer<Uint8List>();
      off.add(registerResolver('slow2', (ref, _) => gate.future));
      final player = GiftPlayer();
      final ctl = AbortController();
      GiftErrorCode? code;
      player
          .load('slow2:x', options: LoadOptions(signal: ctl.signal))
          .then(
            (_) {},
            onError: (Object e) {
              code = (e as GiftPlayerError).code;
            },
          );
      await tester.pump();
      ctl.abort();
      await pumpUntil(tester, () => code != null);
      expect(code, GiftErrorCode.aborted);
      player.destroy();
    });

    testWidgets(
      'stop() rewinds and fails the pending play with aborted; pause/resume keep the frame',
      (tester) async {
        final player = GiftPlayer();
        var loaded = false;
        player
            .load('t:ok', options: const LoadOptions(loops: 0))
            .then((_) => loaded = true);
        await pumpUntil(tester, () => loaded);
        GiftErrorCode? code;
        player.play().then(
          (_) {},
          onError: (Object e) {
            code = (e as GiftPlayerError).code;
          },
        );
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(player.playing, isTrue);
        player.pause();
        expect(player.playing, isFalse);
        player.resume();
        expect(player.playing, isTrue);
        player.stop();
        await pumpUntil(tester, () => code != null);
        expect(code, GiftErrorCode.aborted);
        expect(player.playing, isFalse);
        player.destroy();
      },
    );

    testWidgets('destroy() fails a pending play and later loads', (
      tester,
    ) async {
      final player = GiftPlayer();
      var loaded = false;
      player
          .load('t:ok', options: const LoadOptions(loops: 0))
          .then((_) => loaded = true);
      await pumpUntil(tester, () => loaded);
      GiftErrorCode? code;
      player.play().then(
        (_) {},
        onError: (Object e) {
          code = (e as GiftPlayerError).code;
        },
      );
      player.destroy();
      await pumpUntil(tester, () => code != null);
      expect(code, GiftErrorCode.aborted);
      await expectLater(
        player.load('t:ok'),
        throwsA(
          isA<GiftPlayerError>().having(
            (e) => e.code,
            'code',
            GiftErrorCode.aborted,
          ),
        ),
      );
      player.destroy(); // twice is fine
    });

    testWidgets(
      'replacements passed to load() are applied; unknown keys are ignored; getEditableKeys works',
      (tester) async {
        final player = GiftPlayer();
        GiftInfo? info;
        player
            .load(
              't:ok',
              options: const LoadOptions(
                replacements: {
                  'name': Replacement.text(
                    'Rahul',
                    style: GiftTextStyle(size: 20),
                  ),
                  'nope': Replacement.text('x'),
                  'also': Replacement.hidden(true),
                },
              ),
            )
            .then((i) => info = i);
        await pumpUntil(tester, () => info != null);
        expect(player.getEditableKeys().single.key, 'name');
        player.setText('name', 'Anurag');
        player.setHidden('name', true);
        player.clearReplacement('name');
        player.destroy();
      },
    );

    testWidgets('content mode can change at any time', (tester) async {
      final player = GiftPlayer();
      var loaded = false;
      player.load('t:ok').then((_) => loaded = true);
      await pumpUntil(tester, () => loaded);
      player.setContentMode(ContentMode.fill);
      expect(player.renderer!.contentMode, ContentMode.fill);
      expect(player.contentMode, ContentMode.fill);
      player.destroy();
    });

    testWidgets('seek() shows the requested frame', (tester) async {
      final player = GiftPlayer();
      var loaded = false;
      player.load('t:ok').then((_) => loaded = true);
      await pumpUntil(tester, () => loaded);
      final seen = <int>[];
      player.onFrame.listen(seen.add);
      player.seek(2);
      expect(seen, [2]);
      player.destroy();
    });

    testWidgets('bytes sources are accepted and not cached', (tester) async {
      final player = GiftPlayer();
      final before = GiftPlayer.getCache().stats.entries;
      var loaded = false;
      player.load(tinyGift()).then((_) => loaded = true);
      await pumpUntil(tester, () => loaded);
      expect(GiftPlayer.getCache().stats.entries, before);
      player.destroy();
    });
  });

  group('cache and preload', () {
    testWidgets(
      'preload caches URLs/resolved refs, reports failures, skips bytes; a later load is a cache hit',
      (tester) async {
        List<PreloadResult>? res;
        GiftPlayer.preload([
          't:ok',
          't:bad',
          GiftSource.bytes(tinyGift()),
        ]).then((r) => res = r);
        await pumpUntil(tester, () => res != null);
        expect(res!.map((r) => r.status), [
          PreloadStatus.cached,
          PreloadStatus.failed,
          PreloadStatus.skipped,
        ]);
        expect(res![1].error!.code, GiftErrorCode.unsupportedFormat);
        final hits = GiftPlayer.getCache().stats.hits;
        final player = GiftPlayer();
        var loaded = false;
        player.load('t:ok').then((_) => loaded = true);
        await pumpUntil(tester, () => loaded);
        expect(GiftPlayer.getCache().stats.hits, hits + 1);
        player.destroy();
      },
    );

    testWidgets(
      'two players share one cached gift; idle gifts can be cleared once nobody shows them',
      (tester) async {
        final a = GiftPlayer(), b = GiftPlayer();
        var n = 0;
        a.load('t:ok').then((_) => n++);
        b.load('t:ok').then((_) => n++);
        await pumpUntil(tester, () => n == 2);
        expect(GiftPlayer.getCache().stats.inUse, 1);
        a.destroy();
        b.destroy();
        expect(
          GiftPlayer.getCache().stats.inUse,
          0,
        ); // both leases were given back
        GiftPlayer.getCache().clear();
        expect(GiftPlayer.getCache().stats.entries, 0);
      },
    );
  });

  group('GiftQueue', () {
    Future<(GiftPlayer, GiftQueue)> make(
      WidgetTester t, [
      GiftQueueOptions o = const GiftQueueOptions(),
    ]) async {
      final p = GiftPlayer();
      return (p, GiftQueue(p, o));
    }

    testWidgets(
      'plays one at a time, higher priority first, FIFO within a priority; emits idle',
      (tester) async {
        final (player, q) = await make(tester);
        final order = <String>[];
        q.onItemStart.listen((i) => order.add('${i.src}'));
        var idle = false;
        q.onIdle.listen((_) => idle = true);
        q.add('t:ok', priority: 0);
        q.add('t:ok2', priority: 5);
        q.add('t:ok', priority: 5);
        q.add('t:ok2', priority: 0);
        await pumpUntil(tester, () => idle);
        expect(order, ['t:ok2', 't:ok', 't:ok', 't:ok2']);
        expect(q.stats.played, 4);
        expect(q.isPlaying, isFalse);
        expect(q.length, 0);
        q.destroy();
        player.destroy();
      },
    );

    testWidgets(
      'coalesce merges identical consecutive items into one with a count',
      (tester) async {
        final (player, q) = await make(
          tester,
          const GiftQueueOptions(coalesce: true),
        );
        final counts = <int>[];
        q.onItemStart.listen((i) => counts.add(i.count));
        var idle = false;
        q.onIdle.listen((_) => idle = true);
        final handles = [for (var i = 0; i < 10; i++) q.add('t:ok')];
        q.add('t:ok2');
        expect(handles.first.count, 10);
        await pumpUntil(tester, () => idle);
        expect(counts, [10, 1]);
        expect(await handles.last.done, QueueItemStatus.done);
        q.destroy();
        player.destroy();
      },
    );

    testWidgets('overflow drops the lowest priority, oldest first', (
      tester,
    ) async {
      final (player, q) = await make(
        tester,
        const GiftQueueOptions(maxLength: 2),
      );
      final dropped = <String>[];
      q.onItemDropped.listen(
        (d) => dropped.add('${d.item.src}/${d.item.priority}/${d.reason.name}'),
      );
      q.add(
        't:ok',
        priority: 1,
      ); // starts playing next microtask... still waiting now
      q.add('t:ok2', priority: 1);
      q.add(
        't:ok',
        priority: 9,
      ); // full: the oldest of the lowest priority goes
      expect(dropped, ['t:ok/1/overflow']);
      final h = q.add(
        't:ok2',
        priority: 0,
      ); // lower than everything waiting -> the new item itself is dropped
      expect(await h.done, QueueItemStatus.dropped);
      expect(q.stats.dropped, 2);
      q.destroy();
      player.destroy();
    });

    testWidgets(
      'a broken gift is reported and skipped; the queue never stalls',
      (tester) async {
        final (player, q) = await make(tester);
        final errors = <GiftErrorCode>[];
        q.onItemError.listen((e) => errors.add(e.error.code));
        var idle = false;
        q.onIdle.listen((_) => idle = true);
        q.add('t:bad');
        final h = q.add('t:missing');
        q.add('t:ok');
        await pumpUntil(tester, () => idle);
        expect(errors, [
          GiftErrorCode.unsupportedFormat,
          GiftErrorCode.network,
        ]);
        expect(await h.done, QueueItemStatus.failed);
        expect(q.stats.failed, 2);
        expect(q.stats.played, 1);
        q.destroy();
        player.destroy();
      },
    );

    testWidgets(
      'cancel() removes a waiting item; clear() drops the rest; skip() moves on',
      (tester) async {
        final (player, q) = await make(tester);
        final reasons = <DropReason>[];
        q.onItemDropped.listen((d) => reasons.add(d.reason));
        q.pause(); // keep everything waiting
        final a = q.add('t:ok');
        q.add('t:ok2');
        q.add('t:ok');
        a.cancel();
        expect(await a.done, QueueItemStatus.cancelled);
        expect(q.length, 2);
        q.clear();
        expect(q.length, 0);
        expect(reasons, [
          DropReason.cancelled,
          DropReason.cleared,
          DropReason.cleared,
        ]);

        q.resume();
        var begun = false;
        q.onItemBegin.listen((_) => begun = true);
        files['long'] = svga2(fps: 1, frames: 100, sprites: []); // 100 s
        final long = q.add('t:long');
        await pumpUntil(tester, () => begun);
        await pumpUntil(tester, () => player.playing);
        q.skip();
        expect(
          await long.done.timeout(
            const Duration(seconds: 1),
            onTimeout: () => QueueItemStatus.pending,
          ),
          anyOf(QueueItemStatus.cancelled, QueueItemStatus.pending),
        );
        await pumpUntil(tester, () => !q.isPlaying);
        q.destroy();
        player.destroy();
      },
    );

    testWidgets('pause() stops starting new gifts, resume() continues', (
      tester,
    ) async {
      final (player, q) = await make(tester);
      var started = 0;
      q.onItemStart.listen((_) => started++);
      q.pause();
      q.add('t:ok');
      await tester.pump(const Duration(milliseconds: 100));
      expect(started, 0);
      expect(q.length, 1);
      q.resume();
      await pumpUntil(tester, () => started == 1);
      q.destroy();
      player.destroy();
    });

    testWidgets('preloads the next gifts while the current one plays', (
      tester,
    ) async {
      final (player, q) = await make(
        tester,
        const GiftQueueOptions(preloadAhead: 2),
      );
      files['long'] = svga2(fps: 1, frames: 100, sprites: []);
      q.add('t:long');
      q.add('t:ok');
      q.add('t:ok2');
      q.add('t:ok'); // beyond the window
      await pumpUntil(
        tester,
        () =>
            GiftPlayer.getCache().has('t:ok') &&
            GiftPlayer.getCache().has('t:ok2'),
      );
      q.destroy();
      player.destroy();
    });

    testWidgets('destroy() drops waiting items and later adds are dropped', (
      tester,
    ) async {
      final (player, q) = await make(tester);
      q.pause();
      final a = q.add('t:ok');
      q.destroy();
      expect(await a.done, QueueItemStatus.dropped);
      expect(await q.add('t:ok').done, QueueItemStatus.dropped);
      player.destroy();
    });
  });

  group('GiftQueueController', () {
    testWidgets('exposes live stats', (tester) async {
      final c = GiftQueueController();
      c.queue.add('t:ok');
      expect(c.stats.value.pending, 1);
      await pumpUntil(tester, () => c.stats.value.played == 1);
      expect(c.stats.value.pending, 0);
      c.dispose();
    });
  });

  group('PAG (native engine mocked at the channel)', () {
    final calls = <MethodCall>[];
    var textDoc = <Object?, Object?>{};

    setUp(() {
      calls.clear();
      textDoc = {
        'text': 'original',
        'fontSize': 24.0,
        'fontFamily': 'Arial',
        'fontStyle': 'Regular',
        'fillColor': 0xff000000,
        'strokeColor': 0xff000000,
        'strokeWidth': 1.0,
        'applyFill': true,
        'applyStroke': false,
        'justification': 0,
        'fauxBold': false,
      };
      PagPlatform.channel = const MethodChannel('test_pag');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PagPlatform.channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'pagInit':
                return null;
              case 'pagCreate':
                return {
                  'id': 7,
                  'textureId': 42,
                  'width': 300,
                  'height': 200,
                  'duration': 1000000, // 1 s
                  'frameRate': 30.0,
                  'textIndices': [0, 1],
                  'imageIndices': [0],
                  'textNames': ['title', 'title'], // ambiguous -> #index keys
                  'imageNames': ['avatar'],
                };
              case 'pagGetTextData':
                return textDoc;
              case 'pagSetLayerText':
                return (call.arguments as Map)['name'] == 'plain' ? 1 : 0;
              case 'pagSetLayerVisible':
                return (call.arguments as Map)['name'] == 'banner' ? 1 : 0;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PagPlatform.channel, null);
    });

    Uint8List pagBytes() =>
        Uint8List.fromList([...'PAG'.codeUnits, 1, 2, 3, 4]);

    testWidgets(
      'loads through the engine, maps keys, drives frames by progress, disposes on destroy',
      (tester) async {
        final player = GiftPlayer();
        GiftInfo? info;
        player.load(pagBytes()).then((i) => info = i);
        await pumpUntil(tester, () => info != null);
        expect(info!.format, GiftFormat.pag);
        expect(info!.frameCount, 30);
        expect(info!.durationMs, closeTo(1000, 0.01));
        expect(info!.width, 300);
        expect(info!.editableKeys.map((k) => '${k.key}:${k.type}'), [
          '#0:text',
          '#1:text',
          'avatar:image',
        ]); // ambiguous names -> #index
        expect(player.renderer!.textureId, 42);
        final renders = calls.where((c) => c.method == 'pagRender').toList();
        expect(renders, isNotEmpty);
        expect(
          ((renders.first.arguments as Map)['progress'] as double),
          closeTo(0, 0.001),
        );
        player.seek(15);
        await pumpUntil(
          tester,
          () =>
              calls.where((c) => c.method == 'pagRender').length >
              renders.length,
        );
        expect(
          ((calls.lastWhere((c) => c.method == 'pagRender').arguments
                  as Map)['progress']
              as double),
          closeTo(0.5, 0.01),
        );
        player.destroy();
        await pumpUntil(
          tester,
          () => calls.any((c) => c.method == 'pagDispose'),
        );
        expect(
          (calls.lastWhere((c) => c.method == 'pagDispose').arguments
              as Map)['id'],
          7,
        );
      },
    );

    testWidgets(
      'setText edits the document, clearReplacement restores the original',
      (tester) async {
        final player = GiftPlayer();
        var loaded = false;
        player.load(pagBytes()).then((_) => loaded = true);
        await pumpUntil(tester, () => loaded);
        player.setText(
          '#0',
          'Rahul',
          style: const GiftTextStyle(
            size: 40,
            color: Color(0xff00ff00),
            weight: 'bold',
            align: GiftTextAlign.center,
          ),
        );
        await pumpUntil(
          tester,
          () => calls.any((c) => c.method == 'pagReplaceText'),
        );
        var doc =
            (calls.firstWhere((c) => c.method == 'pagReplaceText').arguments
                    as Map)['doc']
                as Map;
        expect(doc['text'], 'Rahul');
        expect(doc['fontSize'], 40);
        expect(doc['fillColor'], 0xff00ff00);
        expect(doc['fauxBold'], isTrue);
        expect(doc['justification'], 1);
        player.clearReplacement('#0');
        await pumpUntil(
          tester,
          () => calls.where((c) => c.method == 'pagReplaceText').length == 2,
        );
        doc =
            (calls.lastWhere((c) => c.method == 'pagReplaceText').arguments
                    as Map)['doc']
                as Map;
        expect(doc['text'], 'original');
        player.destroy();
      },
    );

    testWidgets(
      'setText on an ordinary layer name falls back to the layer API; unknown names warn',
      (tester) async {
        final player = GiftPlayer();
        var loaded = false;
        player.load(pagBytes()).then((_) => loaded = true);
        await pumpUntil(tester, () => loaded);
        player.setText('plain', 'hi', style: const GiftTextStyle(size: 12));
        player.setText('ghost', 'hi');
        await pumpUntil(
          tester,
          () => calls.where((c) => c.method == 'pagSetLayerText').length == 2,
        );
        player.destroy();
      },
    );

    testWidgets(
      'setImage sends encoded bytes and the fit; setHidden toggles layers',
      (tester) async {
        final player = GiftPlayer();
        var loaded = false;
        player.load(pagBytes()).then((_) => loaded = true);
        await pumpUntil(tester, () => loaded);
        var done = false;
        player
            .setImage(
              'avatar',
              tinyPng,
              options: const GiftImageOptions(fit: GiftImageFit.cover),
            )
            .then((_) => done = true);
        await pumpUntil(tester, () => done);
        final a =
            calls.firstWhere((c) => c.method == 'pagReplaceImage').arguments
                as Map;
        expect(a['index'], 0);
        expect(a['scaleMode'], pagScaleZoom);
        expect(a['bytes'], tinyPng);
        player.setHidden('banner', true);
        await pumpUntil(
          tester,
          () => calls.any((c) => c.method == 'pagSetLayerVisible'),
        );
        expect(
          (calls.firstWhere((c) => c.method == 'pagSetLayerVisible').arguments
              as Map)['visible'],
          isFalse,
        );
        player.destroy();
      },
    );

    testWidgets('content mode maps to libpag scale modes', (tester) async {
      final player = GiftPlayer();
      var loaded = false;
      player.load(pagBytes()).then((_) => loaded = true);
      await pumpUntil(tester, () => loaded);
      player.setContentMode(ContentMode.aspectFill);
      await pumpUntil(
        tester,
        () => calls.where((c) => c.method == 'pagSetScaleMode').length >= 2,
      );
      expect(
        (calls.last.method == 'pagRender'
                ? calls.where((c) => c.method == 'pagSetScaleMode').last
                : calls.last)
            .arguments,
        containsPair('mode', pagScaleZoom),
      );
      player.destroy();
    });

    testWidgets('the view size is forwarded to the native surface in pixels', (
      tester,
    ) async {
      final player = GiftPlayer();
      var loaded = false;
      player.load(pagBytes()).then((_) => loaded = true);
      await pumpUntil(tester, () => loaded);
      player.updateViewSize(const Size(720, 1280));
      await pumpUntil(tester, () => calls.any((c) => c.method == 'pagResize'));
      expect(
        calls.firstWhere((c) => c.method == 'pagResize').arguments,
        containsPair('width', 720),
      );
      player.destroy();
    });

    testWidgets('engine failures map to engine-load-failed / parse-failed', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PagPlatform.channel, (call) async {
            if (call.method == 'pagInit') {
              throw PlatformException(
                code: 'engine-load-failed',
                message: 'libpag.so missing',
              );
            }
            return null;
          });
      final player = GiftPlayer();
      GiftPlayerError? err;
      player
          .load(pagBytes())
          .then(
            (_) {},
            onError: (Object e) {
              err = e as GiftPlayerError;
            },
          );
      await pumpUntil(tester, () => err != null);
      expect(err!.code, GiftErrorCode.engineLoadFailed);
      expect(err!.message, contains('libpag'));
      player.destroy();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PagPlatform.channel, (call) async {
            if (call.method == 'pagCreate') {
              throw PlatformException(
                code: 'parse-failed',
                message: 'corrupt pag',
              );
            }
            return null;
          });
      final p2 = GiftPlayer();
      GiftPlayerError? e2;
      p2
          .load(pagBytes())
          .then(
            (_) {},
            onError: (Object e) {
              e2 = e as GiftPlayerError;
            },
          );
      await pumpUntil(tester, () => e2 != null);
      expect(e2!.code, GiftErrorCode.parseFailed);
      p2.destroy();
    });

    testWidgets(
      'complex scripts in PAG text only warn (libpag cannot shape them)',
      (tester) async {
        final player = GiftPlayer();
        var loaded = false;
        player.load(pagBytes()).then((_) => loaded = true);
        await pumpUntil(tester, () => loaded);
        player.setText('#0', 'नमस्ते');
        await pumpUntil(
          tester,
          () => calls.any((c) => c.method == 'pagReplaceText'),
        );
        player.destroy();
      },
    );
  });

  test('the version constant matches pubspec.yaml', () {
    expect(giftPlayerVersion, '0.1.0');
  });
}
