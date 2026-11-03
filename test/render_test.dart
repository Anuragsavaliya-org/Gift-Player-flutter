import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:incodes_gift_player/incodes_gift_player.dart';
import 'package:incodes_gift_player/src/image/image_renderer.dart';
import 'package:incodes_gift_player/src/renderer.dart';
import 'package:incodes_gift_player/src/svga/svga_renderer.dart';

import 'helpers/synthetic.dart';

/// Paints [r] into a [w] x [h] box and returns the RGBA pixels.
Future<({Uint8List px, int w, int h})> snapshot(
  GiftRenderer r,
  int w,
  int h,
) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  r.paint(canvas, ui.Size(w.toDouble(), h.toDouble()));
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  return (px: data!.buffer.asUint8List(), w: w, h: h);
}

List<int> at(({Uint8List px, int w, int h}) s, int x, int y) {
  final i = (y * s.w + x) * 4;
  return [s.px[i], s.px[i + 1], s.px[i + 2], s.px[i + 3]];
}

SvgaRenderer rendererOf(
  Uint8List svga, {
  ContentMode mode = ContentMode.aspectFit,
}) {
  final movie = parseSvga(svga);
  return SvgaRenderer(movie, {}, contentMode: mode);
}

const red = [1.0, 0.0, 0.0, 1.0];
const green = [0.0, 1.0, 0.0, 1.0];

