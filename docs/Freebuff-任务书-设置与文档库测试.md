# Freebuff 任务书：设置与文档库测试补强

- 任务类型：测试补强
- 难度：低
- 预计耗时：30～60 分钟
- 目标仓库：`https://github.com/Resemble-Cloud/homework-scanner`
- 基线分支：`main`
- 建议工作分支：`test/freebuff-settings-library`
- 运行环境：Flutter 3.47+ / Dart 3.13+
- **不需要**模拟器、真机、Android SDK、原生 Kotlin 或真实作业照片

---

## 1. 任务目标

在不修改生产代码的前提下，补充 5 个针对**设置**和**文档库**的测试，覆盖当前测试没有触及的边界。

只写测试，不改功能。
如果测试发现真实 bug，**不要顺手修**，在最终说明里单独列出，由维护者决定。

---

## 2. 硬性约束

1. 不修改 `lib/`、`android/`、`packages/`、`pubspec.yaml`、`pubspec.lock`。
2. 不引入新依赖。
3. 不使用真实作业照片；只能使用 `test_assets/fixtures/page.jpg`。
4. 不修改或删除已有测试；只新增测试文件/测试用例。
5. 不修改 `.github/`、`README.md`、发布流程。
6. 不执行 `git push --force`，不直接推 `main`。
7. 测试必须真实断言，不允许 `skip`、空断言、只打印结果。
8. 最终必须通过：

```bash
flutter analyze
flutter test
```

目标：现有 41 个测试 + 新增 5 个，共 46 个，全部通过。

---

## 3. 背景

App 结构：

- `DocumentController`：文档状态、串行处理队列、设置、恢复；
- `SessionStore`：文档目录、`session.json`；
- `SettingsStore`：全局 `scan_settings.json`；
- `DocumentLibraryPage`：启动页/文档库；
- `SettingsPage`：默认色彩/默认裁切设置。

现有测试：

- `test/document_controller_test.dart`
- `test/document_model_test.dart`
- `test/pdf_export_test.dart`
- `test/settings_test.dart`
- `test/widget_test.dart`
- `test/support/fakes.dart`

已有覆盖包括：设置 JSON round-trip、设置文件损坏回落、默认灰度、检测框/整图偏好、文档切换、多选导入、非空文档库、设置页修改内存状态。

**不要重复已有用例。**

---

## 4. 需要新增的 5 个测试

### 用例 1：`SessionStore.listDocuments` 排序并跳过损坏 session

文件建议：`test/session_store_test.dart`

场景：

1. 创建临时目录；
2. 用 `SessionStore.createDocument(now: ...)` 创建 3 份文档，`updatedAt` 分别不同；
3. 在 `documents/` 下额外创建一个只有损坏 `session.json` 的目录；
4. 调用 `listDocuments()`。

断言：

- 返回 3 份有效文档；
- 按 `updatedAt` 从新到旧排序；
- 损坏 session 被跳过，不抛异常。

提示：

- 用 `createDocument(title: ..., now: DateTime(...))` 可控制时间；
- 临时目录用 `Directory.systemTemp.createTemp(...)`；
- `addTearDown` 清理临时目录。

---

### 用例 2：`SettingsStore` 遇到合法但不是对象的 JSON 时回落默认

文件建议：加入 `test/settings_test.dart`

场景：

1. 创建临时目录和 `SettingsStore`；
2. 写入一个合法 JSON，但不是对象，例如 `[]` 或 `"nope"`；
3. 调用 `store.load()`。

断言：

- 回落到 `ScanColorMode.grayscale`；
- `DefaultCropMode.auto`；
- 不抛异常。

说明：

- 现有测试覆盖了 `{broken` 这种非法 JSON；本用例补“合法 JSON 但结构不对”；
- 不要修改 `settings_store.dart` 或 `scan_settings.dart`。

---

### 用例 3：修改默认设置不回溯修改已有页面

文件建议：加入 `test/document_controller_test.dart`

场景：

1. 用灰度 + 自动裁切初始化 controller；
2. 添加 1 页并等处理完成；
3. 调用 `controller.updateSettings(...)`，把默认色彩改为黑白、默认裁切改为整图；
4. 再添加 1 页并等处理完成。

断言：

- 第 1 页 `colorMode` 仍是 `grayscale`；
- 第 2 页 `colorMode` 是 `blackAndWhite`；
- 已有页面的 `quadSource` 不被设置修改；
- 新页面确实按新设置入队。

