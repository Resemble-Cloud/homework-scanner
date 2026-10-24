import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/scan_document.dart';
import '../../services/document_controller.dart';
import '../../services/pdf_export_service.dart';
import '../../services/share_service.dart';
import '../../widgets/page_thumbnail.dart';
import '../camera/camera_capture_screen.dart';
import 'export_dialog.dart';
import 'page_detail_screen.dart';

class DocumentScreen extends StatefulWidget {
  const DocumentScreen({
    super.key,
    required this.controller,
    this.pickImage,
    this.sharePdfCallback,
  });

  final DocumentController controller;
  final Future<String?> Function()? pickImage;
  final PdfShareCallback? sharePdfCallback;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  bool _importing = false;

  Future<String?> _defaultPickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    return picked?.path;
  }

  Future<void> _openCamera() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => CameraCaptureScreen(controller: widget.controller),
      ),
    );
  }

  Future<void> _importPage() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final path = await (widget.pickImage ?? _defaultPickImage)();
      if (path == null) return;
      await widget.controller.addCapturedPage(path, captureSource: 'import');
      if (mounted) _snack('已加入队列，后台处理中');
    } catch (error) {
      if (mounted) _snack('导入失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _exportPdf() async {
    final controller = widget.controller;
    final document = controller.document;
    if (document == null) return;
    if (!controller.canExport || controller.isExporting) {
      _snack(document.hasFailures ? '有页面处理失败，请先在页面详情中重试' : '还有页面在后台处理，完成后再导出');
      return;
    }
    final options = await showExportOptionsDialog(
      context,
      pageCount: document.pages.length,
    );
    if (options == null || !mounted) return;
    final result = await showDialog<PdfExportResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ExportRunnerDialog(controller: controller, options: options),
    );
    if (result == null || !mounted) return;
    await showExportResultDialog(
      context,
      result: result,
      onShare: () async {
        final share = widget.sharePdfCallback ?? sharePdf;
        await share(result);
      },
    );
  }

  Future<void> _openPage(String pageId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PageDetailScreen(controller: widget.controller, pageId: pageId),
      ),
    );
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final document = controller.document;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('作业扫描'),
                if (document != null)
                  Text(
                    '${document.pages.length} 页 · '
                    '${controller.isProcessing ? '后台处理中' : '就绪'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            actions: [
              IconButton(
                key: const Key('import-action'),
                tooltip: '从相册导入',
                onPressed: _importing || controller.isExporting
                    ? null
                    : _importPage,
                icon: _importing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library_outlined),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: _buildBody(context, controller, document),
          ),
          bottomNavigationBar: document == null
              ? null
              : _BottomBar(
                  canExport:
                      controller.canExport &&
                      !controller.isExporting &&
                      !controller.isProcessing,
                  exporting: controller.isExporting,
                  onCapture: controller.isExporting ? null : _openCamera,
                  onImport: controller.isExporting ? null : _importPage,
                  onExport: _exportPdf,
                ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    DocumentController controller,
    ScanDocument? document,
  ) {
    if (controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.fatalError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(
                '会话恢复失败：${controller.fatalError}',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (document == null || document.pages.isEmpty) {
      return _EmptyState(onCapture: _openCamera, onImport: _importPage);
    }
    return Column(
      children: [
        _SessionStatus(document: document, controller: controller),
        Expanded(
          child: _PageGrid(
            document: document,
            onOpen: _openPage,
            onMove: controller.movePage,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: Row(
            children: [
              Icon(
                Icons.drag_indicator,
                size: 14,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(width: 4),
              Text(
                '长按页面拖动排序 · 点页面可修正/重拍/删除',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCapture, required this.onImport});

  final VoidCallback onCapture;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 116,
              height: 148,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Icon(
                Icons.document_scanner_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text('还没有页面', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '连续拍摄多页，后台逐页检测与矫正；\n拍完可排序、重拍、重新裁剪，再导出一个 PDF。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('empty-capture-button'),
              onPressed: onCapture,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('开始拍摄'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('从相册导入'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionStatus extends StatelessWidget {
  const _SessionStatus({required this.document, required this.controller});

  final ScanDocument document;
  final DocumentController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = document.pages.where((page) => page.isDone).length;
    final failed = document.pages
        .where((page) => page.status == PageStatus.failed)
        .length;
    final pending = document.pages.length - done - failed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  pending > 0
                      ? '已完成 $done / ${document.pages.length} 页'
                      : failed > 0
                      ? '已完成 $done 页，$failed 页失败'
                      : '全部 ${document.pages.length} 页处理完成',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (document.hasReviewWarnings)
                _StatusPill(
                  icon: Icons.warning_amber_rounded,
                  label:
                      '${document.pages.where((p) => p.needsReview).length} 页建议检查',
                  color: const Color(0xFFB26A00),
                )
              else if (failed > 0)
                _StatusPill(
                  icon: Icons.error_outline,
                  label: '$failed 页失败',
                  color: theme.colorScheme.error,
                ),
            ],
          ),
          if (pending > 0) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: document.pages.isEmpty
                  ? null
                  : done / document.pages.length,
              minHeight: 5,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}

class _PageGrid extends StatelessWidget {
  const _PageGrid({
    required this.document,
    required this.onOpen,
    required this.onMove,
  });

  final ScanDocument document;
  final ValueChanged<String> onOpen;
  final Future<void> Function(int from, int to) onMove;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 14,
        childAspectRatio: 0.66,
      ),
      itemCount: document.pages.length,
      itemBuilder: (context, index) {
        final page = document.pages[index];
        return DragTarget<int>(
          onWillAcceptWithDetails: (details) => details.data != index,
          onAcceptWithDetails: (details) {
            unawaited(onMove(details.data, index));
          },
          builder: (context, candidates, rejected) {
            final highlighted = candidates.isNotEmpty;
            return LongPressDraggable<int>(
              data: index,
              feedback: Material(
                color: Colors.transparent,
                elevation: 8,
                borderRadius: BorderRadius.circular(10),
                child: PageThumbnail(
                  page: page,
                  pageNumber: index + 1,
                  width: 150,
                  height: 200,
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _PageTile(
                  page: page,
                  number: index + 1,
                  onTap: () => onOpen(page.id),
                ),
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: highlighted
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                padding: const EdgeInsets.all(2),
                child: _PageTile(
                  key: Key('page-tile-${page.id}'),
                  page: page,
                  number: index + 1,
                  onTap: () => onOpen(page.id),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({
    super.key,
    required this.page,
    required this.number,
    required this.onTap,
  });

  final ScanPage page;
  final int number;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = File(page.displayPath);
    final pending =
        page.status == PageStatus.processing ||
        page.status == PageStatus.queued;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (file.existsSync())
                    Image.file(
                      file,
                      key: ValueKey(file.path),
                      fit: BoxFit.cover,
                      cacheWidth: 700,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Color(0xFFE2E2E2),
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    )
                  else
                    const ColoredBox(color: Color(0xFFE2E2E2)),
                  if (pending)
                    ColoredBox(
                      color: Colors.black.withValues(alpha: 0.32),
                      child: const Center(
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2.5,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _NumberBadge(number: number),
                  ),
                  if (page.needsReview)
                    const Positioned(
                      left: 6,
                      right: 6,
                      bottom: 6,
                      child: _TileBadge(
                        icon: Icons.warning_amber_rounded,
                        label: '建议检查',
                        color: Color(0xFFB26A00),
                      ),
                    )
                  else if (page.status == PageStatus.failed)
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 6,
                      child: _TileBadge(
                        icon: Icons.error_outline,
                        label: '处理失败 · 点按重试',
                        color: theme.colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
              child: Row(
                children: [
                  Icon(
                    switch (page.status) {
                      PageStatus.done => Icons.check_circle,
                      PageStatus.failed => Icons.error,
                      _ => Icons.hourglass_top,
                    },
                    size: 13,
                    color: switch (page.status) {
                      PageStatus.done => theme.colorScheme.primary,
                      PageStatus.failed => theme.colorScheme.error,
                      _ => theme.colorScheme.tertiary,
                    },
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      page.status.label,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  if (page.outputWidth != null)
                    Text(
                      '${page.outputWidth}×${page.outputHeight}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                        fontSize: 9,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberBadge extends StatelessWidget {
  const _NumberBadge({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          '$number',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _TileBadge extends StatelessWidget {
  const _TileBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: Colors.white),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.canExport,
    required this.exporting,
    required this.onCapture,
    required this.onImport,
    required this.onExport,
  });

  final bool canExport;
  final bool exporting;
  final VoidCallback? onCapture;
  final VoidCallback? onImport;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            OutlinedButton(
              key: const Key('import-button'),
              onPressed: onImport,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
              ),
              child: const Icon(Icons.photo_library_outlined),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                key: const Key('capture-button'),
                onPressed: onCapture,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('连续拍摄'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              key: const Key('export-button'),
              onPressed: canExport && !exporting ? onExport : null,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
              ),
              icon: exporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('PDF'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportRunnerDialog extends StatefulWidget {
  const _ExportRunnerDialog({required this.controller, required this.options});

  final DocumentController controller;
  final ExportOptions options;

  @override
  State<_ExportRunnerDialog> createState() => _ExportRunnerDialogState();
}

class _ExportRunnerDialogState extends State<_ExportRunnerDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      final result = await widget.controller.exportPdf(
        fileName: widget.options.fileName,
        fitA4: widget.options.fitA4,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return AlertDialog(
        title: const Text('导出失败'),
        content: SelectableText(_error!),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => ExportProgressDialog(
        progress: widget.controller.exportProgress,
        totalPages: widget.controller.document?.pages.length ?? 0,
      ),
    );
  }
}
