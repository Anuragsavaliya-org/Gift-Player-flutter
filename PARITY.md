# Web vs Flutter: feature parity

Reference: `@incodes/gift-player` 0.1.0 (the web package). Status legend: **same** = same behaviour, **adapted** = same behaviour through a platform-natural API, **n/a** = a web-only concept with no meaning on mobile.

## Public API

| Web | Flutter | Status |
|---|---|---|
| `new GiftPlayer(container, options)` | `GiftPlayer(GiftPlayerOptions)` + `GiftPlayerSurface(player:)` widget (the container is a widget) | adapted |
| options `contentMode`, `loops`, `clearOnEnd`, `pauseWhenHidden`, `cache`, `staticDurationMs` | same names in `GiftPlayerOptions` | same |
| options `devicePixelRatio`, `observeResize` | not needed: Flutter lays the view out and knows the pixel ratio | n/a |
| options `pagModuleUrl`, `pagWasmUrl`, `pagModule` | not needed: libpag is a native dependency, not downloaded at runtime | n/a |
| `load(src, {replacements, signal, loops, clearOnEnd})` → `GiftInfo` | `load(src, options: LoadOptions(...))` → `GiftInfo` | same |
| `GiftInfo {format,width,height,frameCount,durationMs,editableKeys}` | same fields | same |
| `play() pause() resume() stop() clear() seek(frame)` | same | same |
| `lastSwapMs`, `playing`, `current` | same | same |
| `setContentMode(mode)` | same | same |
| `setText / setImage / setHidden / clearReplacement / getEditableKeys` | same | same |
| `on('loaded' \| 'start' \| 'loop' \| 'end' \| 'error' \| 'frame', fn)` / `off` | `player.onLoaded / onStart / onLoop / onEnd / onError / onFrame` → `listen(fn)` returns the unsubscribe; `GiftEvent.remove(fn)`; `onFrame` is only produced while someone listens | adapted |
| `GiftPlayer.preload(srcs)` | same (`PreloadResult` with `PreloadStatus.cached / skipped / failed`) | same |
| `GiftPlayer.registerResolver / getCache / setCacheBudget` | same (static) and top-level `registerResolver` | same |
| `GiftQueue(player, options)` + `add / pause / resume / clear / skip / destroy / length / isPlaying / stats` | same; plus `isPaused` | same |
| queue options `maxLength, preloadAhead, coalesce, defaultLoops` | same | same |
| `add(src, {priority, replacements, loops})` → handle `{id,status,count,cancel(),done}` | same | same |
| queue events `item-begin / item-start / item-end / item-error / item-dropped / change / idle` | `onItemBegin … onIdle` | adapted |
| `AssetCache`, `CacheStats`, `Lease`, `DEFAULT_CACHE_BYTES` | same (`defaultCacheBytes`) | same |
| `GiftPlayerError` + 7 error codes | same 7 codes as `GiftErrorCode` (`.id` gives the kebab-case string) | same |
| `detectFormat(bytes)` | same | same |
| `detectSource(src)` (`/advanced`) | `detectSource(src)` | same |
| `registerFont(family, data)` → unregister fn | `registerFont(family, bytes)`; Flutter cannot unload fonts, so no unregister | adapted |
| `setPagFallbackFonts`, `releasePagEngineContext` | — | n/a (WebGL/browser fonts) |
| `AbortSignal` | `AbortController` / `AbortSignal` (same shape) | same |
| `GiftSource` = URL \| ArrayBuffer \| Blob | `String` (http(s) / `file://` / `asset:` / `scheme:ref`), `GiftSource`, `Uint8List` | adapted |
| `parseSvga`, `decodeSvgaImages`, `releaseSvgaImages`, SVGA types (`/advanced`) | exported from the main library (documented as unstable) | same |
| React `<GiftPlayerView>` | `GiftPlayerView` widget (same props: `src replacements loops contentMode autoPlay clearOnEnd onLoad onEnd onError playerOptions`) | same |
| React `useGiftQueue()` → `{queue, containerRef, stats}` | `GiftQueueController` → `{player, queue, stats}` | adapted |

## Formats and rendering

