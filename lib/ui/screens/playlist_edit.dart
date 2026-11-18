import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/account.dart';
import '../../data/cover_crop.dart';
import '../../data/models.dart';
import '../../data/playlist_covers.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';

/// Name, description, and who can see it.
Future<void> showPlaylistDetails(BuildContext context, WidgetRef ref, Playlist p) async {
  final name = TextEditingController(text: p.name);
  final notes = TextEditingController(text: p.comment);
  var public = p.public;
  final save = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit details', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: notes,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Public'),
                subtitle: Text(public ? 'Everyone with an account on your server can see it' : 'Only you can see it'),
                value: public,
                onChanged: (v) => setSheet(() => public = v),
              ),
              const SizedBox(height: 8),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          ),
        ),
      ),
    ),
  );
  if (save != true) return;
  final n = name.text.trim();
  final c = ref.read(clientProvider);
  if (c == null) return;
  if (n.isEmpty) {
    if (context.mounted) toast(context, 'A playlist needs a name');
    return;
  }
  try {
    await c.updatePlaylist(
      p.id,
      name: n == p.name ? null : n,
      comment: notes.text.trim() == p.comment ? null : notes.text.trim(),
      public: public == p.public ? null : public,
    );
    ref.invalidate(playlistProvider(p.id));
    ref.invalidate(playlistsProvider);
  } catch (e) {
    if (context.mounted) toast(context, "Couldn't save: $e");
  }
}

/// Your own picture for a playlist: from your photos, your files, or one of its album covers.
Future<void> showPlaylistPicture(BuildContext context, WidgetRef ref, Playlist p) async {
  final mine = ref.read(playlistCoversProvider)[p.id];
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    useRootNavigator: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Playlist picture')),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from your photos'),
            onTap: () => Navigator.pop(ctx, 'photos'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('Choose a file'),
            onTap: () => Navigator.pop(ctx, 'files'),
          ),
          if (p.songs.any((s) => s.coverArt.isNotEmpty))
            ListTile(
              leading: const Icon(Icons.album_outlined),
              title: const Text("One of this playlist's album covers"),
              onTap: () => Navigator.pop(ctx, 'albums'),
            ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_mosaic_outlined),
            title: const Text('Use the automatic picture'),
            subtitle: const Text("The server's mix of the album covers"),
            onTap: () => Navigator.pop(ctx, 'reset'),
          ),
          if (mine?.phoneOnly == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                "Your server doesn't keep playlist pictures, so this playlist's picture is saved on this phone only.",
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final container = ProviderScope.containerOf(context);
  try {
    if (choice == 'reset') {
      await ref.read(playlistCoversProvider.notifier).reset(p.id);
      _refreshSoon(container, p.id);
      if (context.mounted) toast(context, 'Back to the automatic picture');
      return;
    }
    final Uint8List? bytes = switch (choice) {
      'photos' => await (await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 95,
      ))?.readAsBytes(),
      'files' => await (await FilePicker.pickFiles(type: FileType.image)).firstOrNull?.readAsBytes(),
      _ => context.mounted ? await _pickAlbumCover(context, ref, p) : null,
    };
    if (bytes == null || !context.mounted) return;
    final jpeg = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<Uint8List>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => CropScreen(bytes)));
    if (jpeg == null || !context.mounted) return;
    toast(context, 'Saving the picture…');
    final saved = await ref.read(playlistCoversProvider.notifier).set(p.id, p.coverArt, jpeg);
    _refreshSoon(container, p.id);
    if (context.mounted) {
      toast(
        context,
        saved == CoverSaved.onServer
            ? 'Saved on your server: your other devices and apps show it too'
            : "Your server doesn't keep playlist pictures, so it's saved on this phone only",
      );
    }
  } catch (e) {
    if (context.mounted) toast(context, "Couldn't change the picture: $e");
  }
}

/// The server makes the new picture ready in the background; ask again in a moment for its new cover id.
void _refreshSoon(ProviderContainer container, String id) {
  for (final wait in const [Duration(seconds: 1), Duration(seconds: 8)]) {
    Timer(wait, () {
      container.invalidate(playlistProvider(id));
      container.invalidate(playlistsProvider);
    });
  }
}

