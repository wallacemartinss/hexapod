import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';

import '../../core/link/robot_api.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../brand/brand.dart';

const _bg = Brand.navy;
const _card = Brand.card;
const _rec = Color(0xFFFF5A5F);

Future<void> showGalleryScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GalleryScreen()));

/// Saves a downloaded file into the phone's gallery (album "Hexapod").
typedef GallerySaver = Future<void> Function(File file, {required bool video});

Future<void> _saveToPhone(File file, {required bool video}) async {
  if (!await Gal.hasAccess()) await Gal.requestAccess();
  video ? await Gal.putVideo(file.path, album: 'Hexapod') : await Gal.putImage(file.path, album: 'Hexapod');
}

/// "mm:ss" (or "h:mm:ss").
String formatClip(int seconds) {
  final h = seconds ~/ 3600, m = seconds % 3600 ~/ 60, s = seconds % 60;
  final mmss = '${m.toString().padLeft(h > 0 ? 2 : 1, '0')}:${s.toString().padLeft(2, '0')}';
  return h > 0 ? '$h:$mmss' : mmss;
}

/// "1.2 MB", "850 KB".
String formatBytes(int bytes) =>
    bytes >= 1 << 20 ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';

/// Photos and recordings stored on the robot: download them to the phone's
/// gallery (over the robot's Wi-Fi or Tailscale) or delete them; and the
/// camera quality.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key, this.saver = _saveToPhone});

  final GallerySaver saver;

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  MediaStatus? _status;
  bool _failed = false;
  String? _quality;
  final _selected = <String>{};
  final _thumbs = <String, Future<Uint8List>>{};
  final _progress = <String, double>{}; // downloads under way
  Timer? _poll;

  RobotApi? get _api => ref.read(robotApiProvider);

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadQuality();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    try {
      final s = await api.media();
      if (!mounted) return;
      setState(() {
        _status = s;
        _failed = false;
        final names = {for (final i in s.items) i.name};
        _selected.retainWhere(names.contains);
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _loadQuality() async {
    try {
      final q = await _api?.cameraQuality();
      if (mounted && q != null) setState(() => _quality = q);
    } catch (_) {}
  }

  Future<void> _setQuality(String q) async {
    final api = _api;
    if (api == null) return;
    final before = _quality;
    setState(() => _quality = q);
    try {
      await api.setCameraQuality(q);
    } catch (_) {
      if (!mounted) return;
      setState(() => _quality = before);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.galleryQualityFailed)));
    }
  }

  Future<Uint8List> _thumb(String name) =>
      _thumbs.putIfAbsent(name, () => _api?.thumbnail(name) ?? Future.error('offline'));

  /// Downloads [items] one by one into the phone's gallery.
  Future<void> _download(List<MediaItem> items) async {
    final api = _api;
    if (api == null || items.isEmpty) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    var saved = 0;
    for (final item in items) {
      setState(() => _progress[item.name] = 0);
      final file = File('${Directory.systemTemp.path}/${item.name}');
      try {
        await api.download(
          item.name,
          file,
          progress: (p) {
            if (mounted) setState(() => _progress[item.name] = p);
          },
        );
        await widget.saver(file, video: item.isVideo);
        saved++;
      } catch (_) {
        messenger.showSnackBar(SnackBar(content: Text(l.galleryDownloadFailed(item.name))));
      } finally {
        if (file.existsSync()) await file.delete();
        if (mounted) setState(() => _progress.remove(item.name));
      }
    }
    if (saved > 0) messenger.showSnackBar(SnackBar(content: Text(l.gallerySaved(saved))));
    if (mounted) setState(_selected.clear);
  }

  Future<void> _delete(List<MediaItem> items) async {
    final api = _api;
    if (api == null || items.isEmpty) return;
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l.galleryDeleteTitle(items.length)),
        content: Text(l.galleryDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(l.galleryCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _rec),
            onPressed: () => Navigator.pop(c, true),
            child: Text(l.galleryDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final item in items) {
      try {
        await api.deleteMedia(item.name);
        _thumbs.remove(item.name);
      } catch (_) {}
    }
    setState(_selected.clear);
    await _refresh();
  }

  List<MediaItem> get _selectedItems => [
    for (final i in _status?.items ?? const <MediaItem>[])
      if (_selected.contains(i.name)) i,
  ];

  void _toggle(String name) =>
      setState(() => _selected.contains(name) ? _selected.remove(name) : _selected.add(name));

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = _status;
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        title: Text(selecting ? l.gallerySelected(_selected.length) : l.galleryTitle),
        leading: selecting
            ? IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setState(_selected.clear))
            : null,
        actions: [
          if (selecting) ...[
            IconButton(
              tooltip: l.galleryDownload,
              icon: const Icon(Icons.download_rounded),
              onPressed: () => _download(_selectedItems),
            ),
            IconButton(
              tooltip: l.galleryDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _delete(_selectedItems),
            ),
          ] else if (s != null && s.items.isNotEmpty)
            TextButton.icon(
              onPressed: () => _download(s.items),
              icon: const Icon(Icons.download_rounded),
              label: Text(l.galleryDownloadAll),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  if (s != null)
                    Expanded(
                      child: Text(
                        '${l.galleryCount(s.items.length)} · ${l.galleryFree((s.freeMb / 1024).toStringAsFixed(1))}',
                        style: const TextStyle(color: Colors.white60),
                      ),
                    )
                  else
                    const Spacer(),
                  if (_quality != null) ...[
                    Text(l.galleryQuality, style: const TextStyle(color: Colors.white60)),
                    const SizedBox(width: 8),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: '720p', label: Text('720p')),
                        ButtonSegment(value: '1080p', label: Text('1080p')),
                      ],
                      selected: {_quality!},
                      onSelectionChanged: (v) => _setQuality(v.first),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(child: _body(l, s)),
          ],
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l, MediaStatus? s) {
    if (s == null && _failed) return _empty(Icons.wifi_off_rounded, l.galleryOffline);
    if (s == null) return const Center(child: CircularProgressIndicator());
    if (s.items.isEmpty) return _empty(Icons.photo_camera_outlined, l.galleryEmpty);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        childAspectRatio: 16 / 10,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: s.items.length,
      itemBuilder: (_, i) {
        final item = s.items[i];
        return _Tile(
          item: item,
          thumb: _thumb(item.name),
          selected: _selected.contains(item.name),
          progress: _progress[item.name],
          onTap: () => _selected.isNotEmpty ? _toggle(item.name) : _open(item),
          onLongPress: () => _toggle(item.name),
        );
      },
    );
  }

  Widget _empty(IconData icon, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.white38),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ),
  );

  void _open(MediaItem item) {
    final l = context.l10n;
    final api = _api;
    if (api == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (c) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(item.name, style: const TextStyle(fontSize: 15)),
            actions: [
              IconButton(
                tooltip: l.galleryDownload,
                icon: const Icon(Icons.download_rounded),
                onPressed: () {
                  Navigator.pop(c);
                  _download([item]);
                },
              ),
              IconButton(
                tooltip: l.galleryDelete,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () {
                  Navigator.pop(c);
                  _delete([item]);
                },
              ),
            ],
          ),
          body: item.isVideo
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 480,
                        child: AspectRatio(aspectRatio: 16 / 9, child: _Thumb(_thumb(item.name))),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${formatClip(item.durationS)} · ${formatBytes(item.size)}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 4),
                      Text(l.galleryVideoHint, style: const TextStyle(color: Colors.white54)),
                    ],
                  ),
                )
              : InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: Image.network(
                      api.mediaUri(item.name).toString(),
                      headers: {'Authorization': 'Bearer ${api.token}'},
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.item,
    required this.thumb,
    required this.selected,
    required this.progress,
    required this.onTap,
    required this.onLongPress,
  });

  final MediaItem item;
  final Future<Uint8List> thumb;
  final bool selected;
  final double? progress;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Thumb(thumb),
            // Bottom shade for the labels.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            Positioned(
              left: 8,
              bottom: 6,
              right: 8,
              child: Row(
                children: [
                  Icon(
                    item.isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      item.isVideo
                          ? formatClip(item.durationS)
                          : DateFormat.MMMd(
                              Localizations.localeOf(context).toString(),
                            ).add_Hm().format(item.created),
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(formatBytes(item.size), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ),
            ),
            if (item.isVideo)
              const Center(child: Icon(Icons.play_circle_fill_rounded, size: 40, color: Colors.white70)),
            if (selected)
              Container(
                decoration: BoxDecoration(
                  color: Brand.cyan.withValues(alpha: 0.25),
                  border: Border.all(color: Brand.cyan, width: 3),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.topRight,
                padding: const EdgeInsets.all(6),
                child: const Icon(Icons.check_circle_rounded, color: Brand.cyan),
              ),
            if (progress != null)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(value: progress! > 0 ? progress : null, strokeWidth: 4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.bytes);

  final Future<Uint8List> bytes;

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    builder: (_, snap) => snap.hasData
        ? Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true)
        : Container(
            color: _card,
            alignment: Alignment.center,
            child: snap.hasError ? const Icon(Icons.broken_image_outlined, color: Colors.white38) : null,
          ),
  );
}
