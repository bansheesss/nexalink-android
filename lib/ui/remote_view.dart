import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../session.dart';
import 'touch_controller.dart';

class RemoteView extends StatefulWidget {
  const RemoteView({super.key, required this.session});
  final RemoteSession session;

  @override
  State<RemoteView> createState() => _RemoteViewState();
}

class _RemoteViewState extends State<RemoteView> {
  late final TouchController _touch;
  Size _area = Size.zero;

  @override
  void initState() {
    super.initState();
    _touch = TouchController(
      toNorm: _toNorm,
      onMove: (x, y, force) =>
          widget.session.sendMouseMove(x, y, force: force),
      onButton: widget.session.sendMouseButton,
      onScroll: widget.session.sendScroll,
    );
  }

  @override
  void dispose() {
    _touch.dispose();
    super.dispose();
  }

  Rect? _imageRect() {
    final img = widget.session.image.value;
    if (img == null || _area.isEmpty) return null;
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    final s = math.min(_area.width / iw, _area.height / ih);
    final w = iw * s;
    final h = ih * s;
    return Rect.fromLTWH((_area.width - w) / 2, (_area.height - h) / 2, w, h);
  }

  (double, double)? _toNorm(Offset p) {
    final r = _imageRect();
    if (r == null || r.width <= 0 || r.height <= 0) return null;
    final nx = ((p.dx - r.left) / r.width).clamp(0.0, 1.0).toDouble();
    final ny = ((p.dy - r.top) / r.height).clamp(0.0, 1.0).toDouble();
    return (nx, ny);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: widget.session.image,
      builder: (context, img, _) => LayoutBuilder(
        builder: (context, c) {
          _area = c.biggest;
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _touch.down,
            onPointerMove: _touch.moved,
            onPointerUp: _touch.up,
            onPointerCancel: _touch.cancel,
            child: CustomPaint(
              size: c.biggest,
              painter: _FramePainter(img),
            ),
          );
        },
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.image);
  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final img = image;
    if (img == null) return;
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: img,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.image != image;
}
