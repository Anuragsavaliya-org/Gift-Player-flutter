# Changelog

## 0.1.0

First release: a Flutter port of `@incodes/gift-player` 0.1.0 for Android and iOS.

* SVGA 1.x / 2.x (parsed and drawn in Dart: shapes, mattes, clip paths, text and image replacement), GIF, animated and static WebP
  (platform codec), PAG (native libpag 4.5.85 rendered into a Flutter texture).
* `GiftPlayer`, `GiftQueue`, `AssetCache`, resolvers, `preload`, typed errors, events.
* Widgets: `GiftPlayerView`, `GiftPlayerSurface`, `GiftQueueController`.

Known limitation: the iOS plugin has not been compiled or run on a device yet (Android has: SVGA, GIF, WebP and PAG play on a real phone).
