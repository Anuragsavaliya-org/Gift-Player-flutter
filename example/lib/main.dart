import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:incodes_gift_player/incodes_gift_player.dart';

import 'synthetic_svga.dart';

void main() => runApp(const GiftDemoApp());

class GiftDemoApp extends StatelessWidget {
  const GiftDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Gift Player demo',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff6c4bff),
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const DemoPage(),
  );
}

/// One entry of the gift grid.
class Gift {
  Gift(this.name, this.format, this.source, {this.broken = false});
  final String name;
  final String format;
  final Object source;
  final bool broken;
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage>
    with SingleTickerProviderStateMixin {
  // The minimal integration is just this: a player, a surface, load + play. Everything else below is demo UI.
  final GiftPlayer _player = GiftPlayer(const GiftPlayerOptions());
  late GiftQueueController _queue;
  final List<void Function()> _queueOffs = [];

  late final AnimationController _bg = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();
  late final List<Gift> _gifts = [
    Gift('Spinning star', 'SVGA', spinningStar()),
    Gift('Bouncing heart', 'SVGA', bouncingHeart()),
    Gift('Rotating Earth', 'GIF', 'asset:assets/gifts/rotating-earth.gif'),
    Gift('Pulse heart', 'WEBP', 'asset:assets/gifts/pulse-heart.webp'),
    Gift('Like', 'PAG', 'asset:assets/gifts/like.pag'),
    Gift('Replacement', 'PAG', 'asset:assets/gifts/replacement.pag'),
  ];

  Gift? _selected;
  ({Gift gift, GiftInfo info, int loadMs})? _current;
  int _loops = 1;
  ContentMode _mode = ContentMode.aspectFit;
  int _priority = 0; // 0 = normal, 5 = high
  bool _coalesce = true;
  bool _paused = false;
  String _badge = '';
  final math.Random _rng = math.Random();
  Timer? _cacheTimer;

  @override
  void initState() {
    super.initState();
    _selected = _gifts.first;
    _player.onError.listen(_toast);
    _makeQueue();
    // The default cache is shared by every player and queue; its stats are cheap to read.
    _cacheTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  /// The coalesce switch recreates the queue (its options are read once, at construction).
  void _makeQueue() {
    for (final o in _queueOffs) {
      o();
    }
    _queueOffs.clear();
    _queue = GiftQueueController(
      queueOptions: GiftQueueOptions(
        maxLength: 60,
        preloadAhead: 2,
        coalesce: _coalesce,
      ),
    );
    _paused = false;
    _badge = '';
    final q = _queue.queue;
    String name(Object src) {
      for (final g in _gifts) {
        if (identical(g.source, src) || g.source == src) return g.name;
      }
      return '$src';
    }

    _queueOffs.addAll([
      _queue.player.onError.listen(_toast),
      // item-start carries `count`: how many identical sends were merged into this one ("combo")
      q.onItemStart.listen(
        (i) => setState(() => _badge = i.count > 1 ? '×${i.count}' : ''),
      ),
      q.onItemEnd.listen((_) => setState(() => _badge = '')),
      q.onItemError.listen(
        (e) => _toastText('${name(e.item.src)}: ${e.error.code.id}'),
      ),
      q.onItemDropped.listen(
        (e) => _toastText('${name(e.item.src)} dropped (${e.reason.name})'),
      ),
    ]);
  }

  @override
  void dispose() {
    _cacheTimer?.cancel();
    for (final o in _queueOffs) {
      o();
    }
    _bg.dispose();
    _queue.dispose();
    _player.destroy();
    super.dispose();
  }

  void _toast(GiftPlayerError e) {
    if (e.code == GiftErrorCode.aborted) return;
    _toastText(e.code.id);
  }

  void _toastText(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(text), backgroundColor: Colors.red.shade900),
      );
  }

  Future<void> _playOnStage(Gift g) async {
    setState(() => _selected = g);
    final sw = Stopwatch()..start();
    try {
      final info = await _player.load(
        g.source,
        options: LoadOptions(loops: _loops),
      );
      if (!mounted) return;
      setState(
        () => _current = (gift: g, info: info, loadMs: sw.elapsedMilliseconds),
      );
      await _player.play();
    } on GiftPlayerError catch (e) {
      if (e.code == GiftErrorCode.aborted) return;
      _toastText('${g.name}: ${e.code.id}');
    }
  }

  void _stopStage() {
    _player.stop();
    _player.clear();
  }

  void _send(Gift g, {int times = 1}) {
    // loops: 1 on purpose: a queue plays one gift at a time, so an endless gift would block everything behind it
    for (var i = 0; i < times; i++) {
      _queue.queue.add(g.source, priority: _priority, loops: 1);
    }
  }

  void _burst() {
    for (var i = 0; i < 20; i++) {
      _send(_gifts[_rng.nextInt(_gifts.length)]);
    }
  }

