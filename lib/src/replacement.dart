import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Horizontal alignment of replacement text inside the layer's layout rect.
enum GiftTextAlign { left, center, right }

/// How a replacement image fills the layout rect: `fill` stretches (like the original bitmap), `cover` crops, `contain` letterboxes.
enum GiftImageFit { fill, cover, contain }

/// Text styling for `setText`; shared by SVGA and PAG (same fields as the web `TextStyle`).
class GiftTextStyle {
  const GiftTextStyle({
    this.font,
    this.size,
    this.weight,
    this.color,
    this.align,
    this.stroke,
  });

  /// Font family. Default `sans-serif`. A comma separated list ("Arial, sans-serif") uses the first as family and the rest as fallbacks.
  final String? font;

  /// Size in viewBox units (SVGA) / composition pixels (PAG). Default 14.
  final double? size;

  /// `'bold'`, `'normal'`, or a number such as `700`.
  final Object? weight;

  /// Default black.
  final Color? color;

  /// Alignment inside the layer's layout rect. Default centre.
  final GiftTextAlign? align;
  final GiftTextStroke? stroke;
}

class GiftTextStroke {
  const GiftTextStroke({required this.color, required this.width});
  final Color color;
  final double width;
}

/// Options for `setImage`.
class GiftImageOptions {
  const GiftImageOptions({this.fit = GiftImageFit.fill});

  /// How the image fills the layout rect. Default [GiftImageFit.fill].
  final GiftImageFit fit;
}

/// One replacement, applied before the first frame when passed to `load()`.
sealed class Replacement {
  const Replacement();

  /// Replaces a text layer's text.
  const factory Replacement.text(String text, {GiftTextStyle? style}) =
      TextReplacement;

  /// Replaces a layer's picture. [image] is a [ui.Image] (never disposed by the plugin), encoded bytes ([Uint8List]: PNG/JPEG/WebP),
  /// or a `String` (http(s) URL, `file://`, or `asset:`).
  const factory Replacement.image(Object image, {GiftImageOptions? options}) =
      ImageReplacement;

  /// Hides (or shows) a layer.
  const factory Replacement.hidden(bool hidden) = HiddenReplacement;
}

class TextReplacement extends Replacement {
  const TextReplacement(this.text, {this.style});
  final String text;
  final GiftTextStyle? style;
}

class ImageReplacement extends Replacement {
  const ImageReplacement(this.image, {this.options});
  final Object image;
  final GiftImageOptions? options;
}

class HiddenReplacement extends Replacement {
  const HiddenReplacement(this.hidden);
  final bool hidden;
}

/// Replacements by key (`getEditableKeys()` lists the keys).
typedef Replacements = Map<String, Replacement>;

/// A layer / sprite whose content can be replaced with `setText` / `setImage` (the same shape for every format).
class EditableKey {
  const EditableKey({
    required this.key,
    required this.type,
    this.index,
    this.name,
  });

  /// Pass this to `setText` / `setImage` / `setHidden`. For PAG it is the layer name, or `#<index>` when the name is empty or ambiguous.
  final String key;

  /// `'text'`, `'image'` or `'vector'`.
  final String type;

  /// PAG: the editable index. SVGA: null.
  final int? index;

  /// PAG: the layer name (may be empty). SVGA: same as [key].
  final String? name;

  @override
  String toString() => 'EditableKey($key, $type)';
}

