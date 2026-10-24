# homework_scanner · Sprint 3

Flutter 作业扫描 App：**连续拍照 → 后台逐页 FairScan 处理 → 多页修正/排序 → 一个 PDF**。

扫描算法继续复用 FairScan 的 `imageprocessing`（OpenCV + LiteRT），通过 Kotlin 插件 + MethodChannel
调用；没有第二套检测/矫正引擎，也没有用 Dart 重写 CV。

## 当前能力

- 全屏 CameraX 相机（Flutter `camera` 插件），最高可用分辨率、闪光灯、A4 参考框
- 连拍即入队；后台串行处理，缩略图条显示排队/处理中/完成/失败，不阻塞下一次拍摄
- 多页文档：原图始终保留，单页重新裁剪（Sprint 1 四角编辑器）、切色彩模式重处理、重拍、删除
- 页面网格长按拖动排序
- 会话 JSON + 文件目录落盘；App 强杀/重装后恢复未导出文档
- 检测不再只有“检测框 / 整图”两选一：原生返回检测框、纸面外框、整图 2% 三个候选；优先保留纸面，再减少桌面
- 页面详情可在候选之间一键切换；低内容候选保留“建议检查”警告
- 保守去阴影：低强度压平大范围光照梯度，可在单页关闭回退
- Dart `pdf` 包逐页组装；处理后的 JPEG 以原始 DCT 流嵌入，不二次编码；A4/原始比例可选
- 系统分享/保存 sheet 输出 PDF，默认文件名 `扫描_日期时间.pdf`，可改名

## 目录

```
lib/
  main.dart                          # 依赖装配、启动恢复
  models/scan_document.dart          # 文档/页面模型、JSON、四角来源
  services/
    session_store.dart               # 会话目录 + JSON
    document_controller.dart         # 串行队列、兜底、重拍/排序/恢复/导出
    pdf_export_service.dart          # 串行 PDF 组装
    share_service.dart               # 系统分享
  features/camera/                   # 全屏相机 + 快门 + 缩略图条
  features/document/                 # 页面网格、页面详情、导出对话框
  widgets/                            # 四角编辑器、状态缩略图
packages/fairscan_engine/             # Android 原生 FairScan 桥接与算法
test/                                 # 模型/控制器/PDF/Widget 测试
docs/Sprint3-验收报告.md              # 本轮验收、模拟器数据、限制
docs/Sprint3-任务书.md                # 本轮目标与验收标准
docs/sprint3/                         # 候选对比、样张输出、metrics
evidence/sprint3/                     # 模拟器截图
```

## 环境（本机实测）

| 组件 | 版本 |
| --- | --- |
| Flutter / Dart | 3.47.5 stable / 3.13.4 |
| Android Gradle Plugin | 9.1.0 |
| Kotlin | 2.4.0 |
| JDK | 17（`D:\dev\jdk17`） |
| Android SDK | platform 36 / build-tools 36.0.0 |
| OpenCV / LiteRT | 4.12.0 / 1.4.1 |
| minSdk / targetSdk | 26 / 36 |

## 构建与测试

```bash
export PATH="/d/dev/flutter/bin:$PATH"
export FLUTTER_ALREADY_LOCKED=true      # 本机 Flutter cache lockfile 被占用时的绕过
export JAVA_HOME=/d/dev/jdk17
export ANDROID_HOME=/d/dev/Android/Sdk
export GRADLE_USER_HOME=D:/dev/gradle-home

flutter pub get
flutter analyze
flutter test
./android/gradlew -p android :fairscan_engine:testDebugUnitTest

# 模拟器（x86_64）
flutter build apk --release --target-platform android-x64

# 交付包：只保留 arm64-v8a
flutter build apk --release --target-platform android-arm64 --split-per-abi
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

## 关键实现约束

- 每页处理严格串行：`DocumentController` 一次只把一个页面送进原生引擎，避免 12 MP 原图并发。
- 页面始终先复制到文档目录再入队；原生输出写另一个文件，失败不会覆盖原图。
- 检测候选：检测框（import/capture）、纸面外框（paper_outer）、整图内缩 2%（default）；候选必须
  `coverage >= 0.97` 且 `frameFill >= 0.50` 才可能被自动采用，其余回退并标记“建议检查”。
- 纸面外框在现有 FairScan 分割 mask 上计算，不引入第二套引擎。
- 去阴影是 FairScan 增强后的低强度后处理（强度 0.22，背景范围 <14 时跳过），黑白模式不启用。
- 原生编码前裁掉 2 px 插值边缘（`EdgeInset.kt`），消除透视矫正后的左上角黑边。
- PDF 导出逐页读文件、逐页加页；JPEG 流直接 `/DCTDecode` 嵌入，避免多页解码位图同时驻留。
- 相机、分享等平台插件只在设备上运行；widget/单元测试使用注入的 fake 引擎与同步测试存储。

## 已知限制

- 本轮仍只在 Android 模拟器（x86_64 / API 36）验证；**没有实体手机**，真机相机、长按手势、
  手机 PDF 阅读器仍未验收。
- 纸面外框是矩形近似，会包进少量桌面/键盘角落；摊开笔记本的真机样本仍需验证。
- 去阴影效果保守（背景标准差小幅改善，暗像素约 -3.3%），强阴影样本未完成真机评估。
- 当前策略仍偏保守，部分页面会显示“建议检查”；阈值为 Sprint 1 的 3 张样本标定，需要真机重新校准。
- 实时边缘检测未做（后续项）。

详见 [Sprint 3 验收报告](docs/Sprint3-验收报告.md)。

## 许可证

`packages/fairscan_engine/android/src/main/java/org/fairscan/**` 复制自
[FairScan](https://github.com/pynicolas/FairScan)（GPLv3），文件保留原始版权头。
应用整体应以 GPLv3 兼容方式分发，详见 [LICENSE](LICENSE) 与插件 README。