注意：

- 不需要断言第 2 页最终具体四角；检测框/整图由现有算法选择，测试只验证“默认值被应用”；
- 不要为了这个测试去改 `_chooseQuad`。

---

### 用例 4：设置页把修改交给注入的 `SettingsStore`

文件建议：加入 `test/widget_test.dart`

场景：

1. 在测试文件里定义一个轻量的 `RecordingSettingsStore extends SettingsStore`；
2. 只重写 `save`，把最后一次 `ScanSettings` 记录到字段里，立即完成；
3. 创建 `DocumentController` 时注入这个 store 和 `initialSettings`；
4. `pumpWidget(HomeworkScannerApp(controller: ...))`；
5. 点击 `settings-action`；
6. 点击 `settings-color-BLACK_AND_WHITE`；
7. 点击 `settings-crop-detector`。

断言：

- `recordingStore.saved.defaultColorMode == ScanColorMode.blackAndWhite`；
- `recordingStore.saved.defaultCropMode == DefaultCropMode.detector`。

说明：

- 现有 widget test 只验证 controller 内存状态，没有验证“设置页 → store”的调用；
- 真实文件读写已经由 `test/settings_test.dart` 覆盖，不要在 widget 测试里重复做异步文件 I/O；
- 测试结束清理临时目录和 controller。

---

### 用例 5：空文档库展示空状态和“扫描第一份文档”

文件建议：加入 `test/widget_test.dart`

场景：

1. 创建空临时目录和 `SessionStore`；
2. 创建 controller，但**不要**调用 `initialize()`（避免自动创建文档）；
3. `pumpWidget(HomeworkScannerApp(controller: ...))`；
4. 等待首帧和异步列表加载。

断言：

- 显示“我的扫描”；
- 显示“还没有扫描文档”；
- 显示按钮“扫描第一份文档”；
- 不显示任何 `document-*` 卡片。

不要点击“扫描第一份文档”进入完整新建流程；本用例只验证空状态。

---

## 5. 允许修改的文件

只允许新增/修改：

- `test/session_store_test.dart`（新增）
- `test/settings_test.dart`
- `test/document_controller_test.dart`
- `test/widget_test.dart`

如果确实需要复用测试工具，可以在 `test/support/` 增加纯测试辅助函数，但要在说明里解释原因。

---

## 6. 验证命令

在仓库根目录运行：

```bash
flutter pub get
flutter analyze
flutter test
```

如果本机 Flutter cache lockfile 被占用（仅 Windows 环境），可以临时：

```bash
export FLUTTER_ALREADY_LOCKED=true
```

这不是项目配置，不要写进仓库。

---

## 7. 验收标准

- [ ] 新增 5 个测试，且都在 `flutter test` 中真实执行；
- [ ] `flutter analyze` 无 issue；
- [ ] 全部测试通过，至少 46 个；
- [ ] 没有修改生产代码；
- [ ] 没有新增依赖；
- [ ] 没有真实作业照片；
- [ ] 测试失败时能给出清晰断言，不是只打印；
- [ ] 最终提供 `git diff --stat` 和测试结果。

---

## 8. 交付格式

最终回复请包含：

1. 修改/新增的文件列表；
2. 5 个测试的名称；
3. `flutter analyze` 结果；
4. `flutter test` 总测试数；
5. 是否发现生产代码问题（如有，只描述，不修）；
6. `git diff --stat`。

建议提交信息：

```text
test: 补充设置与文档库边界测试
```

---

## 9. 明确不做

- 不优化边框检测/去阴影；
- 不修改 `PaperOuterQuad`、`ShadowCorrection`、`FairScanProcessor`；
- 不修改相机、相册选择器；
- 不改 PDF 导出逻辑；
- 不升级 Flutter/Gradle/依赖；
- 不处理 GitHub Actions billing；
- 不重写 Git 历史；
- 不做 UI 改版。

---

## 10. 可直接粘贴给 Freebuff 的任务描述

> 阅读仓库根目录的 `docs/Freebuff-任务书-设置与文档库测试.md`，严格按任务书执行。
>
> 在 `test/freebuff-settings-library` 分支上只补 5 个测试，不修改 `lib/`、`android/`、`packages/` 和依赖。
>
> 完成后运行 `flutter analyze` 和 `flutter test`，报告修改文件、测试数量、失败原因（如有）和 `git diff --stat`。
>
> 如果发现生产代码 bug，只记录，不修复。
