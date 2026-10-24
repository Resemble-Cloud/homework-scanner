import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/scan_document.dart';
import '../../services/document_controller.dart';
import '../../services/share_service.dart';
import '../document/document_screen.dart';

/// Minimal document library: one card per scan session, one primary action to
/// start a new scan. Keeping this screen at the root is what allows a session
/// to be finished and a second document to be started without reinstall/clear.
class DocumentLibraryPage extends StatefulWidget {
  const DocumentLibraryPage({
    super.key,
    required this.controller,
    this.pickImage,
    this.pickImages,
    this.sharePdfCallback,
  });

  final DocumentController controller;
  final Future<String?> Function()? pickImage;
  final Future<List<String>> Function()? pickImages;
  final PdfShareCallback? sharePdfCallback;

  @override
  State<DocumentLibraryPage> createState() => _DocumentLibraryPageState();
}

class _DocumentLibraryPageState extends State<DocumentLibraryPage> {
  List<ScanDocument> _documents = const <ScanDocument>[];
  bool _loading = true;
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final documents = await widget.controller.store.listDocuments();
      if (!mounted) return;
      setState(() {
        _documents = documents;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _createAndOpen() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final document = await widget.controller.store.createDocument();
      await _openDocument(document);
    } catch (error) {
      if (mounted) _snack('新建文档失败：$error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _openDocument(ScanDocument document) async {
    try {
      await widget.controller.openDocument(document.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DocumentScreen(
            controller: widget.controller,
            pickImage: widget.pickImage,
            pickImages: widget.pickImages,
            sharePdfCallback: widget.sharePdfCallback,
          ),
        ),
      );
      await _reload();
    } catch (error) {
      if (mounted) _snack('打开文档失败：$error');
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的扫描'),
        actions: [
          IconButton(
            key: const Key('new-document-action'),
            tooltip: '新建文档',
            onPressed: _opening ? null : _createAndOpen,
            icon: const Icon(Icons.note_add_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('读取文档失败：$_error'),
                ),
              )
            : _documents.isEmpty
            ? _EmptyLibrary(onScan: _createAndOpen)
            : RefreshIndicator(
                onRefresh: _reload,
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.64,
                  ),
                  itemCount: _documents.length,
                  itemBuilder: (context, index) {
                    final document = _documents[index];
                    return _DocumentCard(
                      key: Key('document-${document.id}'),
                      document: document,
                      onTap: _opening ? null : () => _openDocument(document),
                    );
                  },
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('scan-new-document'),
        onPressed: _opening ? null : _createAndOpen,
        icon: const Icon(Icons.document_scanner_outlined),
        label: Text(_opening ? '打开中…' : '扫描新文档'),
        backgroundColor: theme.colorScheme.primaryContainer,
        foregroundColor: theme.colorScheme.onPrimaryContainer,
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onScan});

  final VoidCallback onScan;

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
            Text('还没有扫描文档', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '拍完一份文档后可回到这里，继续新建下一份；\n每份文档独立保存原图与处理结果。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('empty-new-document'),
              onPressed: onScan,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('扫描第一份文档'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({super.key, required this.document, required this.onTap});

  final ScanDocument document;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _previewPath(document);
    final pending = document.hasPending;
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
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
                  if (preview != null && File(preview).existsSync())
                    Image.file(
                      File(preview),
                      key: ValueKey(preview),
                      fit: BoxFit.cover,
                      cacheWidth: 600,
                      errorBuilder: (_, _, _) => const _Placeholder(),
                    )
                  else
                    const _Placeholder(),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: _PageCountBadge(count: document.pages.length),
                  ),
                  if (pending)
                    const Positioned(
                      left: 8,
                      top: 8,
                      child: _SmallBadge(
                        label: '处理中',
                        color: Color(0xFF2E6F5E),
                      ),
                    )
                  else if (document.hasFailures)
                    const Positioned(
                      left: 8,
                      top: 8,
                      child: _SmallBadge(
                        label: '有失败页',
                        color: Color(0xFFB3261E),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_dateLabel(document.updatedAt)}'
                    ' · ${document.pages.length} 页'
                    '${document.isExported ? ' · 已导出' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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

  String? _previewPath(ScanDocument document) {
    for (final page in document.pages) {
      final path = page.displayPath;
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  String _dateLabel(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.month}/${date.day} ${two(date.hour)}:${two(date.minute)}';
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.description_outlined, size: 42)),
    );
  }
}

class _PageCountBadge extends StatelessWidget {
  const _PageCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          '$count 页',
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    );
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.label, required this.color});

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
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      ),
    );
  }
}
