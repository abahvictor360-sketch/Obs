import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/models.dart';
import '../core/studio_controller.dart';
import '../ui/item_menu.dart';
import '../ui/theme.dart';

/// Displays [content] (a 16:9 canvas) letterboxed in the available space and
/// adds OBS-style touch editing on top for the scene being edited:
///
///  * tap to select, tap empty space to deselect
///  * drag with one finger to move (snaps to canvas edges and center)
///  * pinch with two fingers to scale, twist to rotate (snaps to 90°)
///  * drag the red handles to resize (corners keep aspect ratio)
///  * long-press for the item menu (transform presets, order, lock, ...)
class EditableCanvas extends StatelessWidget {
  const EditableCanvas({super.key, required this.content, this.editable = true, this.label, this.onLongPressCanvas});

  final Widget content;
  final bool editable;
  final String? label;

  /// Long-press on the canvas itself (not on an item you can edit): the
  /// Program's "send to screen" menu.
  final void Function(Offset globalPosition)? onLongPressCanvas;

  @override
  Widget build(BuildContext context) {
    final studio = AppScope.of(context).studio;
    final cw = studio.settings.canvasWidth.toDouble();
    final ch = studio.settings.canvasHeight.toDouble();
    return LayoutBuilder(builder: (context, box) {
      final s = math.min(box.maxWidth / cw, box.maxHeight / ch);
      final dw = cw * s, dh = ch * s;
      return Center(
        child: SizedBox(
          width: dw,
          height: dh,
          child: Stack(
            children: [
              Positioned.fill(child: content),
              // Canvas edge, so the output area is visible even on dark scenes.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: ObsColors.border))),
                ),
              ),
              if (editable)
                Positioned.fill(child: _EditorOverlay(scale: s, onLongPressCanvas: onLongPressCanvas))
              else if (onLongPressCanvas != null)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPressStart: (d) => onLongPressCanvas!(d.globalPosition),
                  ),
                ),
              if (onLongPressCanvas != null)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Builder(
                    builder: (context) => IconButton(
                      key: const ValueKey('send-program'),
                      tooltip: 'Send Program to a screen',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: ObsColors.text),
                      icon: const Icon(Icons.cast),
                      onPressed: () {
                        final box = context.findRenderObject() as RenderBox;
                        onLongPressCanvas!(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                      },
                    ),
                  ),
                ),
              if (label != null)
                Positioned(
                  left: 6,
                  top: 6,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(label!, style: const TextStyle(fontSize: 12, color: ObsColors.text)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

enum _Mode { none, move, pinch, resize }

class _EditorOverlay extends StatefulWidget {
  const _EditorOverlay({required this.scale, this.onLongPressCanvas});

  /// Display pixels per canvas pixel.
  final double scale;
  final void Function(Offset globalPosition)? onLongPressCanvas;

  @override
  State<_EditorOverlay> createState() => _EditorOverlayState();
}

class _EditorOverlayState extends State<_EditorOverlay> {
  _Mode _mode = _Mode.none;
  ItemTransform? _start;
  Offset _startFocal = Offset.zero;
  (int, int) _handle = (0, 0);
  final List<_Guide> _guides = [];

  static const _handleHitRadius = 28.0; // display px, finger sized
  static const _snapDistance = 14.0; // display px

  StudioController get _studio => AppScope.of(context).studio;
  double get _s => widget.scale;

  @override
  Widget build(BuildContext context) {
    final studio = _studio;
    return ListenableBuilder(
      listenable: studio,
      builder: (context, _) {
        final selected = studio.selectedItem;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTap(d.localPosition),
          onLongPressStart: (d) => _onLongPress(d.localPosition, d.globalPosition),
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: CustomPaint(
            painter: _SelectionPainter(
              transform: selected?.transform,
              locked: selected?.locked ?? false,
              scale: _s,
              guides: List.of(_guides),
            ),
            size: Size.infinite,
          ),
        );
      },
    );
  }

  Offset _toCanvas(Offset display) => display / _s;

  /// Top-most visible visual item containing canvas point [p].
  SceneItem? _hitTest(Offset p) {
    final studio = _studio;
    final items = studio.editingScene.items;
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (!it.visible) continue;
      final src = studio.sourceById(it.sourceId);
      if (src == null || !src.type.isVisual) continue;
      if (_contains(it.transform, p)) return it;
    }
    return null;
  }

  static Offset _rotate(Offset v, double deg) {
    final r = deg * math.pi / 180;
    final c = math.cos(r), s = math.sin(r);
    return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
  }

  static bool _contains(ItemTransform t, Offset p) {
    final local = _rotate(p - Offset(t.centerX, t.centerY), -t.rotation);
    return local.dx.abs() <= t.width / 2 && local.dy.abs() <= t.height / 2;
  }

  /// Handle (hx, hy) under display point [d] for the selected item, if any.
  (int, int)? _handleAt(Offset d) {
    final it = _studio.selectedItem;
    if (it == null || it.locked) return null;
    final t = it.transform;
    final c = Offset(t.centerX, t.centerY);
    for (final h in _handles) {
      final pos = (c + _rotate(Offset(h.$1 * t.width / 2, h.$2 * t.height / 2), t.rotation)) * _s;
      if ((pos - d).distance <= _handleHitRadius) return h;
    }
    return null;
  }

  static const _handles = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)];

  void _onTap(Offset d) {
    final hit = _hitTest(_toCanvas(d));
    _studio.selectItem(hit?.id);
  }

  void _onLongPress(Offset local, Offset global) {
    final hit = _hitTest(_toCanvas(local));
    final canvasMenu = widget.onLongPressCanvas;
    // Empty space or a locked background: the canvas's own menu.
    if (canvasMenu != null && (hit == null || hit.locked)) {
      canvasMenu(global);
      return;
    }
    if (hit == null) return;
    _studio.selectItem(hit.id);
    showItemMenu(context, global, hit.id);
  }

  void _onScaleStart(ScaleStartDetails d) {
    final studio = _studio;
    _guides.clear();
    _startFocal = d.localFocalPoint;
    if (d.pointerCount >= 2) {
      final it = studio.selectedItem;
      if (it == null || it.locked) {
        _mode = _Mode.none;
        return;
      }
      _mode = _Mode.pinch;
      _start = it.transform.copy();
      return;
    }
    final handle = _handleAt(d.localFocalPoint);
    if (handle != null) {
      _mode = _Mode.resize;
      _handle = handle;
      _start = studio.selectedItem!.transform.copy();
      return;
    }
    final p = _toCanvas(d.localFocalPoint);
    var it = studio.selectedItem;
    if (it == null || !_contains(it.transform, p)) {
      it = _hitTest(p);
      studio.selectItem(it?.id);
    }
    if (it == null || it.locked) {
      _mode = _Mode.none;
      return;
    }
    _mode = _Mode.move;
    _start = it.transform.copy();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final start = _start;
    final id = _studio.selectedItemId;
    if (_mode == _Mode.none || start == null || id == null) return;
    final delta = (d.localFocalPoint - _startFocal) / _s;
    final cw = _studio.settings.canvasWidth.toDouble();
    final ch = _studio.settings.canvasHeight.toDouble();

    switch (_mode) {
      case _Mode.move:
        var x = start.x + delta.dx, y = start.y + delta.dy;
        _guides.clear();
        if (start.rotation % 360 == 0) {
          (x, y) = _snap(x, y, start.width, start.height, cw, ch);
        }
        _studio.updateTransform(id, (t) {
          t.x = x;
          t.y = y;
        });
      case _Mode.pinch:
        final k = d.scale.clamp(0.05, 20.0);
        final w = math.max(8.0, start.width * k), h = math.max(8.0, start.height * k);
        var rot = start.rotation + d.rotation * 180 / math.pi;
        final nearest = (rot / 90).round() * 90.0;
        if ((rot - nearest).abs() < 4) rot = nearest;
        final cx = start.centerX + delta.dx, cy = start.centerY + delta.dy;
        _studio.updateTransform(id, (t) {
          t
            ..width = w
            ..height = h
            ..x = cx - w / 2
            ..y = cy - h / 2
            ..rotation = rot % 360;
        });
      case _Mode.resize:
        _resize(id, start, delta);
      case _Mode.none:
        break;
    }
    setState(() {});
  }

  void _resize(String id, ItemTransform start, Offset delta) {
    final (hx, hy) = _handle;
    final ld = _rotate(delta, -start.rotation);
    var w = start.width, h = start.height;
    if (hx != 0 && hy != 0) {
      // Corner: uniform scale along the diagonal, opposite corner fixed.
      final diag = Offset(hx * start.width, hy * start.height);
      final len = diag.distance;
      final proj = (ld.dx * diag.dx + ld.dy * diag.dy) / len;
      final k = math.max(8 / math.min(start.width, start.height), (len + proj) / len);
      w = start.width * k;
      h = start.height * k;
    } else {
      if (hx != 0) w = math.max(8, start.width + hx * ld.dx);
      if (hy != 0) h = math.max(8, start.height + hy * ld.dy);
    }
    final c0 = Offset(start.centerX, start.centerY);
    final anchor = c0 + _rotate(Offset(-hx * start.width / 2, -hy * start.height / 2), start.rotation);
    final c = anchor - _rotate(Offset(-hx * w / 2, -hy * h / 2), start.rotation);
    _studio.updateTransform(id, (t) {
      t
        ..width = w
        ..height = h
        ..x = c.dx - w / 2
        ..y = c.dy - h / 2;
    });
  }

  /// Snaps an unrotated box's edges/center to the canvas edges/center.
  (double, double) _snap(double x, double y, double w, double h, double cw, double ch) {
    final tol = _snapDistance / _s;
    double snapAxis(double pos, double size, double canvas, bool vertical) {
      final targets = [0.0, canvas / 2, canvas];
      final anchors = [0.0, size / 2, size];
      var best = pos, bestDist = tol;
      double? guide;
      for (final a in anchors) {
        for (final t in targets) {
          final dist = (pos + a - t).abs();
          if (dist < bestDist) {
            bestDist = dist;
            best = t - a;
            guide = t;
          }
        }
      }
      if (guide != null) _guides.add(_Guide(vertical, guide));
      return best;
    }

    return (snapAxis(x, w, cw, true), snapAxis(y, h, ch, false));
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_mode != _Mode.none) _studio.commitTransform();
    _mode = _Mode.none;
    _start = null;
    setState(_guides.clear);
  }
}

