import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import '../inflate.dart';
import '../zip.dart';
import 'media.dart';
import 'proto.dart';
import 'spec_json.dart';
import 'types.dart';
import 'wire.dart';

const int _defaultFps = 20;

/// Sanity limits so corrupt headers cannot trigger huge allocations.
const int _maxFrames = 100000;

/// Every frame is an object, so sprites x frames is a memory bound: 2M frame objects is already ~100+ MB.
const int _maxFrameEntries = 2000000;

bool _isZip(Uint8List b) =>
    b.length >= 4 && b[0] == 0x50 && b[1] == 0x4b && b[2] == 3 && b[3] == 4;

/// Parses an SVGA file (2.x protobuf, 1.x zip+JSON, or 1.5 zip+protobuf) into the version-independent [SvgaMovie]. Pure and
/// synchronous: no `dart:ui`; images stay raw bytes (see `decodeSvgaImages` for the decoding step).
///
/// [inflated] is the already inflated SVGA 2.x buffer from format detection, so the parser does not inflate twice.
///
/// Throws [GiftPlayerError] (`parse-failed`) for any corrupt or invalid input, including data that would inflate past
/// [maxInflatedBytes].
SvgaMovie parseSvga(
  Uint8List bytes, {
  Uint8List? inflated,
  int maxInflatedBytes = defaultMaxInflatedBytes,
}) {
  try {
    if (inflated != null) return _buildFromProto(inflated);
    if (_isZip(bytes)) return _parseZip(bytes, maxInflatedBytes);
    final Uint8List data;
    try {
      data = inflateCapped(bytes, maxBytes: maxInflatedBytes);
    } on InflateLimitError {
      rethrow;
    } catch (cause) {
      return parseFail(
        'Not a valid SVGA file: zlib inflate failed (file is corrupt, truncated, or not SVGA).',
        cause,
      );
    }
    return _buildFromProto(data);
  } on GiftPlayerError {
    rethrow;
  } catch (e) {
    // Anything else (RangeError, TypeError from malformed data, ...) is still a parse failure.
    return parseFail('SVGA parse failed: $e', e);
  }
}

SvgaMovie _buildFromProto(Uint8List inflated) {
  final raw = decodeMovieEntity(inflated);
  final warnings = <String>[];
  final images = <String, SvgaBinary>{};
  final audios = <String, SvgaBinary>{};
  raw.images.forEach((key, data) {
    final media = classifyMedia(data);
    if (media != null && media.isImage) {
      images[key] = SvgaBinary(data, media.mime);
    } else if (media != null) {
      audios[key] = SvgaBinary(data, media.mime);
    } else {
      warnings.add(
        'images["$key"]: ${data.length} bytes of unrecognised data dropped (not PNG/JPEG/WebP/audio).',
      );
    }
  });
  return _assemble(raw, SvgaContainer.protobuf, images, audios, warnings);
}

SvgaMovie _parseZip(Uint8List bytes, int max) {
  final Map<String, Uint8List> files;
  try {
    files = unzip(bytes, maxBytes: max);
  } on InflateLimitError {
    rethrow;
  } on GiftPlayerError catch (e) {
    return parseFail(e.message, e.cause);
  } catch (cause) {
    return parseFail(
      'Not a valid SVGA file: could not read the zip archive.',
      cause,
    );
  }
  final warnings = <String>[];
  final binary = files['movie.binary'];
  final spec = files['movie.spec'];
  if (binary == null && spec == null) {
    return parseFail('Zip archive has neither movie.binary nor movie.spec.');
  }

  if (binary != null) {
    try {
      return _buildFromZipProtobuf(binary, files, warnings, max);
    } catch (e) {
      if (spec == null || e is InflateLimitError) rethrow;
      warnings.add(
        'movie.binary could not be decoded (${e is GiftPlayerError ? e.message : e}); fell back to movie.spec.',
      );
    }
  }
  return _buildFromSpec(spec!, files, warnings);
}

/// 1.5: `movie.binary` is a MovieEntity (plain, or zlib-compressed) whose `images` values are file names.
SvgaMovie _buildFromZipProtobuf(
  Uint8List binary,
  Map<String, Uint8List> files,
  List<String> warnings,
  int max,
) {
  RawMovie raw;
  try {
    raw = decodeMovieEntity(binary);
  } catch (_) {
    raw = decodeMovieEntity(inflateCapped(binary, maxBytes: max));
  }
  final images = <String, SvgaBinary>{};
  final audios = <String, SvgaBinary>{};
  raw.images.forEach((key, value) {
    final media = classifyMedia(value);
    if (media != null && media.isImage) {
      images[key] = SvgaBinary(value, media.mime);
    } else if (media != null) {
      audios[key] = SvgaBinary(value, media.mime);
    } else {
      _addFromZip(
        key,
        utf8.decode(value, allowMalformed: true),
        files,
        images,
        audios,
        warnings,
      );
    }
  });
  return _assemble(raw, SvgaContainer.zipProtobuf, images, audios, warnings);
}

SvgaMovie _buildFromSpec(
  Uint8List specBytes,
  Map<String, Uint8List> files,
  List<String> warnings,
) {
  Object? json;
  try {
    json = jsonDecode(utf8.decode(specBytes, allowMalformed: true));
  } catch (cause) {
    return parseFail('movie.spec is not valid JSON.', cause);
  }
  final res = fromSpecJson(json);
  final images = <String, SvgaBinary>{};
  final audios = <String, SvgaBinary>{};
  res.imageNames.forEach(
    (key, name) => _addFromZip(key, name, files, images, audios, warnings),
  );
  for (final track in res.raw.audios) {
    if (audios.containsKey(track.audioKey)) continue;
    final data = files['${track.audioKey}.mp3'] ?? files[track.audioKey];
    final media = data == null ? null : classifyMedia(data);
    if (data != null && media != null && !media.isImage) {
      audios[track.audioKey] = SvgaBinary(data, media.mime);
    } else {
      warnings.add(
        'audio "${track.audioKey}" referenced by the spec was not found in the archive.',
      );
    }
  }
  return _assemble(res.raw, SvgaContainer.zipJson, images, audios, warnings);
}

