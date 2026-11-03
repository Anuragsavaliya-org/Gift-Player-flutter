import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:incodes_gift_player/incodes_gift_player.dart';
import 'package:incodes_gift_player/src/image/meta.dart';
import 'package:incodes_gift_player/src/frame_clock.dart';
import 'package:incodes_gift_player/src/replacement.dart' show parseCssColor;
import 'package:incodes_gift_player/src/widgets/gift_player_view.dart' show diffReplacements;
import 'package:incodes_gift_player/src/inflate.dart';
import 'package:incodes_gift_player/src/svga/svg_path.dart';

import 'helpers/synthetic.dart';

Uint8List _simpleSvga() => svga2(
  frames: 4,
  images: {'img': tinyPng},
  sprites: [
    sprite('img', [
      frame(layout: [0, 0, 10, 10], transform: [1, 0, 0, 1, 0, 0]),
      frame(layout: [0, 0, 10, 10], transform: [1, 0, 0, 1, 5, 0]),
      frame(alpha: 0),
      frame(layout: [0, 0, 10, 10], transform: [1, 0, 0, 1, 0, 0]),
    ]),
  ],
);

void main() {
  group('detectFormat', () {
    test('recognises every format from magic bytes', () {
      expect(detectFormat(gifOf([5, 5], loops: 0)).format, GiftFormat.gif);
      final webp = detectFormat(webpAnimOf([20, 20]));
      expect(webp.format, GiftFormat.webp);
      expect(webp.animated, isTrue);
      expect(
        detectFormat(Uint8List.fromList(ascii.encode('PAG\x01rest'))).format,
        GiftFormat.pag,
      );
      final svga = detectFormat(_simpleSvga());
      expect(svga.format, GiftFormat.svga);
      expect(svga.version, '2.x');
      final one = detectFormat(
        svga1(
          spec: {
            'ver': '1.1.0',
            'movie': {
              'viewBox': {'width': 1, 'height': 1},
              'fps': 20,
              'frames': 1,
            },
            'images': {},
            'sprites': [],
          },
        ),
      );
      expect(one.version, '1.x');
    });

    test('a zip without movie.spec/movie.binary is unsupported', () {
      expect(
        () => detectFormat(
          zipOf({
            'a.txt': [1, 2, 3],
          }),
        ),
        throwsA(
          isA<GiftPlayerError>().having(
            (e) => e.code,
            'code',
            GiftErrorCode.unsupportedFormat,
          ),
        ),
      );
    });

    test(
      'garbage and empty input are unsupported-format, never an uncaught error',
      () {
        for (final bytes in [
          Uint8List(0),
          Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]),
        ]) {
          expect(
            () => detectFormat(bytes),
            throwsA(
              isA<GiftPlayerError>().having(
                (e) => e.code,
                'code',
                GiftErrorCode.unsupportedFormat,
              ),
            ),
          );
        }
      },
    );

    test('a decompression bomb is parse-failed, not unsupported', () {
      final bomb = Uint8List.fromList(zlib.encode(Uint8List(2 * 1024 * 1024)));
      expect(
        () => detectFormat(bomb, maxInflatedBytes: 1024 * 1024),
        throwsA(
          isA<GiftPlayerError>().having(
            (e) => e.code,
            'code',
            GiftErrorCode.parseFailed,
          ),
        ),
      );
    });
  });

  group('inflateCapped', () {
    test('round-trips and enforces the cap', () {
      final data = Uint8List.fromList(List.generate(100000, (i) => i % 251));
      expect(inflateCapped(Uint8List.fromList(zlib.encode(data))), data);
      expect(
        () => inflateCapped(
          Uint8List.fromList(zlib.encode(data)),
          maxBytes: 1000,
        ),
        throwsA(isA<InflateLimitError>()),
      );
    });
  });

  group('parseSvga (2.x protobuf)', () {
    test('parses viewBox, fps, frames, images and sprites', () {
      final m = parseSvga(_simpleSvga());
      expect(m.viewBoxWidth, 100);
      expect(m.fps, 10);
      expect(m.frames, 4);
      expect(m.images.keys, ['img']);
      expect(m.images['img']!.mime, 'image/png');
      expect(m.sprites.single.frames.length, 4);
      expect(m.sprites.single.frames[1].transform.tx, 5);
      expect(m.sprites.single.frames[2].alpha, 0);
      expect(m.container, SvgaContainer.protobuf);
    });

    test('KEEP shapes repeat the previous frame and are never exposed', () {
      final m = parseSvga(
        svga2(
          frames: 3,
          sprites: [
            sprite('a.vector', [
              frame(
                shapes: [
                  rectShape(0, 0, 5, 5, [1, 0, 0, 1]),
                ],
              ),
              frame(shapes: [keepShape()]),
              frame(shapes: [keepShape()]),
            ]),
          ],
        ),
      );
      final shapes = m.sprites.single.frames.map((f) => f.shapes).toList();
      expect(shapes[1], hasLength(1));
      expect(shapes[2].single.type, SvgaShapeType.rect);
      expect(
        m.sprites.single.frames
            .expand((f) => f.shapes)
            .any((s) => s.type == SvgaShapeType.keep),
        isFalse,
      );
    });

    test('short sprites are padded with hidden frames and a warning', () {
      final m = parseSvga(
        svga2(
          frames: 3,
          sprites: [
            sprite('a.vector', [
              frame(
                shapes: [
                  rectShape(0, 0, 5, 5, [1, 0, 0, 1]),
                ],
              ),
            ]),
          ],
        ),
      );
      expect(m.sprites.single.frames, hasLength(3));
      expect(m.sprites.single.frames[2].alpha, 0);
      expect(m.warnings.any((w) => w.contains('padded')), isTrue);
    });

    test('matte sprites and dangling matteKeys are preserved', () {
      final m = parseSvga(
        svga2(
          frames: 1,
          sprites: [
            sprite('m.matte', [frame()]),
            sprite('a.vector', [frame()], matte: 'm.matte'),
            sprite('b.vector', [frame()], matte: 'ghost.matte'),
          ],
        ),
      );
      expect(m.sprites[0].isMatte, isTrue);
      expect(m.sprites[1].matteKey, 'm.matte');
      expect(m.warnings.any((w) => w.contains('ghost.matte')), isTrue);
    });

    test('audio in the images map is kept apart from images', () {
      final mp3 = [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0];
      final m = parseSvga(
        svga2(frames: 1, images: {'snd': mp3, 'img': tinyPng}, sprites: []),
      );
      expect(m.audios.keys, ['snd']);
      expect(m.images.keys, ['img']);
    });

    test('rejects corrupt and implausible files with parse-failed', () {
      GiftPlayerError? err;
      try {
        parseSvga(Uint8List.fromList([1, 2, 3, 4]));
      } on GiftPlayerError catch (e) {
        err = e;
      }
      expect(err?.code, GiftErrorCode.parseFailed);
      expect(
        () => parseSvga(svga2(frames: 0, sprites: [])),
        throwsA(isA<GiftPlayerError>()),
      );
      expect(
        () => parseSvga(svga2(w: 0, frames: 1, sprites: [])),
        throwsA(isA<GiftPlayerError>()),
      );
    });

    test('truncated protobuf is parse-failed', () {
      final raw = zlib.decode(_simpleSvga());
      final cut = Uint8List.fromList(
        zlib.encode(raw.sublist(0, raw.length - 7)),
      );
      expect(
        () => parseSvga(cut),
        throwsA(
          isA<GiftPlayerError>().having(
            (e) => e.code,
            'code',
            GiftErrorCode.parseFailed,
          ),
        ),
      );
    });
  });

  group('parseSvga (1.x zip + JSON)', () {
    final spec = {
      'ver': '1.1.0',
      'movie': {
        'viewBox': {'width': 50, 'height': 60},
        'fps': 15,
        'frames': 2,
      },
      'images': {'pic': 'pic'},
      'sprites': [
        {
          'imageKey': 'pic',
          'frames': [
            {
              'alpha': 1,
              'layout': {'x': 0, 'y': 0, 'width': 10, 'height': 10},
              'transform': {'a': 1, 'b': 0, 'c': 0, 'd': 1, 'tx': 3, 'ty': 4},
            },
            {
              'alpha': 0.5,
              'layout': {'x': 0, 'y': 0, 'width': 10, 'height': 10},
            },
          ],
        },
        {
          'imageKey': 'shape.vector',
          'frames': [
            {
              'alpha': 1,
              'shapes': [
                {
                  'type': 'rect',
                  'args': {
                    'x': 1,
                    'y': 2,
                    'width': 3,
                    'height': 4,
                    'cornerRadius': 1,
                  },
                  'styles': {
                    'fill': [1, 0, 0, 1],
                    'lineDash': [2, 1, 0],
                    'stroke': [0, 0, 0, 1],
                    'strokeWidth': 1,
                  },
                },
              ],
            },
            {
              'alpha': 1,
              'shapes': [
                {'type': 'keep'},
              ],
            },
          ],
        },
      ],
    };

    test('parses the spec (movie.spec last or first in the archive)', () {
      for (final first in [false, true]) {
        final m = parseSvga(
          svga1(spec: spec, pngs: {'pic': tinyPng}, specFirst: first),
        );
        expect(m.container, SvgaContainer.zipJson);
        expect(m.viewBoxHeight, 60);
        expect(m.fps, 15);
        expect(m.images['pic']!.data, tinyPng);
        // missing transform = identity, missing numbers = 0
        expect(m.sprites[0].frames[1].transform.a, 1);
        expect(m.sprites[0].frames[0].transform.tx, 3);
        final shape = m.sprites[1].frames[0].shapes.single;
        expect(shape.type, SvgaShapeType.rect);
        expect(shape.style!.dash, 2);
        expect(m.sprites[1].frames[1].shapes, hasLength(1)); // keep resolved
      }
    });

    test('a missing image is a warning, not a failure', () {
      final m = parseSvga(svga1(spec: spec));
      expect(m.images, isEmpty);
      expect(m.warnings.any((w) => w.contains('pic')), isTrue);
    });
  });

  group('SVG path parser', () {
    test('absolute and relative commands give the same bounds', () {
      final a = parseSvgPath('M10 10 L30 10 L30 40 Z').getBounds();
      final r = parseSvgPath('m10 10 l20 0 l0 30 z').getBounds();
      expect(a, r);
      expect(a.left, 10);
      expect(a.right, 30);
      expect(a.bottom, 40);
    });

    test('H V C S Q T and implicit repeats parse', () {
      final b = parseSvgPath(
        'M0 0 H10 V10 H0 Z M20 20 C 20 30 30 30 30 20 S 40 10 40 20 Q 45 25 50 20 T 60 20',
      ).getBounds();
      expect(b.right, closeTo(60, 0.01));
      final implicit = parseSvgPath('M0 0 10 0 10 10').getBounds();
      expect(implicit.width, 10);
      expect(implicit.height, 10);
    });

    test('compact numbers and arcs with glued flags', () {
      expect(parseSvgPath('M0,0L-.5.5').getBounds().left, -0.5);
      final arc = parseSvgPath(
        'M0 0a5 5 0 1010 0',
      ).getBounds(); // flags "1","0" glued to 10
      expect(arc.width, closeTo(10, 0.01));
      expect(arc.height, greaterThan(4));
    });

    test('garbage never throws and returns what was parsed', () {
      expect(parseSvgPath('').getBounds().isEmpty, isTrue);
      expect(parseSvgPath('M10 10 L20 20 Q bogus').getBounds().right, 20);
      expect(parseSvgPath('xyz').getBounds().isEmpty, isTrue);
    });
  });

  group('CSS colours', () {
    test('hex, rgb, hsl, names', () {
      expect(parseCssColor('#fff')!.toARGB32(), 0xffffffff);
      expect(parseCssColor('#ff000080')!.toARGB32(), 0x80ff0000);
      expect(parseCssColor('rgb(0, 128, 255)')!.toARGB32(), 0xff0080ff);
      expect(parseCssColor('rgba(0,0,0,0.5)')!.a, closeTo(0.5, 0.01));
      expect(parseCssColor('hsl(0, 100%, 50%)')!.toARGB32(), 0xffff0000);
      expect(parseCssColor('red')!.toARGB32(), 0xffff0000);
      expect(parseCssColor('nonsense'), isNull);
    });
  });

  group('GIF / WebP metadata', () {
    test('GIF delays are clamped (<=10ms -> 100ms) and loops normalised', () {
      final m = readGifMeta(gifOf([0, 1, 2, 10], loops: 0));
      expect(m.durations, [100, 100, 20, 100]);
      expect(m.loopCount, 0);
      expect(readGifMeta(gifOf([5, 5], loops: 2)).loopCount, 3);
      expect(readGifMeta(gifOf([5, 5])).loopCount, 1);
      expect(readGifMeta(gifOf([5])).animated, isFalse);
    });

    test('WebP durations, loops and still handling', () {
      final m = readWebpMeta(webpAnimOf([0, 50, 200], loops: 3));
      expect(m.frameCount, 3);
      expect(m.durations, [100, 50, 200]);
      expect(m.loopCount, 3);
      expect(readWebpMeta(webpAnimOf([30], loops: 0)).loopCount, 0);
    });

    test('corrupt containers are parse-failed', () {
      expect(
        () => readGifMeta(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<GiftPlayerError>()),
      );
      expect(
        () => readWebpMeta(Uint8List.fromList(List.filled(30, 0))),
        throwsA(isA<GiftPlayerError>()),
      );
    });
  });

  group('FrameClock', () {
    // A manual clock: callbacks run when we call tick().
    FrameClock make({
      required int frames,
      required List<int> log,
      double fps = 10,
      int loops = 1,
      void Function()? onEnd,
      required List<void Function(Duration)> pending,
      required double Function() now,
    }) {
      var handle = 0;
      return FrameClock(
        frames: frames,
        fps: fps,
        loops: loops,
        onFrame: log.add,
        onEnd: onEnd,
        raf: (cb) {
          pending.add(cb);
          return ++handle;
        },
        caf: (_) => pending.clear(),
        now: now,
      );
    }

    test('plays frames in order at fps and ends once', () {
      final log = <int>[];
      final pending = <void Function(Duration)>[];
      var t = 0.0;
      var ended = 0;
      final c = make(
        frames: 4,
        log: log,
        pending: pending,
        now: () => t,
        onEnd: () => ended++,
      );
      c.play();
      for (var k = 0; k < 6; k++) {
        t += 100;
        if (pending.isEmpty) break;
        final cb = pending.removeLast();
        cb(Duration(milliseconds: t.toInt()));
      }
      expect(log.take(4).toList(), [0, 1, 2, 3]);
      expect(ended, 1);
      expect(c.playing, isFalse);
    });

    test('skips frames when the app falls behind, keeping total duration', () {
      final log = <int>[];
      final pending = <void Function(Duration)>[];
      var t = 0.0;
      final c = make(frames: 10, log: log, pending: pending, now: () => t);
      c.play();
      t = 5; // first frame callback establishes the start
      pending.removeLast()(Duration.zero);
      t = 505; // 500ms later: frame 5
      pending.removeLast()(Duration.zero);
      expect(log.last, 5);
      expect(log, isNot(contains(3)));
    });

    test('loops and counts them; 0 loops = forever', () {
      final log = <int>[];
      final pending = <void Function(Duration)>[];
      var t = 0.0;
      var ended = 0;
      final c = make(
        frames: 2,
        log: log,
        loops: 2,
        pending: pending,
        now: () => t,
        onEnd: () => ended++,
      );
      c.play();
      for (var k = 0; k < 8; k++) {
        t += 100;
        if (pending.isEmpty) break;
        pending.removeLast()(Duration.zero);
      }
      expect(log, containsAllInOrder([0, 1, 0, 1]));
      expect(ended, 1);

      final forever = make(
        frames: 2,
        log: <int>[],
        loops: 0,
        pending: pending,
        now: () => t,
      );
      forever.play();
      for (var k = 0; k < 50; k++) {
        t += 100;
        pending.removeLast()(Duration.zero);
      }
      expect(forever.playing, isTrue);
    });

    test(
      'pause keeps the position and resume continues without catching up',
      () {
        final log = <int>[];
        final pending = <void Function(Duration)>[];
        var t = 0.0;
        final c = make(frames: 10, log: log, pending: pending, now: () => t);
        c.play();
        t = 1;
        pending.removeLast()(Duration.zero);
        t = 301;
        pending.removeLast()(Duration.zero);
        final at = log.last;
        c.pause();
        t = 100000; // a long time passes while paused
        c.play();
        t = 100001;
        pending.removeLast()(Duration.zero);
        expect(c.frame, closeTo(at, 1));
      },
    );

    test('per-frame durations and seek', () {
      final log = <int>[];
      final pending = <void Function(Duration)>[];
      var t = 0.0;
      final c = FrameClock(
        frames: 3,
        frameDuration: (i) => [100.0, 400.0, 100.0][i],
        onFrame: log.add,
        raf: (cb) {
          pending.add(cb);
          return 1;
        },
        caf: (_) {},
        now: () => t,
      );
      expect(c.duration, 600);
      c.seek(2);
      expect(log.last, 2);
      c.seek(99); // clamped
      expect(log.last, 2);
    });
  });

  group('AssetCache', () {
    CacheLoaded<String> loaded(String v, int bytes, List<String> disposed) =>
        CacheLoaded(asset: v, bytes: bytes, dispose: () => disposed.add(v));

    test(
      'shares one load, counts hits, evicts LRU idle assets over budget',
      () async {
        final disposed = <String>[];
        final cache = AssetCache<String>(maxBytes: 100);
        var loads = 0;
        Future<CacheLoaded<String>> load(String k) async {
          loads++;
          return loaded(k, 60, disposed);
        }

        final futures = await Future.wait([
          cache.acquire('a', (_) => load('a')),
          cache.acquire('a', (_) => load('a')),
        ]);
        expect(loads, 1);
        expect(futures.first.asset, 'a');
        futures.first.release();
        futures.last.release();
        await cache.acquire('b', (_) => load('b')).then((l) => l.release());
        expect(disposed, ['a']); // 120 > 100: oldest idle goes
        expect(cache.has('a'), isFalse);
        expect(cache.stats.evictions, 1);
        expect(cache.stats.hits, 1);
      },
    );

    test('an asset in use is never evicted', () async {
      final disposed = <String>[];
      final cache = AssetCache<String>(maxBytes: 10);
      final lease = await cache.acquire(
        'a',
        (_) async => loaded('a', 60, disposed),
      );
      cache.setMaxBytes(1);
      expect(disposed, isEmpty);
      lease.release();
      expect(disposed, ['a']);
    });

    test(
      'a failed load is not cached and is reported to every waiter',
      () async {
        final cache = AssetCache<String>();
        var n = 0;
        Future<CacheLoaded<String>> bad(AbortSignal _) async {
          n++;
          throw GiftPlayerError(GiftErrorCode.network, 'boom');
        }

        await expectLater(
          cache.acquire('x', bad),
          throwsA(isA<GiftPlayerError>()),
        );
        await expectLater(
          cache.acquire('x', bad),
          throwsA(isA<GiftPlayerError>()),
        );
        expect(n, 2);
      },
    );

    test('the load is aborted only when every requester has aborted', () async {
      final cache = AssetCache<String>();
      var signalFired = false;
      final gate = Future<void>.delayed(const Duration(milliseconds: 50));
      Future<CacheLoaded<String>> slow(AbortSignal s) async {
        s.onAbort(() => signalFired = true);
        await gate;
        return CacheLoaded(asset: 'v', bytes: 1, dispose: () {});
      }

      final c1 = AbortController(), c2 = AbortController();
      final f1 = cache.acquire('k', slow, signal: c1.signal);
      final f2 = cache.acquire('k', slow, signal: c2.signal);
      c1.abort();
      await expectLater(
        f1,
        throwsA(
          isA<GiftPlayerError>().having(
            (e) => e.code,
            'code',
            GiftErrorCode.aborted,
          ),
        ),
      );
      expect(signalFired, isFalse);
      final l = await f2;
      expect(l.asset, 'v');
    });
  });

  group('sources and resolvers', () {
    test('GiftSource.from normalises strings and bytes', () {
      expect(GiftSource.from('https://x/y.svga'), isA<GiftUrlSource>());
      expect(GiftSource.from('asset:gifts/a.svga'), isA<GiftAssetSource>());
      expect(GiftSource.from('file:///tmp/a.svga'), isA<GiftFileSource>());
      expect(GiftSource.from(Uint8List(3)), isA<GiftBytesSource>());
      expect(
        () => GiftSource.from('nonsense'),
        throwsA(
          isA<GiftPlayerError>().having(
            (e) => e.code,
            'code',
            GiftErrorCode.invalidInput,
          ),
        ),
      );
      expect(() => GiftSource.from(42), throwsA(isA<GiftPlayerError>()));
    });

    test('reserved schemes cannot be registered', () {
      for (final s in [
        'http',
        'https',
        'file',
        'asset',
        'data',
        'blob',
        '1bad',
      ]) {
        expect(
          () => registerResolver(s, (r, _) => r),
          throwsA(isA<GiftPlayerError>()),
        );
      }
    });
  });

  group('replacement diffing', () {
    test('only differences are applied', () {
      final prev = {
        'a': const Replacement.text('x'),
        'b': const Replacement.hidden(true),
        'c': const Replacement.text('c'),
      };
      final next = {
        'a': const Replacement.text('y'),
        'b': const Replacement.hidden(true),
        'd': const Replacement.hidden(false),
      };
      final d = diffReplacements(prev, next);
      expect(d.changed.map((e) => e.key), ['a', 'd']);
      expect(d.cleared, ['c']);
    });
  });
}
