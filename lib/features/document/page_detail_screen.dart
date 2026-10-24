import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';

import '../../models/scan_document.dart';
import '../../services/document_controller.dart';
import '../../widgets/quad_editor_sheet.dart';
import '../camera/camera_capture_screen.dart';

class PageDetailScreen extends StatelessWidget {
  const PageDetailScreen({
    super.key,
    required this.controller,
    required this.pageId,
  });

  final DocumentController controller;
  final String pageId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final document = controller.document;
        final page = controller.pageById(pageId);
        if (document == null || page == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('页面')),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('页面已删除'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('返回'),
                  ),
                ],
              ),
            ),
          );
        }
        final number = document.pageNumber(page.id);
        return Scaffold(
          appBar: AppBar(
            title: Text('第 $number 页'),
            actions: [
              IconButton(
                tooltip: '删除此页',
                onPressed: () => _confirmDelete(context, page),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _PagePreview(page: page),
              const SizedBox(height: 12),
              _StatusRow(page: page),
              if (page.candidates.length > 1) ...[
                const SizedBox(height: 12),
                _CandidateSelector(
                  page: page,
                  enabled: !_busy(page),
                  onSelected: (candidate) =>
                      _applyCandidate(context, page, candidate),
                ),
              ],
              if (page.needsReview) ...[
                const SizedBox(height: 12),
                _ReviewCard(
                  page: page,
                  enabled: !_busy(page),
                  onCorrect: () => _editQuad(context, page, number),
                  onUseDefault: () => _useDefault(context, page),
                ),
              ],
              if (page.status == PageStatus.failed) ...[
                const SizedBox(height: 12),
                _FailureCard(
                  page: page,
                  onRetry: () => controller.retryPage(page.id),
                ),
              ],
              const SizedBox(height: 16),
              Text('色彩模式', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final mode in ScanColorMode.values)
                    _ModeChip(
                      mode: mode,
                      selected: page.colorMode == mode,
                      enabled: !_busy(page),
                      onSelected: () => _setMode(context, page, mode),
                    ),
                ],
              ),
              SwitchListTile(
                key: const Key('shadow-flatten-switch'),
                contentPadding: EdgeInsets.zero,
                value: page.shadowFlatten,
                onChanged: _busy(page)
                    ? null
                    : (value) => _setShadowFlatten(context, page, value),
                title: const Text('去阴影'),
                subtitle: const Text('轻度压平大面积光照不均；关闭可恢复 Sprint 2 输出'),
              ),
              const SizedBox(height: 12),
              Text('页面操作', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const Key('edit-quad-button'),
                    onPressed: _busy(page)
                        ? null
                        : () => _editQuad(context, page, number),
                    icon: const Icon(Icons.crop_free),
                    label: const Text('重新裁剪'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('retake-button'),
                    onPressed: _busy(page) ? null : () => _retake(context),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('重拍'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy(page)
                        ? null
                        : () => _confirmDelete(context, page),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _PageFacts(page: page),
            ],
          ),
        );
      },
    );
  }

  bool _busy(ScanPage page) =>
      page.status == PageStatus.processing || page.status == PageStatus.queued;

  Future<void> _setMode(
    BuildContext context,
    ScanPage page,
    ScanColorMode mode,
  ) async {
    try {
      await controller.setColorMode(page.id, mode);
    } catch (error) {
      if (context.mounted) _snack(context, '切换色彩模式失败：$error');
    }
  }

  Future<void> _setShadowFlatten(
    BuildContext context,
    ScanPage page,
    bool enabled,
  ) async {
    try {
      await controller.setShadowFlatten(page.id, enabled);
      if (context.mounted) {
        _snack(context, enabled ? '已开启去阴影，正在重新处理' : '已关闭去阴影，正在重新处理');
      }
    } catch (error) {
      if (context.mounted) _snack(context, '切换去阴影失败：$error');
    }
  }

  Future<void> _editQuad(
    BuildContext context,
    ScanPage page,
    int number,
  ) async {
    final quad = await showQuadEditor(
      context,
      sourcePath: page.originalPath,
      initialQuad: page.quad,
      reason: page.needsReview
          ? page.reviewReason
          : '拖动四角，把第 $number 页完整框住（原图会保留）',
    );
    if (quad == null || !context.mounted) return;
    try {
      await controller.setManualQuad(page.id, quad);
      if (context.mounted) _snack(context, '已应用手动四角，正在重新处理');
    } catch (error) {
      if (context.mounted) _snack(context, '应用四角失败：$error');
    }
  }

  Future<void> _useDefault(BuildContext context, ScanPage page) async {
    try {
      await controller.useDefaultQuad(page.id);
      if (context.mounted) _snack(context, '已改用整图内缩 2% 重新处理');
    } catch (error) {
      if (context.mounted) _snack(context, '操作失败：$error');
    }
  }

  Future<void> _applyCandidate(
    BuildContext context,
    ScanPage page,
    QuadCandidate candidate,
  ) async {
    try {
      await controller.applyCandidate(page.id, candidate);
      if (context.mounted) {
        _snack(context, '已切换为${_candidateLabel(candidate)}，正在重新处理');
      }
    } catch (error) {
      if (context.mounted) _snack(context, '切换候选框失败：$error');
    }
  }

  Future<void> _retake(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            CameraCaptureScreen(controller: controller, retakePageId: pageId),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, ScanPage page) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这一页？'),
        content: const Text('原图和处理结果都会从本文档移除，无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await controller.deletePage(page.id);
    if (context.mounted) Navigator.of(context).pop();
  }

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

