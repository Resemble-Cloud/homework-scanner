# fairscan_engine

Flutter (Android) 插件：把 [FairScan](https://github.com/pynicolas/FairScan) 的图像处理算法
接到 Dart 侧，Sprint 0 只做**单张图片**的检测 / 透视矫正 / 增强。

不包含 FairScan 的 Compose UI、页面管理、PDF、OCR —— 这些留在 Flutter 侧后续迭代。

## 组成

```
android/src/main/java/org/fairscan/imageprocessing/   # 从 FairScan 复制的算法源码（GPLv3）
android/src/main/kotlin/org/homeworkscanner/fairscan_engine/
    FairScanSegmenter.kt    # LiteRT 分割模型包装（改编自 FairScan ImageSegmentationService）
    FairScanProcessor.kt    # 解码 → 分割 → 四角检测 → 色彩判定 → 透视+增强 → 编码落盘
    FairscanEnginePlugin.kt # MethodChannel "fairscan_engine"
android/src/main/assets/fairscan-segmentation-model.tflite  # v1.2.0，4.9 MB
```

依赖与 FairScan 保持一致：`org.opencv:opencv:4.12.0`（AAR，含 native）、
`com.google.ai.edge.litert:litert{,-support}:1.4.1`。

## Dart API

```dart
import 'package:fairscan_engine/fairscan_engine.dart';

final engine = FairScanEngine();
final info = await engine.engineInfo();      // 模型 / OpenCV 版本 / 是否就绪
final result = await engine.scan(
  '/sdcard/.../photo.jpg',
  options: const ScanOptions(
    colorMode: ScanColorMode.auto,  // auto / color / grayscale / blackAndWhite
    maxPixels: 2000000,             // 输出像素预算（BALANCED）
    jpegQuality: 80,
  ),
);
print('${result.outputPath} ${result.outputWidth}x${result.outputHeight} '
      '${result.fileSizeLabel} ${result.timings.totalMs} ms');
```

`scan()` 成功时返回 `ScanResult`（输出路径、分辨率、字节数、自动/实际色彩模式、
四角坐标、分阶段耗时）；失败抛 `ScanEngineException`，`code` 取值：

| code | 含义 |
|---|---|
| `INVALID_ARGS` | 参数缺失/非法（如 colorMode 未知） |
| `SOURCE_NOT_FOUND` | 输入文件不存在 |
| `DECODE_FAILED` | 图片无法解码（损坏或非图片） |
| `OPENCV_INIT_FAILED` | OpenCV native 初始化失败 |
| `MODEL_INIT_FAILED` | 分割模型加载失败 |
| `PROCESS_FAILED` | 算法阶段抛出异常（附带 OpenCV 原始信息） |
| `ENGINE_DETACHED` | 引擎已随 FlutterEngine 卸载 |
| `ENGINE_UNAVAILABLE` | Dart 侧找不到原生实现（插件未链接） |

输出永远写到 `filesDir/scans/`，输入文件只读，不会被覆盖。

## 与上游的差异（本地补丁）

复制 `imageprocessing` 时只改了一处，属于上游缺陷，已在源码中注释说明：

- `ColorDetection.kt`
  - `autoColorMode()` 在文档掩码为空时提前返回 `GRAYSCALE`。上游此时会在
    `bitwise_and` 里拿到一个已被释放的 `Mat`（尺寸 0×0）并崩溃。
  - `applyGrayWorldToDocument()` 不再释放调用方传入的 `docMask`。

其余算法（`DocumentDetection`、`ContourOrientation`、`Perspective`、`PostProcessing`、
`Geometry`、`BitonalPacking`）与 FairScan `c1517c5` 完全一致。

## 资源与线程

- 所有 Mat / Bitmap 在 `try/finally` 中释放；LiteRT `Interpreter` 在
  `onDetachedFromEngine` 时 `close()`。
- 单线程 executor 串行处理；`Interpreter` 不复用跨请求的可变状态。
- 分割模型常驻内存（约 5 MB 映射 + 运行时），首次扫描时加载。

## 许可证

`src/main/java/org/fairscan/**` 来自 FairScan，版权归 The FairScan authors，
GNU GPLv3。把本插件链入应用意味着应用整体需要以 GPLv3 兼容方式分发。