/// Looks up an image by its file-name stem inside a 1.x zip (`<name>.png`, then bare name, then key).
void _addFromZip(
  String key,
  String name,
  Map<String, Uint8List> files,
  Map<String, SvgaBinary> images,
  Map<String, SvgaBinary> audios,
  List<String> warnings,
) {
  final data =
      files['$name.png'] ?? files[name] ?? files['$key.png'] ?? files[key];
  final media = data == null ? null : classifyMedia(data);
  if (data != null && media != null && media.isImage) {
    images[key] = SvgaBinary(data, media.mime);
  } else if (data != null && media != null) {
    audios[key] = SvgaBinary(data, media.mime);
  } else {
    warnings.add(
      'images["$key"]: file "$name" not found (or not an image) in the archive.',
    );
  }
}

const SvgaFrame _hiddenFrame = SvgaFrame(
  alpha: 0,
  layout: SvgaLayout.zero,
  transform: SvgaMatrix.identity,
  clipPath: '',
  shapes: <SvgaShape>[],
);

SvgaMovie _assemble(
  RawMovie raw,
  SvgaContainer container,
  Map<String, SvgaBinary> images,
  Map<String, SvgaBinary> audios,
  List<String> warnings,
) {
  final width = raw.viewBoxWidth;
  final height = raw.viewBoxHeight;
  if (!(width > 0) || !(height > 0)) {
    parseFail(
      'Invalid viewBox ${width}x$height: missing or non-positive size.',
    );
  }
  if (raw.frames <= 0) {
    parseFail('Movie has ${raw.frames} frames; nothing to play.');
  }
  if (raw.frames > _maxFrames) {
    parseFail(
      'Implausible frame count ${raw.frames} (limit $_maxFrames); file is likely corrupt.',
    );
  }
  if (raw.frames * raw.sprites.length > _maxFrameEntries) {
    parseFail(
      'Implausible size: ${raw.sprites.length} sprites x ${raw.frames} frames.',
    );
  }
  var fps = raw.fps;
  if (fps <= 0) {
    warnings.add('fps is $fps; defaulting to $_defaultFps.');
    fps = _defaultFps;
  }

  var padded = 0;
  var truncated = 0;
  final sprites = raw.sprites.map((s) {
    if (s.frames.length < raw.frames) {
      padded++;
    } else if (s.frames.length > raw.frames) {
      truncated++;
    }
    return _buildSprite(s, raw.frames);
  }).toList();
  if (padded > 0) {
    warnings.add(
      '$padded sprite(s) had fewer than ${raw.frames} frames; padded with hidden frames.',
    );
  }
  if (truncated > 0) {
    warnings.add(
      '$truncated sprite(s) had more than ${raw.frames} frames; extra frames dropped.',
    );
  }

  final missing = <String>{};
  for (final s in sprites) {
    if (s.imageKey.isNotEmpty &&
        !s.isMatte &&
        !s.imageKey.endsWith('.vector') &&
        !images.containsKey(s.imageKey)) {
      missing.add(s.imageKey);
    }
  }
  if (missing.isNotEmpty) {
    warnings.add('No image data for imageKey(s): ${missing.join(', ')}.');
  }

  // A matteKey whose mask sprite does not exist is kept as-is (renderers must ignore it).
  final keys = sprites.map((s) => s.imageKey).toSet();
  final dangling = {
    for (final s in sprites)
      if (s.matteKey != null && !keys.contains(s.matteKey)) s.matteKey!,
  };
  if (dangling.isNotEmpty) {
    warnings.add(
      'matteKey(s) with no matching mask sprite (ignore when rendering): ${dangling.join(', ')}.',
    );
  }

  return SvgaMovie(
    container: container,
    version: raw.version,
    viewBoxWidth: width,
    viewBoxHeight: height,
    fps: fps,
    frames: raw.frames,
    images: images,
    audios: audios,
    audioTracks: raw.audios,
    sprites: sprites,
    warnings: warnings,
  );
}

SvgaSprite _buildSprite(RawSprite s, int frameCount) {
  final frames = List<SvgaFrame>.filled(frameCount, _hiddenFrame);
  // KEEP = "same shapes as the previous frame" (per sprite). Resolved here; never exposed.
  List<SvgaShape> prev = const [];
  for (var i = 0; i < frameCount; i++) {
    if (i >= s.frames.length) {
      frames[i] = _hiddenFrame;
      prev = const [];
      continue;
    }
    final rf = s.frames[i];
    final List<SvgaShape> shapes;
    if (rf.shapes.isNotEmpty && rf.shapes[0].type == SvgaShapeType.keep) {
      shapes = prev;
    } else if (rf.shapes.any((sh) => sh.type == SvgaShapeType.keep)) {
      shapes = rf.shapes.where((sh) => sh.type != SvgaShapeType.keep).toList();
    } else {
      shapes = rf.shapes;
    }
    prev = shapes;
    frames[i] = rf.isDefault
        ? _hiddenFrame
        : SvgaFrame(
            alpha: rf.alpha,
            layout: rf.layout,
            transform: rf.transform,
            clipPath: rf.clipPath,
            shapes: shapes,
          );
  }
  return SvgaSprite(
    imageKey: s.imageKey,
    matteKey: s.matteKey.isEmpty ? null : s.matteKey,
    isMatte: s.imageKey.endsWith('.matte'),
    frames: frames,
  );
}