class _Guide {
  _Guide(this.vertical, this.pos);
  final bool vertical;
  final double pos; // canvas px
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter({required this.transform, required this.locked, required this.scale, required this.guides});

  final ItemTransform? transform;
  final bool locked;
  final double scale;
  final List<_Guide> guides;

  @override
  void paint(Canvas canvas, Size size) {
    final guidePaint = Paint()
      ..color = ObsColors.warn
      ..strokeWidth = 1;
    for (final g in guides) {
      final p = g.pos * scale;
      if (g.vertical) {
        canvas.drawLine(Offset(p, 0), Offset(p, size.height), guidePaint);
      } else {
        canvas.drawLine(Offset(0, p), Offset(size.width, p), guidePaint);
      }
    }

    final t = transform;
    if (t == null) return;
    final w = t.width * scale, h = t.height * scale;
    canvas.save();
    canvas.translate(t.centerX * scale, t.centerY * scale);
    canvas.rotate(t.rotation * math.pi / 180);
    final rect = Rect.fromCenter(center: Offset.zero, width: w, height: h);
    final color = locked ? ObsColors.textDim : ObsColors.selection;
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
    if (!locked) {
      final fill = Paint()..color = color;
      for (final hx in [-1, 0, 1]) {
        for (final hy in [-1, 0, 1]) {
          if (hx == 0 && hy == 0) continue;
          canvas.drawRect(
            Rect.fromCenter(center: Offset(hx * w / 2, hy * h / 2), width: 12, height: 12),
            fill,
          );
        }
      }
    } else {
      final tp = TextPainter(
        text: const TextSpan(text: '🔒', style: TextStyle(fontSize: 16)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, rect.topLeft + const Offset(4, 4));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SelectionPainter old) => true;
}
