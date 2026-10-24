import 'dart:io';
import 'dart:ui' as ui;

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';

import '../models/scan_document.dart';

Future<List<NormalizedPoint>?> showQuadEditor(
  BuildContext context, {
  required String sourcePath,
  List<NormalizedPoint>? initialQuad,
  String? reason,
}) {
  return showModalBottomSheet<List<NormalizedPoint>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => QuadEditorSheet(
      sourcePath: sourcePath,
      initialQuad: initialQuad,
      reason: reason,
    ),
  );
}

/// Manual four-corner editor reused from Sprint 1. The expensive rescan happens
/// once in the document controller after the user applies the corners.
class QuadEditorSheet extends StatefulWidget {
  const QuadEditorSheet({
    super.key,
    required this.sourcePath,
    this.initialQuad,
    this.reason,
  });

  final String sourcePath;
  final List<NormalizedPoint>? initialQuad;
  final String? reason;

  @override
  State<QuadEditorSheet> createState() => _QuadEditorSheetState();
}

class _QuadEditorSheetState extends State<QuadEditorSheet> {
  static const double _handleRadius = 24;

  Size? _imageSize;
  _ImageLayout? _layout;
  late List<NormalizedPoint> _quad;

  @override
  void initState() {
    super.initState();
    _quad = widget.initialQuad != null && widget.initialQuad!.length == 4
        ? List<NormalizedPoint>.of(widget.initialQuad!)
        : kDefaultInsetQuad;
    _resolveImageSize();
  }

  Future<void> _resolveImageSize() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      codec.dispose();
      if (mounted) setState(() => _imageSize = size);
    } catch (_) {
      // Keep the fallback layout; the image error widget will explain itself.
    }
  }

  Offset _toScreen(int index) {
    final layout = _layout;
    if (layout == null) return Offset.zero;
    return Offset(
      layout.offset.dx + _quad[index].$1 * layout.size.width,
      layout.offset.dy + _quad[index].$2 * layout.size.height,
    );
  }

  void _updateQuad(int index, Offset screenPos) {
    final layout = _layout;
    if (layout == null || layout.size.width <= 0 || layout.size.height <= 0) {
      return;
    }
    final dx = ((screenPos.dx - layout.offset.dx) / layout.size.width).clamp(
      0.0,
      1.0,
    );
    final dy = ((screenPos.dy - layout.offset.dy) / layout.size.height).clamp(
      0.0,
      1.0,
    );
    setState(() {
      _quad = [
        for (var i = 0; i < 4; i++)
          if (i == index) (dx, dy) else _quad[i],
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        height: MediaQuery.sizeOf(context).height * 0.9,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '拖动四角框住纸张',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
              if (widget.reason != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: theme.colorScheme.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.reason!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ColoredBox(
                  color: Colors.black,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final imageSize = _imageSize;
                      if (imageSize == null) {
                        return const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        );
                      }
                      _layout = _ImageLayout.contain(
                        imageSize,
                        Size(constraints.maxWidth, constraints.maxHeight),
                      );
                      final layout = _layout!;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(widget.sourcePath),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Center(
                              child: Text(
                                '无法读取原图',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                          Positioned.fromRect(
                            rect: Rect.fromLTWH(
                              layout.offset.dx,
                              layout.offset.dy,
                              layout.size.width,
                              layout.size.height,
                            ),
                            child: CustomPaint(painter: _QuadPainter(_quad)),
                          ),
                          for (var i = 0; i < 4; i++)
                            _CornerHandle(
                              key: ValueKey('corner-$i'),
                              position: _toScreen(i),
                              radius: _handleRadius,
                              onDrag: (position) => _updateQuad(i, position),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            setState(() => _quad = kDefaultInsetQuad),
                        child: const Text('整图内缩 2%'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        key: const Key('apply-quad-button'),
                        onPressed: () => Navigator.of(context).pop(_quad),
                        child: const Text('应用此四角'),
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
  }
}

class _ImageLayout {
  const _ImageLayout({required this.offset, required this.size});

  factory _ImageLayout.contain(Size image, Size container) {
    final imageRatio = image.width / image.height;
    final containerRatio = container.width / container.height;
    final size = imageRatio > containerRatio
        ? Size(container.width, container.width / imageRatio)
        : Size(container.height * imageRatio, container.height);
    return _ImageLayout(
      offset: Offset(
        (container.width - size.width) / 2,
        (container.height - size.height) / 2,
      ),
      size: size,
    );
  }

  final Offset offset;
  final Size size;
}

class _CornerHandle extends StatelessWidget {
  const _CornerHandle({
    super.key,
    required this.position,
    required this.radius,
    required this.onDrag,
  });

  final Offset position;
  final double radius;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Positioned(
      left: position.dx - radius,
      top: position.dy - radius,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onDrag(position + details.delta),
        child: Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.30),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
          ),
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  const _QuadPainter(this.quad);

  final List<NormalizedPoint> quad;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(quad[0].$1 * size.width, quad[0].$2 * size.height);
    for (var i = 1; i < quad.length; i++) {
      path.lineTo(quad[i].$1 * size.width, quad[i].$2 * size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0x44000000)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFC107)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_QuadPainter oldDelegate) =>
      oldDelegate.quad.toString() != quad.toString();
}
