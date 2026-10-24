import 'dart:io';

import 'package:flutter/material.dart';

import '../models/scan_document.dart';

/// Small page tile used by the camera filmstrip and page grid. Never decodes
/// the 12 MP original at full size; [Image.file] applies its own cacheWidth.
class PageThumbnail extends StatelessWidget {
  const PageThumbnail({
    super.key,
    required this.page,
    required this.pageNumber,
    this.width = 64,
    this.height = 84,
    this.showNumber = true,
    this.onTap,
    this.onLongPress,
  });

  final ScanPage page;
  final int pageNumber;
  final double width;
  final double height;
  final bool showNumber;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = page.displayPath;
    final file = File(path);
    Widget image = file.existsSync()
        ? Image.file(
            file,
            fit: BoxFit.cover,
            cacheWidth: (width * 3).round(),
            errorBuilder: (_, _, _) =>
                const ColoredBox(color: Color(0xFFE0E0E0)),
          )
        : const ColoredBox(color: Color(0xFFE0E0E0));

    if (page.status == PageStatus.processing ||
        page.status == PageStatus.queued) {
      image = Stack(
        fit: StackFit.expand,
        children: [
          Opacity(opacity: 0.45, child: image),
          Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      );
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
              image,
              if (showNumber)
                Positioned(
                  left: 3,
                  top: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      child: Text(
                        '$pageNumber',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              if (page.status == PageStatus.failed)
                Positioned(
                  right: 3,
                  bottom: 3,
                  child: _Badge(
                    color: theme.colorScheme.error,
                    icon: Icons.error_outline,
                    label: '失败',
                  ),
                )
              else if (page.needsReview)
                Positioned(
                  left: 3,
                  right: 3,
                  bottom: 3,
                  child: _Badge(
                    color: const Color(0xFFB26A00),
                    icon: Icons.warning_amber_rounded,
                    label: '建议检查',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.icon, required this.label});

  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 9, color: Colors.white),
            const SizedBox(width: 1),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
