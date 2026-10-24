import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fairscan_engine/fairscan_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Below this mean segmentation probability the detected quad is likely
/// clipping page content, so we ask the user to confirm the corners instead of
/// trusting it. Calibrated against the fixed samples 1/4/5/7 (see docs/quality/).
const double kQuadScoreThreshold = 0.85;

/// Output pixel budgets. 2 MP is FairScan's BALANCED default; 4 MP keeps small
/// text and sub/superscripts legible after perspective correction.
enum ScanQuality {
  balanced2mp('平衡 2MP', 2000000),
  high4mp('高细节 4MP', 4000000);

  const ScanQuality(this.label, this.maxPixels);

  final String label;
  final int maxPixels;
}

void main() {
  // Debug-only headless batch runner for Sprint 1 evidence collection. It is
  // gated on kDebugMode and an explicit --dart-define flag so release builds
  // keep the normal app entry point and never run scans on startup.
  const batchFlag = String.fromEnvironment('EVIDENCE_BATCH');
  if (kDebugMode && batchFlag.isNotEmpty) {
    runApp(
      _EvidenceBatchApp(
        manifestPath: batchFlag,
        engine: FairScanEngine(),
      ),
    );
    return;
  }
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
  ScanQuality _quality = ScanQuality.high4mp;
  String? _sourcePath;
  ScanResult? _result;
  ScanEngineException? _error;
  bool _busy = false;
  String _stageLabel = '';
  List<NormalizedPoint>? _quad;
  DetectResult? _detect;

  Future<void> _pickAndScan() async {
    final path = await widget.pickImage();
    if (path == null) return;
    setState(() {
      _sourcePath = path;
      _quad = null;
      _detect = null;
    });
    await _detectAndScan(path);
  }

  Future<void> _rescan() async {
    final path = _sourcePath;
    if (path == null) return;
    await _detectAndScan(path);
  }

  /// Sprint 1: detect first so a poor frame is caught before it silently drops
  /// formulas. Auto continues; a weak or missing quad opens the corner editor.
  Future<void> _detectAndScan(String path) async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _stageLabel = '检测纸张…';
    });
    try {
      final detect = await widget.engine.detectDocument(path);
      if (!mounted) return;
      setState(() {
        _detect = detect;
        _quad = detect.quad;
      });
      if (!detect.detected || detect.score < kQuadScoreThreshold) {
        final coverage = detect.coverage;
        final fill = detect.frameFill;
        _stageLabel = !detect.detected
            ? '未自动检出纸张，请手动框选四角'
            : fill != null && fill < 0.5
            ? '检测框只占取景框 ${(fill * 100).round()}%，可能只框住纸面一部分，请确认四角'
            : coverage != null && coverage < 0.85
            ? '检测框只覆盖了 ${(coverage * 100).round()}% 的纸面，可能漏掉内容，请确认四角'
            : '检测置信度偏低（${detect.score.toStringAsFixed(2)}），请确认四角';
        // The editor is user input, not processing: drop the busy flag so the
        // indeterminate spinner behind the sheet stops ticking. Left running it
        // would schedule frames forever (and hang pumpAndSettle in tests).
        if (mounted) setState(() => _busy = false);
        await _openQuadEditor(path);
        return;
      }
      await _scan(path);
    } on ScanEngineException catch (error) {
      _error = error;
    } catch (error) {
      _error = ScanEngineException('UNEXPECTED', '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          // Errors render their own card; don't leave a stale stage line up.
          if (_error != null) _stageLabel = '';
        });
      }
    }
  }

  Future<void> _openQuadEditor(String path) async {
    final quad = await showModalBottomSheet<List<NormalizedPoint>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _QuadEditorSheet(
        engine: widget.engine,
        sourcePath: path,
        initialQuad: _quad,
      ),
    );
    if (quad == null || !mounted) return;
    setState(() => _quad = quad);
    await _scan(path);
  }

  Future<void> _scan(String path) async {
    setState(() {
      _busy = true;
      _stageLabel = '透视矫正 + 增强…';
    });
    final result = await widget.engine.scan(
      path,
      options: ScanOptions(
        colorMode: _colorMode,
        maxPixels: _quality.maxPixels,
        quad: _quad,
      ),
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _stageLabel = '';
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('作业扫描 · Sprint 1')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Controls(
            colorMode: _colorMode,
            quality: _quality,
            busy: _busy,
            canRescan: _sourcePath != null,
            onColorModeChanged: (mode) => setState(() => _colorMode = mode),
            onQualityChanged: (quality) => setState(() => _quality = quality),
            onPick: _pickAndScan,
            onRescan: _rescan,
            onEditQuad: _sourcePath == null
                ? null
                : () => _openQuadEditor(_sourcePath!),
          ),
          if (_busy || _stageLabel.isNotEmpty) ...[
            const SizedBox(height: 16),
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
            ],
            Text(
              _stageLabel.isEmpty ? '原生引擎处理中…' : _stageLabel,
              style: theme.textTheme.bodySmall,
            ),
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
            _OutputCard(result: _result!, detect: _detect),
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
    required this.quality,
    required this.busy,
    required this.canRescan,
    required this.onColorModeChanged,
    required this.onQualityChanged,
    required this.onPick,
    required this.onRescan,
    this.onEditQuad,
  });

  final ScanColorMode colorMode;
  final ScanQuality quality;
  final bool busy;
  final bool canRescan;
  final ValueChanged<ScanColorMode> onColorModeChanged;
  final ValueChanged<ScanQuality> onQualityChanged;
  final VoidCallback onPick;
  final VoidCallback onRescan;
  final VoidCallback? onEditQuad;

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
            SegmentedButton<ScanQuality>(
              segments: ScanQuality.values
                  .map(
                    (quality) => ButtonSegment(
                      value: quality,
                      label: Text(quality.label),
                    ),
                  )
                  .toList(),
              selected: {quality},
              onSelectionChanged: busy
                  ? null
                  : (selection) => onQualityChanged(selection.first),
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
            if (onEditQuad != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : onEditQuad,
                icon: const Icon(Icons.crop),
                label: const Text('手动调整四角'),
              ),
            ],
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
  const _OutputCard({required this.result, this.detect});

  final ScanResult result;
  final DetectResult? detect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detection = detect;
    final rows = <(String, String)>[
      ('输出文件', result.outputPath),
      ('分辨率', '${result.outputWidth}×${result.outputHeight}'),
      ('文件大小', result.fileSizeLabel),
      ('原图尺寸', '${result.sourceWidth}×${result.sourceHeight}'),
      ('色彩模式', '${result.colorMode.wireName}（自动判定：${result.autoColorMode.wireName}）'),
      ('纸张检测', result.detected ? '成功（${result.detectionStage}）' : '未检出（整图输出）'),
      if (detection != null && detection.detected)
        ('检测置信度', detection.score.toStringAsFixed(3)),
      // Split the confidence into its two halves so a frame that lands inside
      // the page (high paper fill, low coverage) is obvious on screen.
      if (detection?.meanProb != null)
        ('纸面占比', detection!.meanProb!.toStringAsFixed(3)),
      if (detection?.coverage != null)
        ('纸面覆盖', detection!.coverage!.toStringAsFixed(3)),
      if (detection?.frameFill != null)
        ('取景占比', detection!.frameFill!.toStringAsFixed(3)),
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

/// Full-screen editor showing the source image with four draggable corners.
/// Reuses the engine only for a quick 1 MP preview render on confirm, so the
/// expensive re-scan happens once, on the real quad, in the parent page.
class _QuadEditorSheet extends StatefulWidget {
  const _QuadEditorSheet({
    required this.engine,
    required this.sourcePath,
    required this.initialQuad,
  });

  final ScanEngine engine;
  final String sourcePath;
  final List<NormalizedPoint>? initialQuad;

  @override
  State<_QuadEditorSheet> createState() => _QuadEditorSheetState();
}

class _QuadEditorSheetState extends State<_QuadEditorSheet> {
  static const double _handleRadius = 26;

  /// Size of the displayed (letterboxed) image inside the overlay.
  Size _displaySize = Size.zero;
  Offset _displayOffset = Offset.zero;
  Size _containerSize = Size.zero;

  /// Decoded pixel size of the source image, needed to letterbox correctly.
  Size? _imageSize;

  /// Working quad in normalized [0,1] coords, top-left first.
  late List<NormalizedPoint> _quad;

  @override
  void initState() {
    super.initState();
    _quad = widget.initialQuad ??
        const [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)];
    _resolveImageSize();
  }

  /// Decodes intrinsic dimensions once so letterboxing is exact. Uses a
  /// one-shot codec rather than an [ImageStreamListener] so no stream stays
  /// pending — that would keep [WidgetTester.pumpAndSettle] from ever settling.
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
      if (mounted && _imageSize != size) {
        setState(() => _imageSize = size);
      }
    } catch (_) {
      // Leave _imageSize null; the overlay falls back to BoxFit.contain only.
    }
  }

  Offset _toScreen(int index, double scale) => Offset(
        _displayOffset.dx + _quad[index].$1 * _displaySize.width,
        _displayOffset.dy + _quad[index].$2 * _displaySize.height,
      );

  void _updateQuad(int index, Offset screenPos, double scale) {
    final dx = ((screenPos.dx - _displayOffset.dx) / _displaySize.width)
        .clamp(0.0, 1.0);
    final dy = ((screenPos.dy - _displayOffset.dy) / _displaySize.height)
        .clamp(0.0, 1.0);
    setState(() {
      _quad = [
        for (int i = 0; i < 4; i++)
          if (i == index)
            (dx, dy)
          else
            _quad[i]
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
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
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _containerSize = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  return GestureDetector(
                    onPanUpdate: (details) {},
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(widget.sourcePath),
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stack) => const Center(
                            child: Text('无法读取原图'),
                          ),
                        ),
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, bc) {
                              _containerSize = Size(
                                bc.maxWidth,
                                bc.maxHeight,
                              );
                              final imageSize = _imageSize ?? Size.zero;
                              if (imageSize == Size.zero) {
                                return const SizedBox.shrink();
                              }
                              _computeLayout(imageSize);
                              final scale = _displaySize.width > 0
                                  ? _containerSize.width / _displaySize.width
                                  : 1.0;
                              return Stack(
                                children: [
                                  Positioned.fromRect(
                                    rect: Rect.fromLTWH(
                                      _displayOffset.dx,
                                      _displayOffset.dy,
                                      _displaySize.width,
                                      _displaySize.height,
                                    ),
                                    child: CustomPaint(
                                      painter: _QuadPainter(_quad),
                                    ),
                                  ),
                                  for (int i = 0; i < 4; i++)
                                    _CornerHandle(
                                      key: ValueKey('corner-$i'),
                                      position: _toScreen(i, scale),
                                      radius: _handleRadius,
                                      onDrag: (pos) =>
                                          _updateQuad(i, pos, scale),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(_quad),
                      child: const Text('重置为默认'),
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
    );
  }

  void _computeLayout(Size imageSize) {
    if (imageSize == Size.zero || _containerSize == Size.zero) return;
    final ratio = imageSize.width / imageSize.height;
    final containerRatio = _containerSize.width / _containerSize.height;
    final display = ratio > containerRatio
        ? Size(_containerSize.width, _containerSize.width / ratio)
        : Size(_containerSize.height * ratio, _containerSize.height);
    final offset = Offset(
      (_containerSize.width - display.width) / 2,
      (_containerSize.height - display.height) / 2,
    );
    if (display != _displaySize || offset != _displayOffset) {
      setState(() {
        _displaySize = display;
        _displayOffset = offset;
      });
    }
  }
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
        onPanUpdate: (details) => onDrag(position + details.delta),
        child: Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.35),
            border: Border.all(color: color, width: 2.5),
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
    final fill = Paint()..color = const Color(0x33000000);
    final stroke = Paint()
      ..color = const Color(0xFFE53935)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(quad[0].$1 * size.width, quad[0].$2 * size.height);
    for (int i = 1; i < quad.length; i++) {
      path.lineTo(quad[i].$1 * size.width, quad[i].$2 * size.height);
    }
    path.close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(_QuadPainter oldDelegate) =>
      oldDelegate.quad.toString() != quad.toString();
}

/// Debug-only headless driver that runs the real engine over a JSON manifest
/// of fixed samples and writes the Sprint 1 evidence bundle (per-sample output
/// at both budgets, detection overlays, and a metrics summary).
///
/// Manifest format:
/// ```json
/// { "outDir": "/sdcard/…/evidence", "jobs": [
///     { "source": "…/1.jpg", "id": "hw1",
///       "modes": ["GRAYSCALE"], "budgets": [2000000, 4000000] }
/// ] }
/// ```
/// Every job runs detect + scan per (mode, budget). Results are printed as one
/// `EVIDENCE_JSON: {...}` line so `adb logcat` can be parsed by the collector.
class _EvidenceBatchApp extends StatefulWidget {
  const _EvidenceBatchApp({required this.manifestPath, required this.engine});

  final String manifestPath;
  final ScanEngine engine;

  @override
  State<_EvidenceBatchApp> createState() => _EvidenceBatchAppState();
}

class _EvidenceBatchAppState extends State<_EvidenceBatchApp> {
  String _status = 'starting';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final out = <String, Object?>{'started': true};
    try {
      final manifest = jsonDecode(await File(widget.manifestPath).readAsString())
          as Map<String, dynamic>;
      final outDir = Directory(manifest['outDir'] as String);
      await outDir.create(recursive: true);
      final jobs = (manifest['jobs'] as List).cast<Map<String, dynamic>>();
      await widget.engine.initialize();
      final results = <Map<String, Object?>>[];
      for (final job in jobs) {
        final source = job['source'] as String;
        final id = job['id'] as String;
        final modes = (job['modes'] as List).cast<String>();
        final budgets = (job['budgets'] as List).cast<num>();
        final detect = await widget.engine.detectDocument(source);
        // Detection overlay: shows exactly what the quad includes, so a
        // clipped formula is visible in review.
        final overlay = await detect.renderQuadOverlay(source);
        if (overlay != null) {
          await File('${outDir.path}/${id}_detect.png').writeAsBytes(overlay);
        }
        results.add({
          'id': id,
          'source': source,
          'detect': {
            'stage': detect.detectionStage,
            'score': detect.score,
            'meanProb': detect.meanProb,
            'coverage': detect.coverage,
            'frameFill': detect.frameFill,
            'autoAccepted': detect.score >= kQuadScoreThreshold,
            'threshold': kQuadScoreThreshold,
            'quad': detect.quad
                ?.map((p) => [p.$1, p.$2])
                .toList(growable: false),
            'segmentationMs': detect.segmentationMs,
            'detectionMs': detect.detectionMs,
            'overlay': overlay == null ? null : '${id}_detect.png',
          },
        });
        // Sprint 1 acceptance: when auto detection is rejected, walk the same
        // path the corner editor uses (cropImage with a user quad) so the
        // bundle proves the manual route recovers the full page.
        final manualRaw = job['manualQuad'] as List?;
        final manualPoints = manualRaw == null
            ? null
            : [
                for (final p in manualRaw.cast<List>())
                  ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
              ];
        for (final mode in modes) {
          for (final budget in budgets) {
            final scan = await widget.engine.scan(
              source,
              options: ScanOptions(
                colorMode: ScanColorMode.fromWire(mode),
                maxPixels: budget.toInt(),
                quad: detect.quad,
              ),
            );
            final name = '${id}_${mode.toLowerCase()}_${budget ~/ 1000}k.'
                '${scan.outputFormat}';
            await File(scan.outputPath).copy('${outDir.path}/$name');
            results.add({
              'id': id,
              'mode': mode,
              'budget': budget.toInt(),
              'file': name,
              'outputWidth': scan.outputWidth,
              'outputHeight': scan.outputHeight,
              'fileBytes': scan.fileBytes,
              'colorMode': scan.colorMode.wireName,
              'autoColorMode': scan.autoColorMode.wireName,
              'detectionStage': scan.detectionStage,
              'timings': {
                for (final e in scan.timings.entries) e.$1: e.$2,
              },
            });
            setState(() => _status = 'done ${results.length} runs');
          }
        }
        if (manualPoints != null && detect.score < kQuadScoreThreshold) {
          for (final mode in modes) {
            for (final budget in budgets) {
              final crop = await widget.engine.cropImage(
                source,
                manualPoints,
                options: ScanOptions(
                  colorMode: ScanColorMode.fromWire(mode),
                  maxPixels: budget.toInt(),
                ),
              );
              final name = '${id}_${mode.toLowerCase()}_'
                  '${budget ~/ 1000}k_manual.${crop.outputFormat}';
              await File(crop.outputPath).copy('${outDir.path}/$name');
              results.add({
                'id': id,
                'mode': mode,
                'budget': budget.toInt(),
                'manual': true,
                'file': name,
                'outputWidth': crop.outputWidth,
                'outputHeight': crop.outputHeight,
                'fileBytes': crop.fileBytes,
                'colorMode': crop.colorMode.wireName,
                'timings': {
                  for (final e in crop.timings.entries) e.$1: e.$2,
                },
              });
              setState(() => _status = 'done ${results.length} runs');
            }
          }
        }
      }
      out['ok'] = true;
      out['runs'] = results;
    } catch (e, s) {
      out['ok'] = false;
      out['error'] = '$e';
      out['stack'] = '$s'.split('\n').take(6).join('\n');
    }
    // logcat truncates long lines, so the authoritative copy goes to disk.
    try {
      final manifest = jsonDecode(
        await File(widget.manifestPath).readAsString(),
      ) as Map<String, dynamic>;
      await File('${manifest['outDir']}/metrics.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(out));
    } catch (_) {
      // Falls back to the logcat line below.
    }
    debugPrint('EVIDENCE_JSON: ${jsonEncode(out)}');
    setState(() => _status = out['ok'] == true ? 'done' : 'failed');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('EVIDENCE_BATCH $_status', textDirection: TextDirection.ltr),
        ),
      ),
    );
  }
}
