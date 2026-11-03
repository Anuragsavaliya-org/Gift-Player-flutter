import 'dart:ui' as ui;

/// How a gift fits its box (same names as the web package).
///
/// * [fill]: stretch to the box, ignoring aspect ratio.
/// * [aspectFit]: uniform scale so everything is visible, centred (letterbox).
/// * [aspectFill]: uniform scale so the box is covered, centred (overflow is cropped).
enum ContentMode { fill, aspectFit, aspectFill }

/// Maps content units to box pixels: `x' = sx * x + ox`, `y' = sy * y + oy`.
class GiftView {
  const GiftView(this.sx, this.sy, this.ox, this.oy);
  final double sx, sy, ox, oy;
}

/// Content-mode transform from a content rectangle ([contentWidth] x [contentHeight]) into a box.
GiftView computeView(
  ContentMode mode,
  double boxWidth,
  double boxHeight,
  double contentWidth,
  double contentHeight,
) {
  final kx = boxWidth / contentWidth;
  final ky = boxHeight / contentHeight;
  if (mode == ContentMode.fill) return GiftView(kx, ky, 0, 0);
  final k = mode == ContentMode.aspectFit
      ? (kx < ky ? kx : ky)
      : (kx > ky ? kx : ky);
  return GiftView(
    k,
    k,
    (boxWidth - contentWidth * k) / 2,
    (boxHeight - contentHeight * k) / 2,
  );
}

/// Applies [computeView] to a canvas (translate + scale) after clipping to the box.
void applyView(
  ui.Canvas canvas,
  ui.Size box,
  double contentWidth,
  double contentHeight,
  ContentMode mode,
) {
  canvas.clipRect(ui.Offset.zero & box);
  final v = computeView(
    mode,
    box.width,
    box.height,
    contentWidth,
    contentHeight,
  );
  canvas.translate(v.ox, v.oy);
  canvas.scale(v.sx, v.sy);
}
