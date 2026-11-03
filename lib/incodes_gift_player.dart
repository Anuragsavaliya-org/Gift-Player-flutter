/// Play animated gift files through one API: **SVGA** (1.x and 2.x), **GIF**, **animated and static WebP**, and **PAG**.
///
/// Flutter port of the `@incodes/gift-player` web package: [GiftPlayer] (load / play / pause / replace text and images), [GiftQueue]
/// (priorities, preloading, combos), an [AssetCache], and the widgets [GiftPlayerView], [GiftPlayerSurface] and [GiftQueueController].
library;

// Players and queue
export 'src/player.dart'
    show
        GiftPlayer,
        GiftPlayerOptions,
        LoadOptions,
        GiftInfo,
        PreloadResult,
        PreloadStatus,
        getDefaultCache;
export 'src/queue.dart'
    show
        GiftQueue,
        GiftQueueOptions,
        QueueHandle,
        QueueItemStatus,
        DropReason,
        QueueItemInfo,
        QueueItemEnd,
        QueueItemError,
        QueueItemDropped,
        QueueChange,
        QueueStats;

// Widgets
export 'src/widgets/gift_player_view.dart'
    show
        GiftPlayerView,
        GiftQueueController,
        GiftQueueState;
export 'src/widgets/gift_surface.dart' show GiftPlayerSurface;

// Cache and sources
export 'src/cache.dart'
    show AssetCache, CacheLoaded, CacheStats, Lease, defaultCacheBytes;
export 'src/asset.dart'
    show LoadedGift, SourceResolver, registerResolver;
export 'src/source.dart'
    show
        GiftSource,
        GiftUrlSource,
        GiftFileSource,
        GiftAssetSource,
        GiftBytesSource,
        readSource,
        detectSource;
export 'src/abort.dart' show AbortController, AbortSignal;

// Errors, detection, fonts, events
export 'src/errors.dart' show GiftPlayerError, GiftErrorCode;
export 'src/detect.dart' show detectFormat, FormatInfo, GiftFormat;
export 'src/fonts.dart' show registerFont;
export 'src/emitter.dart' show GiftEvent;

// Shared types
export 'src/replacement.dart'
    show
        Replacement,
        TextReplacement,
        ImageReplacement,
        HiddenReplacement,
        Replacements,
        GiftTextStyle,
        GiftTextStroke,
        GiftTextAlign,
        GiftImageOptions,
        GiftImageFit,
        EditableKey;
export 'src/viewport.dart' show ContentMode;

// Advanced building blocks (unstable: not covered by semver)
export 'src/svga/parse.dart' show parseSvga;
export 'src/svga/types.dart';
export 'src/svga/decode_images.dart'
    show decodeSvgaImages, releaseSvgaImages, DecodedSvgaImages;

/// The version of this plugin (a test checks it equals `pubspec.yaml`).
const String giftPlayerVersion = '0.1.0';
