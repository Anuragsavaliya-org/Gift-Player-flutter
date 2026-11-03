# incodes_gift_player example

A one-page demo of the plugin: a stage with an animated "live video" background (so you can see gifts rendering with transparency over video), a grid of gifts, a queue panel (Send, Burst x20, Combo x10, priority), a controls row (play/pause/stop, loops, content mode, replacement name, clear cache with MB used), an info panel (format, size, frames, duration, editable keys, load time) and a snackbar for typed errors (try "Broken file").

```sh
cd example
flutter pub get
flutter run            # Android device/emulator or iOS simulator
```

`lib/main.dart` keeps the minimal integration obvious: a `GiftPlayer`, a `GiftPlayerSurface`, `load()` and `play()`; `MinimalExample` at the bottom is the declarative `GiftPlayerView` version.

## Gifts

* **Spinning star** and **Bouncing heart** (SVGA) are built in code by `lib/synthetic_svga.dart`: no third-party artwork is shipped. The star has an editable `name` text layer (change the "Name" field), the heart uses a matte layer.
* `assets/gifts/rotating-earth.gif`: CC BY-SA 3.0, by Marvel (Wikimedia Commons), based on a NASA Visible Earth image: https://commons.wikimedia.org/wiki/File:Rotating_earth_(large).gif
* `assets/gifts/like.pag`, `replacement.pag`: from https://github.com/Tencent/libpag (`assets/`), Apache-2.0, Copyright (C) Tencent.
* **Broken file** is random bytes: it demonstrates `unsupportedFormat` and that the queue skips it.

To use your own gifts, put files in `assets/gifts/` (they are already declared in `pubspec.yaml`) and add an entry with `'asset:assets/gifts/<file>'`, or pass a `https://` URL.
