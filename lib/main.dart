import 'dart:io';

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const HomeworkScannerApp());
}

Future<String?> pickImageWithGallery() async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  return picked?.path;
}

class HomeworkScannerApp extends StatelessWidget {
  const HomeworkScannerApp({super.key, this.engine, this.pickImage});

  /// Injectable for widget tests.
  final ScanEngine? engine;
  final Future<String?> Function()? pickImage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '作业扫描 Sprint 0',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E6F5E),
        useMaterial3: true,
      ),
      home: ScannerPage(
        engine: engine ?? FairScanEngine(),
        pickImage: pickImage ?? pickImageWithGallery,
      ),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({
    super.key,
    required this.engine,
    required this.pickImage,
  });

  final ScanEngine engine;
  final Future<String?> Function() pickImage;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  ScanColorMode _colorMode = ScanColorMode.auto;
  String? _sourcePath;
  ScanResult? _result;
  ScanEngineException? _error;
  bool _busy = false;

  Future<void> _pickAndScan() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final path = await widget.pickImage();
      if (path == null) {
        return;
      }
      _sourcePath = path;
      await _scan(path);
    } on ScanEngineException catch (error) {
      _error = error;
    } catch (error) {
      _error = ScanEngineException('UNEXPECTED', '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rescan() async {
    final path = _sourcePath;
    if (path == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      await _scan(path);
    } on ScanEngineException catch (error) {
      _error = error;
    } catch (error) {
      _error = ScanEngineException('UNEXPECTED', '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan(String path) async {
    final result = await widget.engine.scan(
      path,
      options: ScanOptions(colorMode: _colorMode),
    );
    if (!mounted) return;
    setState(() => _result = result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('作业扫描 · Sprint 0')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Controls(
            colorMode: _colorMode,
            busy: _busy,
            canRescan: _sourcePath != null,
            onColorModeChanged: (mode) => setState(() => _colorMode = mode),
            onPick: _pickAndScan,
            onRescan: _rescan,
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text('原生引擎处理中（检测 → 透视矫正 → 增强）…', style: theme.textTheme.bodySmall),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            _ErrorCard(error: _error!),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            _Images(sourcePath: _sourcePath, result: _result!),
            const SizedBox(height: 16),
            _TimingsCard(timings: _result!.timings),
            const SizedBox(height: 16),
            _OutputCard(result: _result!),
          ],
          const SizedBox(height: 24),
          _EngineInfoCard(engine: widget.engine),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.colorMode,
    required this.busy,
    required this.canRescan,
    required this.onColorModeChanged,
    required this.onPick,
    required this.onRescan,
  });

  final ScanColorMode colorMode;
  final bool busy;
  final bool canRescan;
  final ValueChanged<ScanColorMode> onColorModeChanged;
  final VoidCallback onPick;
  final VoidCallback onRescan;

  static const _labels = <ScanColorMode, String>{
    ScanColorMode.auto: '自动（彩色/灰度）',
    ScanColorMode.color: '彩色',
    ScanColorMode.grayscale: '灰度增强',
    ScanColorMode.blackAndWhite: '黑白（二值化）',
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<ScanColorMode>(
              initialValue: colorMode,
              decoration: const InputDecoration(
                labelText: '色彩模式',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _labels.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: busy
                  ? null
                  : (value) {
                      if (value != null) onColorModeChanged(value);
                    },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('pick-button'),
                    onPressed: busy ? null : onPick,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('选择图片并扫描'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: busy || !canRescan ? null : onRescan,
                  child: const Text('重新扫描'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final ScanEngineException error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '处理失败',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    '${error.code}: ${error.message}',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '原图未被修改。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
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

class _Images extends StatelessWidget {
  const _Images({required this.sourcePath, required this.result});

  final String? sourcePath;
  final ScanResult result;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ImagePanel(
          key: const Key('source-image'),
          title: '原图',
          subtitle: sourcePath == null ? '' : _fileName(sourcePath!),
          path: sourcePath,
        ),
        const SizedBox(height: 12),
        _ImagePanel(
          key: const Key('result-image'),
          title: '处理后',
          subtitle:
              '${_fileName(result.outputPath)} · '
              '${result.outputWidth}×${result.outputHeight}',
          path: result.outputPath,
          highlight: true,
        ),
      ],
    );
  }
}

class _ImagePanel extends StatelessWidget {
  const _ImagePanel({
    super.key,
    required this.title,
    required this.subtitle,
    required this.path,
    this.highlight = false,
  });

  final String title;
  final String subtitle;
  final String? path;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: highlight
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subtitle,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 320,
            child: path == null
                ? const ColoredBox(color: Colors.black12)
                : Image.file(
                    File(path!),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          '无法读取图片文件',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TimingsCard extends StatelessWidget {
  const _TimingsCard({required this.timings});

  final ScanStageTimings timings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxMs = timings.entries
        .where((entry) => entry.$1 != '总计')
        .fold<int>(1, (max, entry) => entry.$2 > max ? entry.$2 : max);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('各阶段耗时', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final entry in timings.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(width: 88, child: Text(entry.$1)),
                    Expanded(
                      child: LinearProgressIndicator(
                        key: Key('timing-${entry.$1}'),
                        value: entry.$2 / maxMs,
                        minHeight: 6,
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: Text(
                        '${entry.$2} ms',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall,
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

class _OutputCard extends StatelessWidget {
  const _OutputCard({required this.result});

  final ScanResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('输出文件', result.outputPath),
      ('分辨率', '${result.outputWidth}×${result.outputHeight}'),
      ('文件大小', result.fileSizeLabel),
      ('原图尺寸', '${result.sourceWidth}×${result.sourceHeight}'),
      ('色彩模式', '${result.colorMode.wireName}（自动判定：${result.autoColorMode.wireName}）'),
      ('纸张检测', result.detected ? '成功（${result.detectionStage}）' : '未检出（整图输出）'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('输出信息', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 88,
                      child: Text(row.$1, style: theme.textTheme.bodySmall),
                    ),
                    Expanded(
                      child: SelectableText(
                        row.$2,
                        style: theme.textTheme.bodySmall,
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

class _EngineInfoCard extends StatelessWidget {
  const _EngineInfoCard({required this.engine});

  final ScanEngine engine;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EngineInfo>(
      future: engine.engineInfo(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final text = info == null
            ? (snapshot.hasError ? '引擎信息不可用：${snapshot.error}' : '引擎加载中…')
            : '模型 ${info.modelAsset} · OpenCV ${info.opencvVersion} · '
                  '${info.initialized ? "已就绪" : "未初始化"}';
        return Text(
          'FairScan 引擎：$text',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        );
      },
    );
  }
}

String _fileName(String path) => path.split(Platform.pathSeparator).last;