class _PagePreview extends StatelessWidget {
  const _PagePreview({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = File(page.displayPath);
    final showSpinner =
        page.status == PageStatus.processing ||
        page.status == PageStatus.queued;
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (file.existsSync())
            InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Image.file(
                file,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Center(
                  child: Text('无法读取图片', style: TextStyle(color: Colors.white)),
                ),
              ),
            )
          else
            Center(
              child: Text(
                page.status == PageStatus.failed ? '处理失败，原图仍保留' : '等待处理结果…',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          if (showSpinner)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.30),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 10),
                    Text(
                      page.status.label,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(
            left: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  page.processedPath == null ? '原图预览' : '处理结果',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (page.status) {
      PageStatus.done => theme.colorScheme.primary,
      PageStatus.failed => theme.colorScheme.error,
      _ => theme.colorScheme.tertiary,
    };
    return Row(
      children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 6),
        Text(
          page.status.label,
          style: theme.textTheme.labelLarge?.copyWith(color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            page.quadSource.label,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _CandidateSelector extends StatelessWidget {
  const _CandidateSelector({
    required this.page,
    required this.enabled,
    required this.onSelected,
  });

  final ScanPage page;
  final bool enabled;
  final ValueChanged<QuadCandidate> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('裁切候选', style: theme.textTheme.titleSmall),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('优先保留纸面，再减少桌面', style: theme.textTheme.bodySmall),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final candidate in page.candidates)
                  Tooltip(
                    message:
                        '保留纸面 ${(candidate.coverage * 100).round()}%'
                        ' · 背景 ${(candidate.background * 100).round()}%'
                        ' · 占画面 ${(candidate.frameFill * 100).round()}%',
                    child: ChoiceChip(
                      label: Text(_candidateLabel(candidate)),
                      selected: _candidateSelected(candidate),
                      onSelected: enabled && !_candidateSelected(candidate)
                          ? (_) => onSelected(candidate)
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _candidateSelected(QuadCandidate candidate) {
    final source = switch (candidate.source) {
      'import' => QuadSource.import,
      'capture' => QuadSource.capture,
      'paper_outer' => QuadSource.paperOuter,
      _ => QuadSource.fallback,
    };
    if (source == QuadSource.import || source == QuadSource.capture) {
      return page.quadSource == QuadSource.import ||
          page.quadSource == QuadSource.capture;
    }
    return page.quadSource == source;
  }
}

String _candidateLabel(QuadCandidate candidate) => switch (candidate.source) {
  'import' || 'capture' => '检测框',
  'paper_outer' => '纸面外框',
  _ => '整图 2%',
};

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.page,
    required this.enabled,
    required this.onCorrect,
    required this.onUseDefault,
  });

  final ScanPage page;
  final bool enabled;
  final VoidCallback onCorrect;
  final VoidCallback onUseDefault;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFF3E0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFB26A00),
                ),
                const SizedBox(width: 8),
                Text(
                  '建议检查',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: const Color(0xFF8A5300)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              page.reviewReason ?? '检测结果不可靠，建议确认四角。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('review-correct-button'),
                  onPressed: enabled ? onCorrect : null,
                  icon: const Icon(Icons.crop_free),
                  label: const Text('修正四角'),
                ),
                TextButton(
                  onPressed: enabled ? onUseDefault : null,
                  child: const Text('整图内缩 2%'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.page, required this.onRetry});

  final ScanPage page;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '处理失败，原图未修改',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 4),
            SelectableText(
              '${page.errorCode ?? 'UNKNOWN'}: ${page.errorMessage ?? ''}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('retry-page-button'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final ScanColorMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final label = switch (mode) {
      ScanColorMode.auto => '自动',
      ScanColorMode.color => '彩色',
      ScanColorMode.grayscale => '灰度',
      ScanColorMode.blackAndWhite => '黑白',
    };
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: enabled ? (_) => onSelected() : null,
    );
  }
}

class _PageFacts extends StatelessWidget {
  const _PageFacts({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('原图', page.originalPath),
      ('处理结果', page.processedPath ?? '—'),
      ('最终四角来源', page.quadSource.label),
      ('去阴影', page.shadowFlatten ? '开启' : '关闭'),
      if (page.engineStage != null) ('引擎检测入口', page.engineStage!),
      if (page.detectionScore != null)
        ('检测置信度', page.detectionScore!.toStringAsFixed(3)),
      if (page.detectionFrameFill != null)
        ('取景占比', page.detectionFrameFill!.toStringAsFixed(3)),
      if (page.outputWidth != null)
        ('输出尺寸', '${page.outputWidth}×${page.outputHeight}'),
      if (page.fileBytes != null)
        ('文件大小', '${(page.fileBytes! / 1024).toStringAsFixed(0)} KB'),
      if (page.processingMs != null)
        ('处理耗时', '${(page.processingMs! / 1000).toStringAsFixed(2)} s'),
      if (page.engineMs != null)
        ('引擎耗时', '${(page.engineMs! / 1000).toStringAsFixed(2)} s'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('页面信息', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 92,
                      child: Text(
                        row.$1,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        row.$2,
                        style: Theme.of(context).textTheme.bodySmall,
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