  void _togglePause() {
    if (_paused) {
      _queue.queue.resume();
    } else {
      _queue.queue.pause();
    }
    setState(() => _paused = !_paused);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gift Player demo')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'incodes_gift_player. Play a gift on the stage, or Send it to the live queue and simulate a busy chat.',
          ),
          const SizedBox(height: 12),
          _stage(),
          const SizedBox(height: 12),
          _controls(),
          const SizedBox(height: 12),
          _queuePanel(),
          const SizedBox(height: 12),
          _grid(),
          const SizedBox(height: 12),
          _infoPanel(),
        ],
      ),
    );
  }

  /// A fake live video: an animated gradient, so it is obvious that gifts are drawn with transparency over it. Two layers sit on
  /// top: the queue's player and the single-gift player.
  Widget _stage() => AspectRatio(
    aspectRatio: 3 / 4,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _bg,
            builder: (context, _) => DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-1 + 2 * _bg.value, -1),
                  end: Alignment(1 - 2 * _bg.value, 1),
                  colors: const [
                    Color(0xff0f2027),
                    Color(0xff2c5364),
                    Color(0xff6a3093),
                    Color(0xff0f2027),
                  ],
                ),
              ),
            ),
          ),
          const Positioned(
            top: 10,
            left: 12,
            child: Text(
              '● LIVE',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          GiftPlayerSurface(player: _queue.player),
          GiftPlayerSurface(player: _player),
          if (_badge.isNotEmpty)
            Positioned(
              top: 10,
              right: 12,
              child: Chip(
                label: Text(_badge),
                backgroundColor: Colors.amber.shade800,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _controls() {
    final mb = GiftPlayer.getCache().stats.bytes / 1048576;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Controls',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () {
                    final g = _selected;
                    if (g != null) _playOnStage(g);
                  },
                  child: const Text('▶ Play / replay'),
                ),
                OutlinedButton(
                  onPressed: _togglePause,
                  child: Text(_paused ? '⏵ Resume queue' : '⏸ Pause queue'),
                ),
                OutlinedButton(
                  onPressed: _stopStage,
                  child: const Text('■ Stop'),
                ),
              ],
            ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Loops'),
                DropdownButton<int>(
                  value: _loops,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1')),
                    DropdownMenuItem(value: 3, child: Text('3')),
                    DropdownMenuItem(value: 0, child: Text('infinite')),
                  ],
                  onChanged: (v) => setState(() => _loops = v ?? 1),
                ),
                const Text('Content mode'),
                DropdownButton<ContentMode>(
                  value: _mode,
                  items: [
                    for (final m in ContentMode.values)
                      DropdownMenuItem(value: m, child: Text(m.name)),
                  ],
                  onChanged: (m) {
                    if (m == null) return;
                    setState(() => _mode = m);
                    _player.setContentMode(m);
                    _queue.player.setContentMode(m);
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Cache: ${mb.toStringAsFixed(1)} MB'),
                OutlinedButton(
                  onPressed: () => GiftPlayer.getCache().clear(),
                  child: const Text('Clear cache'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _queuePanel() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Live stream',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Priority'),
              DropdownButton<int>(
                value: _priority,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('normal')),
                  DropdownMenuItem(value: 5, child: Text('high')),
                ],
                onChanged: (v) => setState(() => _priority = v ?? 0),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _coalesce,
                    onChanged: (v) => setState(() {
                      _coalesce = v ?? true;
                      final old = _queue;
                      _makeQueue();
                      old.dispose();
                    }),
                  ),
                  const Text('merge identical sends (coalesce)'),
                ],
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: _burst, child: const Text('Burst ×20')),
              FilledButton(
                onPressed: _selected == null
                    ? null
                    : () => _send(_selected!, times: 10),
                child: Text(
                  'Combo ×10 ${_selected == null ? '' : '(${_selected!.name})'}',
                ),
              ),
              OutlinedButton(
                onPressed: _queue.queue.clear,
                child: const Text('Clear waiting'),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'Each gift tile below also has a Send button that queues it once.',
            ),
          ),
          ValueListenableBuilder<GiftQueueState>(
            valueListenable: _queue.stats,
            builder: (context, s, _) => Text(
              'Waiting ${s.pending} · Playing ${s.playing ? 'yes' : 'no'} · Played ${s.played} · Errors ${s.failed} · Dropped ${s.dropped}',
            ),
          ),
        ],
      ),
    ),
  );

  Widget _grid() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final g in _gifts)
        SizedBox(
          width: 170,
          child: Card(
            shape: _selected == g
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(g.name, overflow: TextOverflow.ellipsis),
                      ),
                      Chip(
                        label: Text(g.format),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: g.broken ? Colors.red.shade900 : null,
                      ),
                    ],
                  ),
                  if (g.broken)
                    const Text(
                      'deliberately broken',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => _playOnStage(g),
                        child: const Text('Play'),
                      ),
                      TextButton(
                        onPressed: () => _send(g),
                        child: const Text('Send'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget _infoPanel() {
    final c = _current;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Current gift',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            if (c == null)
              const Text('Play a gift from the grid to see its details.')
            else ...[
              Text('Name: ${c.gift.name}'),
              Text('Format: ${c.info.format.name}'),
              Text('Size: ${c.info.width.toInt()} × ${c.info.height.toInt()}'),
              Text('Frames: ${c.info.frameCount}'),
              Text('Duration: ${c.info.durationMs.round()} ms'),
              Text('Load time: ${c.loadMs} ms (click to first frame)'),
              Text(
                'Editable keys: ${c.info.editableKeys.isEmpty ? 'none' : c.info.editableKeys.map((k) => '${k.key} (${k.type})').join(', ')}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