/// Parses a CSS colour string: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()`, `hsl()/hsla()`, `transparent`, and the
/// common named colours. Returns null if it cannot be parsed (the web package paints an invalid colour black).
Color? parseCssColor(String css) {
  final s = css.trim().toLowerCase();
  if (s.isEmpty) return null;
  if (s == 'transparent') return const Color(0x00000000);
  if (s.startsWith('#')) {
    var h = s.substring(1);
    if (h.length == 3 || h.length == 4) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if (h.length != 6 && h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    if (v == null) return null;
    return h.length == 6
        ? Color(0xff000000 | v)
        : Color(((v & 0xff) << 24) | (v >> 8));
  }
  final m = RegExp(r'^(rgba?|hsla?)\(([^)]*)\)$').firstMatch(s);
  if (m != null) {
    final parts = m
        .group(2)!
        .split(RegExp(r'[,\s/]+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.length < 3) return null;
    double? num(String t) =>
        double.tryParse(t.endsWith('%') ? t.substring(0, t.length - 1) : t);
    final a = parts.length > 3
        ? (parts[3].endsWith('%')
              ? (num(parts[3]) ?? 100) / 100
              : (num(parts[3]) ?? 1))
        : 1.0;
    if (m.group(1)!.startsWith('rgb')) {
      double ch(String t) =>
          t.endsWith('%') ? (num(t) ?? 0) * 2.55 : (num(t) ?? 0);
      return Color.fromRGBO(
        ch(parts[0]).round().clamp(0, 255),
        ch(parts[1]).round().clamp(0, 255),
        ch(parts[2]).round().clamp(0, 255),
        a.clamp(0.0, 1.0),
      );
    }
    final hue = num(parts[0].replaceAll('deg', '')) ?? 0;
    final sat = (num(parts[1]) ?? 0) / 100;
    final light = (num(parts[2]) ?? 0) / 100;
    return HSLColor.fromAHSL(
      a.clamp(0.0, 1.0),
      ((hue % 360) + 360) % 360,
      sat.clamp(0.0, 1.0),
      light.clamp(0.0, 1.0),
    ).toColor();
  }
  final named = _namedColors[s];
  return named == null ? null : Color(0xff000000 | named);
}

const Map<String, int> _namedColors = {
  'black': 0x000000,
  'white': 0xffffff,
  'red': 0xff0000,
  'green': 0x008000,
  'blue': 0x0000ff,
  'yellow': 0xffff00,
  'cyan': 0x00ffff,
  'aqua': 0x00ffff,
  'magenta': 0xff00ff,
  'fuchsia': 0xff00ff,
  'gray': 0x808080,
  'grey': 0x808080,
  'silver': 0xc0c0c0,
  'maroon': 0x800000,
  'olive': 0x808000,
  'lime': 0x00ff00,
  'teal': 0x008080,
  'navy': 0x000080,
  'purple': 0x800080,
  'orange': 0xffa500,
  'pink': 0xffc0cb,
  'gold': 0xffd700,
  'brown': 0xa52a2a,
  'violet': 0xee82ee,
  'indigo': 0x4b0082,
  'crimson': 0xdc143c,
  'coral': 0xff7f50,
  'salmon': 0xfa8072,
  'tomato': 0xff6347,
  'khaki': 0xf0e68c,
  'turquoise': 0x40e0d0,
  'tan': 0xd2b48c,
  'beige': 0xf5f5dc,
  'ivory': 0xfffff0,
  'lavender': 0xe6e6fa,
  'orchid': 0xda70d6,
  'skyblue': 0x87ceeb,
  'steelblue': 0x4682b4,
  'royalblue': 0x4169e1,
  'hotpink': 0xff69b4,
  'deeppink': 0xff1493,
  'darkred': 0x8b0000,
  'darkgreen': 0x006400,
  'darkblue': 0x00008b,
  'lightgray': 0xd3d3d3,
  'lightgrey': 0xd3d3d3,
  'darkgray': 0xa9a9a9,
  'darkgrey': 0xa9a9a9,
  'whitesmoke': 0xf5f5f5,
  'gainsboro': 0xdcdcdc,
};

/// Builds a Flutter [FontWeight] from a CSS-like weight (`'bold'`, `'normal'`, `700`, `'600'`).
FontWeight? fontWeightOf(Object? weight) {
  if (weight == null) return null;
  if (weight is FontWeight) return weight;
  final s = weight.toString().toLowerCase();
  if (s == 'bold') return FontWeight.w700;
  if (s == 'normal') return FontWeight.w400;
  final n = int.tryParse(s);
  if (n == null) return null;
  final i = ((n.clamp(100, 900)) / 100).round() - 1;
  return FontWeight.values[i.clamp(0, 8)];
}