void main() {
  testWidgets(
    'SVGA: a vector rect is drawn where the viewBox says, nothing elsewhere',
    (tester) async {
      await tester.runAsync(() async {
        final r = rendererOf(
          svga2(
            frames: 1,
            sprites: [
              sprite('a.vector', [
                frame(shapes: [rectShape(10, 10, 20, 20, red)]),
              ]),
            ],
          ),
        );
        r.drawFrame(0);
        final s = await snapshot(r, 100, 100);
        expect(at(s, 20, 20), [255, 0, 0, 255]);
        expect(at(s, 80, 80)[3], 0);
        r.destroy();
      });
    },
  );

  testWidgets(
    'SVGA: nothing is painted before the first drawFrame and after clear()',
    (tester) async {
      await tester.runAsync(() async {
        final r = rendererOf(
          svga2(
            frames: 1,
            sprites: [
              sprite('a.vector', [
                frame(shapes: [rectShape(0, 0, 100, 100, red)]),
              ]),
            ],
          ),
        );
        expect(at(await snapshot(r, 50, 50), 25, 25)[3], 0);
        r.drawFrame(0);
        expect(at(await snapshot(r, 50, 50), 25, 25)[3], 255);
        r.clear();
        expect(r.hasFrame, isFalse);
        expect(at(await snapshot(r, 50, 50), 25, 25)[3], 0);
      });
    },
  );

  testWidgets('SVGA: frame alpha, transform and per-frame content', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final r = rendererOf(
        svga2(
          frames: 3,
          sprites: [
            sprite('a.vector', [
              frame(alpha: 0.5, shapes: [rectShape(0, 0, 10, 10, red)]),
              frame(
                transform: [1, 0, 0, 1, 50, 50],
                shapes: [rectShape(0, 0, 10, 10, red)],
              ),
              frame(alpha: 0),
            ]),
          ],
        ),
      );
      r.drawFrame(0);
      final a = at(await snapshot(r, 100, 100), 5, 5);
      expect(a[3], inInclusiveRange(126, 130));
      r.drawFrame(1);
      final b = await snapshot(r, 100, 100);
      expect(at(b, 5, 5)[3], 0);
      expect(at(b, 55, 55), [255, 0, 0, 255]);
      r.drawFrame(2);
      expect(at(await snapshot(r, 100, 100), 55, 55)[3], 0);
    });
  });

  testWidgets(
    'SVGA: a matte keeps only the masked part of the run (group masked once)',
    (tester) async {
      await tester.runAsync(() async {
        final r = rendererOf(
          svga2(
            frames: 1,
            sprites: [
              sprite('m.matte', [
                frame(
                  shapes: [
                    rectShape(0, 0, 50, 100, [0, 0, 0, 1]),
                  ],
                ),
              ]),
              sprite('a.vector', [
                frame(shapes: [rectShape(0, 0, 100, 100, green)]),
              ], matte: 'm.matte'),
            ],
          ),
        );
        r.drawFrame(0);
        final s = await snapshot(r, 100, 100);
        expect(at(s, 25, 50), [0, 255, 0, 255]);
        expect(at(s, 75, 50)[3], 0);
      });
    },
  );

  testWidgets(
    'SVGA: a dangling matteKey is ignored and the sprite is drawn normally',
    (tester) async {
      await tester.runAsync(() async {
        final r = rendererOf(
          svga2(
            frames: 1,
            sprites: [
              sprite('a.vector', [
                frame(shapes: [rectShape(0, 0, 100, 100, green)]),
              ], matte: 'ghost.matte'),
            ],
          ),
        );
        r.drawFrame(0);
        expect(at(await snapshot(r, 100, 100), 50, 50), [0, 255, 0, 255]);
      });
    },
  );

  testWidgets('SVGA: clip paths mask a sprite', (tester) async {
    await tester.runAsync(() async {
      final r = rendererOf(
        svga2(
          frames: 1,
          sprites: [
            sprite('a.vector', [
              frame(
                clip: 'M0 0 L50 0 L50 100 L0 100 Z',
                shapes: [rectShape(0, 0, 100, 100, green)],
              ),
            ]),
          ],
        ),
      );
      r.drawFrame(0);
      final s = await snapshot(r, 100, 100);
      expect(at(s, 25, 50)[3], 255);
      expect(at(s, 75, 50)[3], 0);
    });
  });

  testWidgets('SVGA: path, rounded rect and dashed stroke shapes draw', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dashed = Pb()
        ..varint(1, 1)
        ..msg(
          3,
          Pb()
            ..f32(1, 10)
            ..f32(2, 10)
            ..f32(3, 80)
            ..f32(4, 80)
            ..f32(5, 0),
        )
        ..msg(
          10,
          Pb()
            ..msg(
              2,
              Pb()
                ..f32(1, 1)
                ..f32(2, 0)
                ..f32(3, 0)
                ..f32(4, 1),
            )
            ..f32(3, 4)
            ..f32(7, 10)
            ..f32(8, 10)
            ..f32(9, 0),
        );
      final r = rendererOf(
        svga2(
          frames: 1,
          sprites: [
            sprite('a.vector', [
              frame(
                shapes: [
                  pathShape('M0 0 L100 0 L100 20 L0 20 Z', green),
                  rectShape(0, 60, 100, 40, red, radius: 20),
                  dashed,
                ],
              ),
            ]),
          ],
        ),
      );
      r.drawFrame(0);
      final s = await snapshot(r, 100, 100);
      expect(at(s, 50, 16), [0, 255, 0, 255]);
      expect(at(s, 15, 10), [255, 0, 0, 255]); // dash on
      expect(at(s, 25, 10), [0, 255, 0, 255]); // dash gap shows the path below
      expect(at(s, 50, 80)[0], 255);
      expect(at(s, 2, 62)[3], 0); // rounded corner is transparent
    });
  });

  testWidgets(
    'content modes: fit letterboxes, fill stretches, fill-aspect crops',
    (tester) async {
      await tester.runAsync(() async {
        Future<({Uint8List px, int w, int h})> shot(ContentMode m) async {
          final r = rendererOf(
            svga2(
              frames: 1,
              sprites: [
                sprite('a.vector', [
                  frame(shapes: [rectShape(0, 0, 100, 100, red)]),
                ]),
              ],
            ),
            mode: m,
          );
          r.drawFrame(0);
          return snapshot(r, 200, 100);
        }

        final fit = await shot(ContentMode.aspectFit);
        expect(at(fit, 10, 50)[3], 0); // left letterbox bar
        expect(at(fit, 100, 50)[3], 255);
        final fill = await shot(ContentMode.fill);
        expect(at(fill, 10, 50)[3], 255);
        final crop = await shot(ContentMode.aspectFill);
        expect(at(crop, 10, 50)[3], 255);
        expect(at(crop, 199, 99)[3], 255);
      });
    },
  );

  testWidgets(
    'SVGA: text replacement draws, is cleared and unknown keys are ignored',
    (tester) async {
      await tester.runAsync(() async {
        final r = rendererOf(
          svga2(
            frames: 1,
            sprites: [
              sprite('name', [
                frame(layout: [0, 0, 100, 40]),
              ]),
            ],
          ),
        );
        r.drawFrame(0);
        r.setText(
          'name',
          'Hello',
          const GiftTextStyle(size: 30, color: Color(0xffff0000)),
        );
        final s = await snapshot(r, 100, 100);
        var any = false;
        for (var y = 0; y < 40 && !any; y++) {
          for (var x = 0; x < 100; x++) {
            if (at(s, x, y)[3] > 0) {
              any = true;
              break;
            }
          }
        }
        expect(any, isTrue);
        r.clearReplacement('name');
        final c = await snapshot(r, 100, 100);
        expect(c.px.every((b) => b == 0), isTrue);
        r.setText('nope', 'x'); // warns, never throws
        r.setHidden('nope', true);
      });
    },
  );

  testWidgets('SVGA: image replacement (bytes) and hiding', (tester) async {
    await tester.runAsync(() async {
      final movie = parseSvga(
        svga2(
          frames: 1,
          images: {'pic': tinyPng},
          sprites: [
            sprite('pic', [
              frame(layout: [0, 0, 100, 100]),
            ]),
          ],
        ),
      );
      final decoded = await decodeSvgaImages(movie);
      expect(decoded.failed, isEmpty);
      final r = SvgaRenderer(movie, decoded.bitmaps);
      r.drawFrame(0);
      expect(
        at(await snapshot(r, 100, 100), 50, 50)[3],
        greaterThan(0),
      ); // original bitmap
      r.setHidden('pic', true);
      expect(at(await snapshot(r, 100, 100), 50, 50)[3], 0);
      r.setHidden('pic', false);
      await r.setImage(
        'pic',
        tinyPng,
        const GiftImageOptions(fit: GiftImageFit.contain),
      );
      expect(at(await snapshot(r, 100, 100), 50, 50)[3], greaterThan(0));
      expect(r.getEditableKeys().map((k) => k.key), ['pic']);
      r.destroy();
      expect(decoded.bitmaps, isEmpty); // owned images were disposed
    });
  });

  testWidgets('SVGA: a shared bitmap map is left alone on destroy', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final movie = parseSvga(
        svga2(
          frames: 1,
          images: {'pic': tinyPng},
          sprites: [
            sprite('pic', [
              frame(layout: [0, 0, 10, 10]),
            ]),
          ],
        ),
      );
      final decoded = await decodeSvgaImages(movie);
      SvgaRenderer(movie, decoded.bitmaps, sharedImages: true).destroy();
      expect(decoded.bitmaps, isNotEmpty);
      releaseSvgaImages(decoded.bitmaps);
    });
  });

  testWidgets(
    'GIF: frames decode through the platform codec with the container timing',
    (tester) async {
      await tester.runAsync(() async {
        final r = await AnimatedImageRenderer.create(gifOf([10, 20], loops: 0));
        expect(r.frameCount, 2);
        expect(r.frameDuration(0), 100);
        expect(r.frameDuration(1), 200);
        expect(r.loopCount, 0);
        expect(r.size, const ui.Size(2, 2));
        r.drawFrame(0);
        final f0 = at(await snapshot(r, 2, 2), 0, 0);
        r.drawFrame(1);
        await r.ready(1);
        r.drawFrame(1);
        final f1 = at(await snapshot(r, 2, 2), 0, 0);
        expect(f0, [0, 0, 0, 255]);
        expect(f1, [255, 255, 255, 255]);
        expect(r.supportsReplacement, isFalse);
        r.destroy();
      });
    },
  );

  testWidgets('GIF: random access wraps around the codec correctly', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final r = await AnimatedImageRenderer.create(
        gifOf([10, 10, 10]),
        maxCacheBytes: 1,
      ); // force the streaming window
      for (final i in [2, 0, 1, 0, 2]) {
        await r.ready(i);
        r.drawFrame(i);
        final c = at(await snapshot(r, 2, 2), 0, 0);
        expect(c[0], i.isEven ? 0 : 255, reason: 'frame $i');
      }
      r.destroy();
    });
  });

  testWidgets('a still image is shown for staticDurationMs once', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final r = await AnimatedImageRenderer.create(
        gifOf([5]),
        staticDurationMs: 1234,
      );
      expect(r.frameCount, 1);
      expect(r.frameDuration(0), 1234);
      expect(r.loopCount, 1);
      r.destroy();
    });
  });

  testWidgets('not a GIF/WebP is rejected', (tester) async {
    await tester.runAsync(() async {
      await expectLater(
        AnimatedImageRenderer.create(svga2(frames: 1, sprites: [])),
        throwsA(isA<GiftPlayerError>()),
      );
    });
  });
}
