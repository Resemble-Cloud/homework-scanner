import 'package:flutter/material.dart';

import '../../services/pdf_export_service.dart';
import '../../services/session_store.dart';

class ExportOptions {
  const ExportOptions({required this.fileName, required this.fitA4});

  final String fileName;
  final bool fitA4;
}

Future<ExportOptions?> showExportOptionsDialog(
  BuildContext context, {
  required int pageCount,
  DateTime? now,
}) {
  final defaultName = defaultPdfFileName(now);
  return showDialog<ExportOptions>(
    context: context,
    builder: (context) => _ExportOptionsDialog(
      pageCount: pageCount,
      initialName: defaultName.substring(0, defaultName.length - 4),
    ),
  );
}

class _ExportOptionsDialog extends StatefulWidget {
  const _ExportOptionsDialog({
    required this.pageCount,
    required this.initialName,
  });

  final int pageCount;
  final String initialName;

  @override
  State<_ExportOptionsDialog> createState() => _ExportOptionsDialogState();
}

class _ExportOptionsDialogState extends State<_ExportOptionsDialog> {
  late final TextEditingController _name;
  bool _fitA4 = true;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导出 PDF'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('pdf-name-field'),
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: '文件名',
              suffixText: '.pdf',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const Key('fit-a4-checkbox'),
            value: _fitA4,
            onChanged: (value) => setState(() => _fitA4 = value ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('适配 A4'),
            subtitle: const Text('关闭则每页按图片宽高比定尺寸'),
          ),
          Text(
            '${widget.pageCount} 页 · 处理后的图片直接嵌入，不二次压缩',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm-export-button'),
          onPressed: _submit,
          child: const Text('导出'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入文件名')));
      return;
    }
    Navigator.of(context).pop(ExportOptions(fileName: name, fitA4: _fitA4));
  }
}

class ExportProgressDialog extends StatelessWidget {
  const ExportProgressDialog({
    super.key,
    required this.progress,
    required this.totalPages,
  });

  final PdfExportProgress? progress;
  final int totalPages;

  @override
  Widget build(BuildContext context) {
    final current = progress;
    final done = current?.donePages ?? 0;
    return AlertDialog(
      title: const Text('正在导出 PDF'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: totalPages == 0 ? null : done / totalPages,
          ),
          const SizedBox(height: 12),
          Text(
            current == null
                ? '准备中…'
                : '${current.currentLabel} · $done / $totalPages 页',
          ),
          const SizedBox(height: 4),
          Text(
            '逐页读取，避免多页图像同时占用内存',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

Future<void> showExportResultDialog(
  BuildContext context, {
  required PdfExportResult result,
  required Future<void> Function() onShare,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('导出完成'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${result.pageCount} 页 · ${result.sizeLabel}'),
          const SizedBox(height: 8),
          SelectableText(
            result.path,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          const Text('点“分享 / 保存”可打开系统对话框，另存到文件、网盘或发送。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('完成'),
        ),
        FilledButton.icon(
          key: const Key('share-pdf-button'),
          onPressed: () async {
            try {
              await onShare();
            } catch (error) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text('打开分享面板失败：$error\n${result.path}')),
                );
              }
            }
          },
          icon: const Icon(Icons.ios_share),
          label: const Text('分享 / 保存'),
        ),
      ],
    ),
  );
}
