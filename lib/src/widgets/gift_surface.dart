import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../player.dart';
import '../renderer.dart';

/// Shows whatever a [GiftPlayer] is playing. Give it a size (wrap it in a `SizedBox` / `Expanded` / `AspectRatio`): it fills its
/// constraints and fits the gift inside them according to the player's `contentMode`.
///
/// It is transparent: a finished gift disappears (`clearOnEnd`), and gifts render over whatever is behind the widget (a video, a
/// live stream, ...).
class GiftPlayerSurface extends StatefulWidget {
  const GiftPlayerSurface({super.key, required this.player});

  final GiftPlayer player;

  @override
  State<GiftPlayerSurface> createState() => _GiftPlayerSurfaceState();
}

class _GiftPlayerSurfaceState extends State<GiftPlayerSurface> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        final size = c.biggest;
        if (size.isFinite && !size.isEmpty) {
          final px = ui.Size(size.width * dpr, size.height * dpr);
          // Report the size after layout (the PAG surface is sized in physical pixels).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.player.updateViewSize(px);
          });
        }
        return ValueListenableBuilder<GiftRenderer?>(
          valueListenable: widget.player.surface,
          builder: (context, renderer, _) {
            if (renderer == null) return const SizedBox.expand();
            return RepaintBoundary(
              child: _RendererView(
                key: ObjectKey(renderer),
                renderer: renderer,
              ),
            );
          },
        );
      },
    );
  }
}

class _RendererView extends StatelessWidget {
  const _RendererView({super.key, required this.renderer});

  final GiftRenderer renderer;

  @override
  Widget build(BuildContext context) {
    final texture = renderer.textureId;
    if (texture != null) {
      return ListenableBuilder(
        listenable: renderer.repaint,
        builder: (context, _) => renderer.hasFrame
            ? Texture(textureId: texture)
            : const SizedBox.expand(),
      );
    }
    return CustomPaint(
      painter: _GiftPainter(renderer),
      size: Size.infinite,
      isComplex: true,
      willChange: true,
    );
  }
}

class _GiftPainter extends CustomPainter {
  _GiftPainter(this.renderer) : super(repaint: renderer.repaint);

  final GiftRenderer renderer;

  @override
  void paint(Canvas canvas, Size size) => renderer.paint(canvas, size);

  @override
  bool shouldRepaint(_GiftPainter old) => !identical(old.renderer, renderer);
}