| Web | Flutter | Status |
|---|---|---|
| SVGA 2.x (zlib + protobuf), 1.x (zip + JSON), 1.5 (zip + protobuf) parser, `KEEP` shapes, padded/truncated frames, dangling `matteKey`, audio kept apart, size limits (`maxInflatedBytes`, frame limits) | ported line by line (`lib/src/svga/*`, `zip.dart`, `inflate.dart`) | same |
| SVGA drawing on Canvas 2D: bitmaps, path/rect/ellipse shapes, fill/stroke/caps/joins/miter/dash, per-sprite clip path, alpha, mattes composited once per run | `dart:ui` canvas: same draw list, `saveLayer` + `dstIn` for mattes, own SVG path parser and dash code | same algorithm, different canvas |
| SVGA text replacement (font, size, weight, colour, align, stroke, squeeze to the layout width) | same options (`GiftTextStyle`), drawn with Flutter's text engine | same |
| SVGA image replacement with `fill / cover / contain` | same | same |
| GIF/WebP: delays ≤ 10 ms → 100 ms, loop count normalised (GIF N+1, WebP N), still image shown `staticDurationMs`, look-ahead decoding | same rules; pixels come from `dart:ui`'s codec instead of `ImageDecoder` / the built-in LZW decoder | adapted |
| PAG via libpag (WASM + WebGL), driven frame by frame by the clock | libpag 4.5.85 native (Android GL / iOS Metal) into a Flutter texture, driven frame by frame by the same clock | adapted |
| PAG editable text / image / hide, `#index` keys, ambiguous names, ordinary text layers by name, complex-script warning | same logic (Dart) over a thin native bridge | same |
| Frame clock with skipping, `loops`, pause/resume without catching up, seek | `FrameClock`, same algorithm, driven by Flutter frame callbacks | same |
| Asset cache: LRU by decoded bytes, leases, shared loads, abort only when all requesters gave up | `AssetCache`, same algorithm | same |
| Pause when the page is hidden | pause when the app is paused/hidden (`AppLifecycleState`) | adapted |
| ArrayBuffer/Blob sources are not cached | `Uint8List` sources are not cached | same |

## Verification

Run on this Windows machine (Flutter 3.44.9). "Not run" means exactly that: the code is written but nothing has executed it.

| What | Result |
|---|---|
| `flutter analyze` (library, tests, example) | no issues |
| `flutter test`: 88 tests | **all pass**. Real pixel checks for SVGA (shapes, alpha, transforms, mattes, clip, dash, text, image replacement, content modes) and GIF (frames, wrap-around access) through the engine's real codec; the parsers (2.x, 1.x, corrupt/truncated/bomb inputs); the clock; the cache; the player (events, abort, stop, pause, loops, replacements); the queue (priority, coalesce, overflow, failure skipping, cancel, skip, pause, preload); the widgets |
| PAG Dart logic | tested against a **mocked** method channel (key mapping, frame→progress, text document edits and restore, image bytes, hidden, scale mode, view resize, dispose, error mapping). The real native engine was not involved |
| Android: `flutter build apk --debug` of the example | **builds**; the Kotlin plugin compiles against the real `com.tencent.tav:libpag:4.5.85` and `libpag.so` is in the APK (arm64-v8a, armeabi-v7a, x86_64) |
| Android: Kotlin unit tests (`testDebugUnitTest`) | 3 pass (dispatcher only) |
| Android: PAG playing on a device | **run** on a V2214 phone (release build): `like.pag` (244x244, 28 frames) and `replacement.pag` (800x800, 60 frames) load and play. A release build first crashed in `libpag.so` `JNI_OnLoad` because R8 removed libpag's Java classes; fixed with `android/consumer-rules.pro` (keep `org.libpag.**`) |
| iOS: Swift plugin and podspec | **not compiled, not run**: iOS builds need macOS/Xcode. The code was written against the libpag Objective-C headers (v4.5.x) and mirrors the Android implementation, but Swift's import renaming of those headers (e.g. `getLayers(byName:)`) could not be checked here |
| iOS: SVGA/GIF/WebP | pure Dart / `dart:ui`: identical code to Android, but **not run on iOS** |
| `integration_test/` (example) | written to run on a device/emulator; **not run** |

## Public surface

Only what the web package exports is exported (plus the platform adaptations above). Internal helpers (`parseCssColor`, `diffReplacements`, `FrameClock`, `GiftRenderer`, `GiftLease`) are not exported. The example app mirrors `examples/web-demo`, except that the real SVGA/WebP sample files were not available on this machine, so it uses two synthetic SVGA gifts plus the GIF and PAG samples.

## Decisions that differ from the web package

* The SVGA renderer draws every sprite with one `Paint` alpha per draw operation, exactly like `globalAlpha` on a canvas (overlapping shapes inside one sprite are not flattened first, in both implementations).
* The web package decodes SVGA images through `<img>` for better downscaling; Flutter uses `FilterQuality.medium` (mip-mapped) for the same reason.
* `play()` returns a `Future` that fails with `aborted` when stopped/replaced/destroyed (the promise rejection of the web package). A failed future nobody awaits is marked as handled internally, so it never surfaces as an uncaught error.
* A registered resolver is raced against the abort signal, so aborting a load never waits for a resolver that ignores the signal (the web package waits for it).
