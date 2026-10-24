import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/scan_document.dart';
import '../../services/document_controller.dart';
import '../../widgets/page_thumbnail.dart';

/// Full-screen capture surface. Photos are handed to [DocumentController] as
/// soon as the shutter returns; the controller's serially processed queue runs
/// independently, so the next shot is never blocked by CV work.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({
    super.key,
    required this.controller,
    this.retakePageId,
  });

  final DocumentController controller;
  final String? retakePageId;

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _camera;
  bool _initializing = true;
  bool _capturing = false;
  String? _error;
  FlashMode _flashMode = FlashMode.auto;

  bool get _isRetake => widget.retakePageId != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera?.dispose());
    _camera = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      unawaited(camera.dispose());
      _camera = null;
      if (mounted) setState(() => _initializing = true);
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (!mounted) return;
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('NO_CAMERA', '设备没有可用相机');
      }
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final next = CameraController(
        description,
        ResolutionPreset.max,
        enableAudio: false,
      );
      await next.initialize();
      try {
        await next.setFlashMode(_flashMode);
      } catch (_) {
        // Front cameras / emulators may not expose a flash. The preview still
        // works and the button reports the unsupported mode on demand.
      }
      if (!mounted) {
        await next.dispose();
        return;
      }
      final old = _camera;
      _camera = next;
      if (old != null && old != next) unawaited(old.dispose());
      setState(() => _initializing = false);
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = _cameraErrorText(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '相机启动失败：$error';
      });
    }
  }

  String _cameraErrorText(CameraException error) {
    return switch (error.code) {
      'CameraAccessDenied' => '相机权限被拒绝，请在系统设置中允许相机权限后重试',
      'CameraAccessDeniedWithoutPrompt' => '相机权限已被永久拒绝，请到系统设置中开启',
      'CameraAccessRestricted' => '相机访问受限',
      'NO_CAMERA' => '设备没有可用相机',
      _ => '相机启动失败：${error.description ?? error.code}',
    };
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      await HapticFeedback.mediumImpact();
      final shot = await camera.takePicture();
      if (_isRetake) {
        await widget.controller.retakePage(widget.retakePageId!, shot.path);
        await _deleteTemp(shot.path);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final document = widget.controller.document;
      if (document == null) {
        throw StateError('文档尚未初始化');
      }
      // Deliberately do not await the copy/scan: the shutter must be ready for
      // the next page immediately. The controller serialises processing.
      final future = widget.controller.addCapturedPage(
        shot.path,
        captureSource: 'capture',
      );
      unawaited(
        future.then((_) => _deleteTemp(shot.path)).catchError((Object error) {
          if (mounted) _snack('第 ${document.pages.length + 1} 页入队失败：$error');
        }),
      );
      if (mounted) setState(() {});
    } on CameraException catch (error) {
      if (mounted) _snack(_cameraErrorText(error));
    } catch (error) {
      if (mounted) _snack('拍照失败：$error');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _deleteTemp(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The session already owns a copy.
    }
  }

  Future<void> _cycleFlash() async {
    final camera = _camera;
    if (camera == null) return;
    final next = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };
    try {
      await camera.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (error) {
      if (mounted) _snack('当前相机不支持该闪光灯模式：$error');
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.controller.document;
    final pageNumber = _isRetake && document != null
        ? document.pageNumber(widget.retakePageId!)
        : null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final currentDocument = widget.controller.document;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (_error != null)
                _CameraError(
                  message: _error!,
                  onRetry: _initializeCamera,
                  onClose: () => Navigator.of(context).pop(),
                )
              else if (_initializing || _camera == null)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              else
                _CameraPreview(controller: _camera!),
              if (_error == null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _A4GuidePainter()),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: Row(
                      children: [
                        IconButton.filledTonal(
                          key: const Key('close-camera'),
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                          tooltip: '完成',
                        ),
                        const Spacer(),
                        if (pageNumber != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              '重拍第 $pageNumber 页',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        IconButton.filledTonal(
                          key: const Key('flash-button'),
                          onPressed: _camera == null ? null : _cycleFlash,
                          icon: Icon(_flashIcon),
                          tooltip: '闪光灯：$_flashLabel',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_error == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _BottomShutterBar(
                    cameraReady: _camera != null && !_initializing,
                    capturing: _capturing,
                    controller: widget.controller,
                    document: currentDocument,
                    isRetake: _isRetake,
                    onCapture: _capture,
                    onDone: () => Navigator.of(context).pop(),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  IconData get _flashIcon => switch (_flashMode) {
    FlashMode.off => Icons.flash_off,
    FlashMode.auto => Icons.flash_auto,
    _ => Icons.flash_on,
  };

  String get _flashLabel => switch (_flashMode) {
    FlashMode.off => '关闭',
    FlashMode.auto => '自动',
    _ => '常亮',
  };
}

class _CameraPreview extends StatelessWidget {
  const _CameraPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = constraints.biggest;
        final previewAspect = screen.height > screen.width
            ? 1 / controller.value.aspectRatio
            : controller.value.aspectRatio;
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: previewAspect * 1000,
              height: 1000,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }
}

class _BottomShutterBar extends StatelessWidget {
  const _BottomShutterBar({
    required this.cameraReady,
    required this.capturing,
    required this.controller,
    required this.document,
    required this.isRetake,
    required this.onCapture,
    required this.onDone,
  });

  final bool cameraReady;
  final bool capturing;
  final DocumentController controller;
  final ScanDocument? document;
  final bool isRetake;
  final VoidCallback onCapture;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final pages = document?.pages ?? const <ScanPage>[];
    final visible = pages.length > 6 ? pages.sublist(pages.length - 6) : pages;
    final processing = pages
        .where(
          (p) =>
              p.status == PageStatus.processing ||
              p.status == PageStatus.queued,
        )
        .length;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xEE000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 26, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 74,
                child: visible.isEmpty
                    ? const Center(
                        child: Text(
                          '连续拍摄多页 · 处理在后台进行',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final page = visible[index];
                          final number =
                              pages.length - visible.length + index + 1;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PageThumbnail(
                                page: page,
                                pageNumber: number,
                                width: 60,
                                height: 60,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                page.status.label,
                                style: TextStyle(
                                  color: page.status == PageStatus.failed
                                      ? Colors.redAccent
                                      : Colors.white70,
                                  fontSize: 9,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                pages.isEmpty
                    ? 'A4 参考框仅作对齐引导'
                    : '已拍 ${pages.length} 页'
                          '${processing > 0 ? ' · 后台处理中 $processing 页' : ' · 全部处理完成'}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (isRetake)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onDone,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('取消'),
                      ),
                    )
                  else
                    SizedBox(
                      width: 72,
                      child: Text(
                        pages.isEmpty ? '' : '${pages.length} 页',
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  Expanded(
                    child: Center(
                      child: Semantics(
                        button: true,
                        label: '拍照',
                        child: GestureDetector(
                          key: const Key('shutter-button'),
                          onTap: cameraReady && !capturing ? onCapture : null,
                          child: Container(
                            width: 74,
                            height: 74,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: capturing
                                      ? Colors.white54
                                      : Colors.white,
                                ),
                                child: capturing
                                    ? const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          color: Colors.black87,
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: TextButton(
                      key: const Key('done-camera-button'),
                      onPressed: isRetake ? null : onDone,
                      child: Text(
                        isRetake ? '' : '完成',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({
    required this.message,
    required this.onRetry,
    required this.onClose,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white70,
              size: 52,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
            TextButton(onPressed: onClose, child: const Text('返回')),
          ],
        ),
      ),
    );
  }
}

class _A4GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final top = size.height * 0.14;
    final bottomReserve = math.min(size.height * 0.34, 260.0);
    final availableHeight = size.height - top - bottomReserve;
    final availableWidth = size.width * 0.84;
    var guideHeight = availableHeight * 0.96;
    var guideWidth = guideHeight / math.sqrt2;
    if (guideWidth > availableWidth) {
      guideWidth = availableWidth;
      guideHeight = guideWidth * math.sqrt2;
    }
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, top + availableHeight / 2),
      width: guideWidth,
      height: guideHeight,
    );

    final overlay = Path()..addRect(Offset.zero & size);
    final hole = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, overlay, hole),
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );

    final border = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      border,
    );

    final corner = Paint()
      ..color = const Color(0xFFFFD54F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const arm = 24.0;
    for (final spec in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomRight, -1.0, -1.0),
      (rect.bottomLeft, 1.0, -1.0),
    ]) {
      final point = spec.$1;
      canvas.drawLine(point, point + Offset(arm * spec.$2, 0), corner);
      canvas.drawLine(point, point + Offset(0, arm * spec.$3), corner);
    }

    final textPainter = TextPainter(
      text: TextSpan(
        text: 'A4 参考框 · 对齐纸张四角',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.75),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(rect.left, rect.top - textPainter.height - 8),
    );
  }

  @override
  bool shouldRepaint(_A4GuidePainter oldDelegate) => false;
}
