import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Turns touch gestures into mouse actions:
///  tap = left click, long press = right click, drag = left-button drag,
///  two-finger drag = wheel scroll.
class TouchController {
  TouchController({
    required this.toNorm,
    required this.onMove,
    required this.onButton,
    required this.onScroll,
  });

  /// Local position -> normalised (0..1) remote position, or null.
  final (double, double)? Function(Offset local) toNorm;
  final void Function(double nx, double ny, bool force) onMove;
  final void Function(int button, bool pressed) onButton;
  final void Function(int dx, int dy) onScroll;

  static const double slop = 12;
  static const double scrollStep = 28;
  static const Duration longPress = Duration(milliseconds: 500);

  final Map<int, Offset> _pts = {};
  Offset _start = Offset.zero;
  bool _dragging = false;
  bool _longDone = false;
  bool _multi = false;
  Timer? _timer;
  double _scrollAcc = 0;
  double? _lastCentroidY;

  void _move(Offset p, {bool force = false}) {
    final n = toNorm(p);
    if (n != null) onMove(n.$1, n.$2, force);
  }

  double _centroidY() {
    var s = 0.0;
    for (final p in _pts.values) {
      s += p.dy;
    }
    return s / _pts.length;
  }

  void down(PointerDownEvent e) {
    _pts[e.pointer] = e.localPosition;
    if (_pts.length == 1 && !_multi) {
      _start = e.localPosition;
      _dragging = false;
      _longDone = false;
      _timer?.cancel();
      _timer = Timer(longPress, () {
        if (_dragging || _multi) return;
        _longDone = true;
        HapticFeedback.mediumImpact();
        _move(_start, force: true);
        onButton(2, true); // right button
        onButton(2, false);
      });
    } else if (_pts.length >= 2) {
      _timer?.cancel();
      if (_dragging) {
        onButton(1, false);
        _dragging = false;
      }
      _multi = true;
      _scrollAcc = 0;
      _lastCentroidY = _centroidY();
    }
  }

  void moved(PointerMoveEvent e) {
    if (!_pts.containsKey(e.pointer)) return;
    _pts[e.pointer] = e.localPosition;
    if (_multi) {
      if (_pts.length >= 2) {
        final y = _centroidY();
        final last = _lastCentroidY ?? y;
        _scrollAcc += y - last;
        _lastCentroidY = y;
        while (_scrollAcc >= scrollStep) {
          onScroll(0, 1); // finger down -> content down -> wheel up
          _scrollAcc -= scrollStep;
        }
        while (_scrollAcc <= -scrollStep) {
          onScroll(0, -1);
          _scrollAcc += scrollStep;
        }
      }
      return;
    }
    if (_longDone) return;
    if (!_dragging && (e.localPosition - _start).distance > slop) {
      _timer?.cancel();
      _dragging = true;
      _move(_start, force: true);
      onButton(1, true);
    }
    if (_dragging) _move(e.localPosition);
  }

  void up(PointerUpEvent e) {
    _timer?.cancel();
    final pos = e.localPosition;
    _pts.remove(e.pointer);
    if (_multi) {
      if (_pts.isEmpty) _multi = false;
      return;
    }
    if (_dragging) {
      _move(pos, force: true);
      onButton(1, false);
      _dragging = false;
      return;
    }
    if (_longDone) return;
    _move(_start, force: true); // tap = left click
    onButton(1, true);
    onButton(1, false);
  }

  void cancel(PointerCancelEvent e) {
    _timer?.cancel();
    _pts.remove(e.pointer);
    if (_dragging) {
      onButton(1, false);
      _dragging = false;
    }
    if (_pts.isEmpty) _multi = false;
  }

  void dispose() => _timer?.cancel();
}