Future<Uint8List?> _pickAlbumCover(BuildContext context, WidgetRef ref, Playlist p) async {
  final covers = albumCovers(p.songs);
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Pick an album cover', style: Theme.of(ctx).textTheme.titleLarge),
            ),
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                padding: const EdgeInsets.all(12),
                mainAxisSpacing: 12,
                crossAxisSpacing: 8,
                childAspectRatio: 0.78,
                children: [
                  for (final (cover, album) in covers.take(120))
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.pop(ctx, cover),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(aspectRatio: 1, child: Cover(cover, size: double.infinity)),
                          const SizedBox(height: 4),
                          Text(
                            album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  final c = ref.read(clientProvider);
  if (picked == null || c == null) return null;
  final r = await http.get(c.coverUrl(picked, size: 1000)).timeout(const Duration(seconds: 30));
  if (r.statusCode != 200 || r.bodyBytes.isEmpty || r.bodyBytes.first == 0x7B) {
    throw Exception("the server didn't send that cover");
  }
  return r.bodyBytes;
}

/// Pinch and drag a picture inside a square; answers the square as a JPEG.
class CropScreen extends StatefulWidget {
  const CropScreen(this.bytes, {super.key});
  final Uint8List bytes;
  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  ui.Image? _image;
  Object? _error;
  SquareCrop? _crop;
  SquareCrop? _pinchFrom;
  Offset _pinchStart = Offset.zero;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(widget.bytes);
      // a big photo is made smaller while it's read: 2400 pixels across is plenty for a 1000-pixel square
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (w, h) => w > 2400 ? ui.TargetImageSize(width: 2400) : ui.TargetImageSize(),
      );
      final frame = await codec.getNextFrame();
      if (mounted) setState(() => _image = frame.image);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    final image = _image, crop = _crop;
    if (image == null || crop == null) return;
    setState(() => _saving = true);
    try {
      final out = crop.outputSide;
      final rec = ui.PictureRecorder();
      Canvas(rec).drawImageRect(
        image,
        crop.source,
        Rect.fromLTWH(0, 0, out.toDouble(), out.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final square = await rec.endRecording().toImage(out, out);
      final data = await square.toByteData(format: ui.ImageByteFormat.rawRgba);
      square.dispose();
      final jpeg = await compute(rgbaToJpeg, (out, out, data!.buffer.asUint8List()));
      if (mounted) Navigator.pop(context, jpeg);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        toast(context, "Couldn't make the picture: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Move and zoom'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton(onPressed: image == null ? null : _done, child: const Text('Done')),
        ],
      ),
      body: _error != null
          ? const Center(
              child: Text("Couldn't open that picture", style: TextStyle(color: Colors.white)),
            )
          : image == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (ctx, box) {
                final view = (box.biggest.shortestSide - 32).clamp(120.0, 600.0);
                final size = Size(image.width.toDouble(), image.height.toDouble());
                final crop = (_crop != null && _crop!.view == view) ? _crop! : SquareCrop.centred(size, view);
                _crop = crop;
                return Center(
                  child: GestureDetector(
                    onScaleStart: (d) {
                      _pinchFrom = _crop;
                      _pinchStart = d.localFocalPoint;
                    },
                    onScaleUpdate: (d) => setState(() {
                      _crop = SquareCrop.pinch(_pinchFrom!, _pinchStart, d.localFocalPoint, _pinchFrom!.zoom * d.scale);
                    }),
                    onDoubleTap: () => setState(() => _crop = SquareCrop.centred(size, view)),
                    child: Container(
                      width: view,
                      height: view,
                      decoration: BoxDecoration(border: Border.all(color: Colors.white70, width: 1.5)),
                      child: ClipRect(
                        child: Stack(
                          children: [
                            Positioned(
                              left: crop.offset.dx,
                              top: crop.offset.dy,
                              width: crop.shown.width,
                              height: crop.shown.height,
                              child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Drag to move, pinch to zoom, double-tap to start over',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
