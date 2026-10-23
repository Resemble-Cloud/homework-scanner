# homework_scanner · Sprint 0

Flutter 作业扫描 App 的骨架：**Flutter 负责 UI / 选图 / 展示，扫描算法直接复用 FairScan 的
`imageprocessing` 模块**，通过 Android Kotlin 插件 + MethodChannel 调用，不重写任何 CV 算法。

本轮只验证**单张图片**的「纸张检测 → 透视矫正 → 图像增强 → 落盘」，不做多页 PDF、OCR、
相机采集和完整 UI。

## 目录结构

```
lib/main.dart                     # 单页 UI：选图、原图/结果对比、分阶段耗时、错误卡片
packages/fairscan_engine/         # Android 原生插件（Kotlin）
  android/src/main/java/org/fairscan/imageprocessing/   # FairScan 算法源码（GPLv3，见 README）
  android/src/main/kotlin/org/homeworkscanner/fairscan_engine/  # 桥接与流水线
  android/src/main/assets/fairscan-segmentation-model.tflite    # FairScan 分割模型 v1.2.0
  lib/fairscan_engine.dart        # Dart 客户端（ScanEngine / ScanResult / ScanEngineException）
  test/                           # Dart 侧解析与错误映射测试
test/widget_test.dart             # 注入 FakeScanEngine 的 UI 测试
test_assets/real_samples/         # 真实作业照片（1–8.jpg）
evidence/                         # 真机验证证据（截图、输出图、1:1 裁切、review.html）
docs/Sprint0-验收报告.md          # 验收报告
```

## 环境（本机实测组合）

| 组件 | 版本 |
|---|---|
| Flutter | 3.47.5 (stable)，Dart 3.13.4 |
| Android Gradle Plugin | 9.1.0（Flutter 模板） |
| Kotlin | 2.4.0 |
| Gradle | 9.3.1（wrapper 指向腾讯镜像，复用 `D:\dev\gradle-home` 缓存） |
| JDK | 17（`D:\dev\jdk17`） |
| Android SDK | platform 36 / build-tools 36.0.0 |
| OpenCV | `org.opencv:opencv:4.12.0`（AAR） |
| LiteRT | 1.4.1 |
| minSdk / targetSdk | 26 / 36 |

## 构建与运行

```bash
export JAVA_HOME=/d/dev/jdk17
export ANDROID_HOME=/d/dev/Android/Sdk
export GRADLE_USER_HOME=D:/dev/gradle-home     # 复用已有缓存，避免重新下载 Gradle/AGP

flutter pub get
flutter analyze                                # 无 issue
flutter test                                   # UI + Dart 客户端测试
flutter build apk --debug                      # 或 --release

# 原生算法单测（复制自 FairScan 的纯函数测试）
cd android && ./gradlew :fairscan_engine:testDebugUnitTest
```

安装到设备后点「选择图片并扫描」，选一张作业照片即可；输出写到应用私有目录
`files/scans/`，不会修改原图。

## 本轮实现状态

- [x] 独立 Flutter 工程 + Git 基线（未触碰 `study_course_manager`）
- [x] Kotlin 插件封装 FairScan `imageprocessing`（检测 / 透视 / 增强 / 二值化）
- [x] MethodChannel 双向错误契约、分阶段耗时、Mat/Bitmap 释放
- [x] Flutter 选图 + 原图/结果对比 + 耗时/输出信息 + 错误展示
- [x] `flutter analyze` / Dart 测试 / 原生单测 / debug+release APK
- [x] 真实作业照片跑通完整流水线（模拟器 x86_64 API 36）
- [ ] 真机（USB 手机）验证 —— 本机没有连接 Android 设备，见验收报告的「未解决问题」
- [ ] 多页 / PDF / OCR / 相机采集（后续 Sprint）

## 已知构建约束

- `android/gradle.properties` 里 `android.uniquePackageNames=false`：LiteRT 1.4.1 的
  `litert-support` 与 `litert-support-api` 使用同一个 namespace，与 FairScan 的做法一致。
- `kotlin.incremental=false`：本机 Kotlin 2.4.0 增量缓存偶发
  `Could not close incremental caches ... class-fq-name-to-source.tab`，关闭增量编译规避，
  只影响构建速度。
- Gradle wrapper 指向 `mirrors.cloud.tencent.com`：本机 hosts 把 github.com 指向本地中间人，
  JDK 信任库不认其自签证书；腾讯/阿里镜像可直连（与 `study_course_manager` 的既有配置一致）。
- 构建时 Flutter 会提示插件应用了 Kotlin Gradle Plugin（KGP）；AGP 9 的 Built-in Kotlin
  迁移留到后续版本。

## 许可证

`packages/fairscan_engine/android/src/main/java/org/fairscan/**` 复制自
[FairScan](https://github.com/pynicolas/FairScan)（GPLv3），文件保留原始版权头。
应用整体应以 GPLv3 兼容方式分发，详见 [LICENSE](LICENSE) 与插件 README。
