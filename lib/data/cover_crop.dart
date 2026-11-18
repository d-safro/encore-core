import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

/// The maths of the square crop: a picture of [image] size shown in a square window [view] wide. At zoom 1
/// the picture just covers the window (its short side fits); [zoom] makes it bigger. [offset] is where the
/// picture's top-left corner sits in the window (zero or less: the picture always covers the window).
class SquareCrop {
  const SquareCrop(this.image, this.view, {this.zoom = 1, this.offset = Offset.zero});
  final Size image;
  final double view, zoom;
  final Offset offset;

  static const maxZoom = 6.0;

  /// Screen pixels per picture pixel.
  double get scale => view / image.shortestSide * zoom;
  Size get shown => image * scale;

  /// The picture in the middle at zoom 1.
  factory SquareCrop.centred(Size image, double view) {
    final c = SquareCrop(image, view);
    return c.moved(Offset((view - c.shown.width) / 2, (view - c.shown.height) / 2));
  }

  /// Moved to [o], kept so the picture still covers the whole window.
  SquareCrop moved(Offset o) => SquareCrop(
    image,
    view,
    zoom: zoom,
    offset: Offset(o.dx.clamp(view - shown.width, 0.0), o.dy.clamp(view - shown.height, 0.0)),
  );

  /// Zoomed to [z] (pinch), keeping the picture point under [focal] (a point in the window) where it is.
  /// [from] is the crop when the pinch started, [start] the focal point then.
  static SquareCrop pinch(SquareCrop from, Offset start, Offset focal, double z) {
    final zoom = z.clamp(1.0, maxZoom);
    final point = (start - from.offset) / from.scale; // in picture pixels
    final next = SquareCrop(from.image, from.view, zoom: zoom);
    return next.moved(focal - point * next.scale);
  }

  /// The part of the picture inside the window, in picture pixels.
  Rect get source {
    final side = view / scale;
    return Rect.fromLTWH(-offset.dx / scale, -offset.dy / scale, side, side);
  }

  /// How big the saved picture is: the crop's own size, kept between 300 and 1000 pixels.
  int get outputSide => source.width.round().clamp(300, 1000);
}

/// Raw RGBA pixels → a JPEG (runs in the background: plain Dart, so it can go to another isolate).
Uint8List rgbaToJpeg((int, int, Uint8List) p) {
  final (w, h, rgba) = p;
  final image = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4);
  return img.encodeJpg(image, quality: 88);
}
