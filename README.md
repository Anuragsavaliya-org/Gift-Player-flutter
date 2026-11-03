# incodes_gift_player

Play animated gift files through one API on **Android and iOS**: **SVGA** (1.x and 2.x), **GIF**, **animated and static WebP**, and **PAG**. A queue for live streams, a cache, text and picture replacement, typed errors.

This is the Flutter port of the web package [`@incodes/gift-player`](https://github.com/Anuragsavaliya-org/Gift-Player) 0.1.0 and follows its API and behaviour. [PARITY.md](PARITY.md) compares the two feature by feature and says what has and has not been verified.

```yaml
dependencies:
  incodes_gift_player: ^0.1.0
```

* Flutter 3.44+, Dart 3.12+, Android `minSdk 24`, iOS 13+.
* No Dart dependencies besides Flutter. Native: [libpag](https://github.com/Tencent/libpag) 4.5.85 (Apache-2.0) for PAG only.

## Quick start

### Declarative (like `<GiftPlayerView>`)

```dart
SizedBox(
  width: 360,
  height: 360,
  child: GiftPlayerView(
    src: 'https://cdn.example.com/rocket.svga', // SVGA, GIF, WebP or PAG: detected from the bytes
    replacements: {'name': Replacement.text('Rahul', style: GiftTextStyle(size: 40, color: Colors.white))},
    onEnd: () => debugPrint('done'),
  ),
)
```

Changing `src` reloads (the load in flight is aborted), changing `replacements` updates in place, disposing destroys the player.

### Imperative

```dart
final player = GiftPlayer();
// anywhere in build(): SizedBox(width: 360, height: 360, child: GiftPlayerSurface(player: player))
await player.load('https://cdn.example.com/rocket.svga');
await player.play();   // completes when the gift has ended
player.destroy();
```

The surface is transparent: a finished gift disappears (`clearOnEnd: false` keeps the last frame), so it never stays frozen on top of your video.

### Queue (live streams)

```dart
final c = GiftQueueController(queueOptions: const GiftQueueOptions(maxLength: 50, preloadAhead: 2, coalesce: true));
c.queue.onItemStart.listen((i) => badge.show(i.count));                         // "x10" combo badge when identical gifts are merged
c.queue.onItemError.listen((e) => debugPrint('${e.item.src} ${e.error.code}')); // a broken gift is skipped
c.queue.add('https://cdn.example.com/rocket.svga', priority: 5, replacements: {'name': Replacement.text('Rahul')});
// show it:   GiftPlayerSurface(player: c.player)      live numbers: c.stats (ValueListenable)
// when done: c.dispose()
```

One gift at a time; higher `priority` first, first come first served within a priority. When `maxLength` waiting gifts are queued, the lowest priority (oldest first) is dropped (`onItemDropped`, reason `overflow`). The next `preloadAhead` gifts are fetched, parsed and decoded while the current one plays. Each gift plays once unless you pass `loops` (`0` = forever) or `defaultLoops`.

## Sources

`load()` / `add()` / `preload()` take a `String`, a `GiftSource`, or the file's bytes:

| source | meaning | cached |
|---|---|---|
| `'https://…'` / `GiftSource.url` | fetched over HTTP(S) | yes |
| `'file:///…'` / `GiftSource.file` | file on the device | yes |
| `'asset:assets/gifts/a.svga'` / `GiftSource.asset` | Flutter asset | yes |
| `'scheme:ref'` | teach a scheme with `registerResolver('gift', (id, signal) => 'https://cdn/$id.svga')`, then `load('gift:12345')`; the resolver returns a URL or the bytes | yes (keyed by the resolved URL, or the reference for bytes) |
| `Uint8List` / `GiftSource.bytes` | the file itself | no |

## Formats

| format | how it is played |
|---|---|
| SVGA 1.x / 2.x | parsed and drawn by this package in Dart (`dart:ui` canvas): shapes, mattes, clip paths, text and image replacement. The same code on Android and iOS. Files over 64 KB are parsed in a background isolate. |
| GIF, WebP (animated and still) | container timing and loop count read by this package, pixels decoded by the platform codec. |
| PAG | libpag renders natively (Android: OpenGL ES, iOS: Metal) into a Flutter texture. Text and image layers can be replaced. |

## Replacements

```dart
final info = await player.load(url, options: LoadOptions(replacements: {
  'name': Replacement.text('Rahul', style: GiftTextStyle(size: 40, color: Colors.white)),
  'avatar': Replacement.image(avatarBytes),          // ui.Image, encoded bytes, or a URL / file:// / asset: string
  'banner': Replacement.hidden(true),
}));
info.editableKeys;                                    // [EditableKey(avatar, image), EditableKey(banner, vector), ...]
player.setText('name', 'Anurag');                     // later, no reload; survives seeking and looping
await player.setImage('avatar', bytes, options: GiftImageOptions(fit: GiftImageFit.cover));
player.setHidden('banner', true);
player.clearReplacement('name');
```

* SVGA keys are the sprite image keys; PAG keys are the editable layer name, or `#<index>` when the name is empty or ambiguous.
* Replacements passed to `load()` are applied **before the first frame**, so the original text never flashes.
* Unknown keys log a warning and are ignored; they never throw. GIF and WebP have nothing to replace (warning).
* Custom fonts: `await registerFont('MyFont', ttfBytes)` makes a font available to SVGA text (Flutter's text engine) and PAG text (libpag, which names the font by the family *inside* the file).
* CSS colour strings from the web API are available as `parseCssColor('#ff8800')`; styles take Flutter `Color`s.

## Cache and preload

Loaded gifts (fetched, parsed, images decoded) live in an LRU cache with a budget in **estimated decoded bytes** (default 64 MB; `GiftPlayer.setCacheBudget(bytes)`). A gift any player is showing is never evicted, and two players showing the same gift share one set of decoded images.

```dart
await GiftPlayer.preload(['https://cdn.example.com/a.svga', 'asset:assets/b.pag']); // never throws; a later load() is instant
GiftPlayer.getCache().stats;   // bytes, maxBytes, entries, inUse, hits, misses, evictions, disposed, loading
```

Pass `GiftPlayerOptions(cache: AssetCache<LoadedGift>(maxBytes: …))` for a private cache.

## Errors

Everything fails with a `GiftPlayerError`; `error.code` is a `GiftErrorCode`:

| code | meaning |
|---|---|
| `unsupportedFormat` | not SVGA / GIF / WebP / PAG, or the platform cannot run it |
| `invalidInput` | wrong argument type or an unknown source string, `play()` before `load()` |
| `network` | fetch/read failed (offline, HTTP error, missing file or asset) or a registered resolver failed |
| `parseFailed` | corrupt container, or newer than the parser supports |
| `decodeFailed` | parsed, but the pixels could not be decoded |
| `engineLoadFailed` | the native PAG engine could not be loaded or started |
| `aborted` | cancelled by an `AbortSignal`, a newer `load()`, `stop()` or `destroy()` (not reported through `onError`) |

Events (`player.onX.listen(fn)` returns the function that unsubscribes): `onLoaded`, `onStart`, `onLoop`, `onEnd`, `onError`, `onFrame` (only produced while a listener exists). Queue: `onItemBegin`, `onItemStart`, `onItemEnd`, `onItemError`, `onItemDropped`, `onChange`, `onIdle`.

## Lifecycle and platform notes

* `pauseWhenHidden` (default true): the gift pauses when the app goes to the background and continues from the same frame.
* Flutter lays the view out, so there are no `devicePixelRatio` / `observeResize` options: give `GiftPlayerSurface` / `GiftPlayerView` a size.
* No runtime permissions are needed. Gifts fetched over the network need the `INTERNET` permission in your app's Android manifest (Flutter adds it for debug builds only: add `<uses-permission android:name="android.permission.INTERNET"/>` for release), and plain `http://` URLs need cleartext traffic enabled on Android and an App Transport Security exception on iOS.
* iOS uses CocoaPods (libpag ships no Swift package); the pod is a static framework.

## Known limitations

* **PAG text cannot shape complex scripts** (same as the web package): libpag draws text glyph by glyph, so Hindi / Gujarati marks come out misplaced and Arabic is drawn in isolated forms. Latin, CJK and emoji are fine. `setText` on a PAG gift logs one warning when the text needs shaping. SVGA text is drawn by Flutter's text engine and shapes correctly: use SVGA for personalised names in those scripts.
* A replaced PAG picture cannot be restored to the original (libpag has no API for it): set another image.
* A GIF or WebP that loops forever never ends: `play()` stays pending (the queue plays each gift once by default for this reason).
* A gift that is still playing when you call `load()` keeps playing until the new one is ready; a gift that has ended is already gone.
* Flutter cannot unload a font, so `registerFont` returns nothing to undo it.
* Web-only concepts that do not exist here: `releasePagEngineContext` (no shared WebGL context; each PAG gift owns its texture and frees it on destroy) and `setPagFallbackFonts` (libpag's mobile SDKs choose fallback fonts themselves; register your own font with `registerFont`).
* **Verification status** is in [PARITY.md](PARITY.md#verification): the Dart side is covered by 88 automated tests and SVGA, GIF, WebP and PAG (including text/image replacement) have been run on a real Android phone (release build). The iOS side (Swift plugin, podspec, Metal PAG rendering) is written against the libpag headers but has **not been compiled or run yet**: please report iOS problems in the issue tracker.

## Third-party runtime code

* PAG playback uses [libpag](https://github.com/Tencent/libpag) 4.5.85 (Apache-2.0), pulled in as `com.tencent.tav:libpag` (Android) and the `libpag` pod (iOS). Keep its license and notice when you ship it.
* The example's `rotating-earth.gif` (CC BY-SA 3.0) and `like.pag`, `replacement.pag` (Apache-2.0): see [example/README.md](example/README.md).
