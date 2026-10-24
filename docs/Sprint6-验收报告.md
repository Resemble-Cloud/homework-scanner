# Sprint 6 验收报告 · 默认色彩与默认裁切设置

- 基线：`9d715d4`（Sprint 5 多文档/多选导入）
- 目标：增加一个极简设置页，可选择默认色彩和默认裁切，避免把默认值硬编码
- 结果：已完成；默认 **灰度 + 自动裁切**，可选检测框/纸面外框/整图 2%
- 设备：Android 模拟器 `sdk_gphone64_x86_64`，Android 16 / API 36
- 实体手机仍未连接

---

## 1. 功能

### 设置入口

“我的扫描”右上角新增齿轮 → “扫描设置”。

### 默认色彩

- 自动 / 彩色 / 灰度 / 黑白
- 默认：**灰度**
- 只影响之后新拍或新导入的页面

### 默认裁切

- 自动（推荐）
- 检测框
- 纸面外框
- 整图 2%

默认：**自动**。

设置允许用户主动选“检测框”；如果检测框保留纸面不足，仍保留“建议检查”，不会静默接受切边。

### 持久化

设置写到：

`<app documents>/scan_settings.json`

示例：

```json
{"defaultColorMode":"GRAYSCALE","defaultCropMode":"detector"}
```

设置只影响新增页面，不回溯修改已有页面；旧页面继续使用自己的色彩模式/四角。

---

## 2. 实现

- `lib/models/scan_settings.dart`
  - `ScanSettings`、`DefaultCropMode`
- `lib/services/settings_store.dart`
  - `scan_settings.json` 原子读写；损坏时回落默认值
- `lib/features/settings/settings_page.dart`
  - 两个设置块，无多余选项
- `lib/features/documents/document_library_page.dart`
  - 右上角齿轮入口
- `lib/services/document_controller.dart`
  - 新增页面读取 `settings.defaultColorMode`
  - `_chooseQuad` 根据 `defaultCropMode` 优先选择候选
  - 检测框偏好下低内容仍标 `needsReview`
- `lib/main.dart`
  - 启动时加载设置并注入控制器

---

## 3. 模拟器验收

1. 打开“扫描设置”，默认选中灰度、自动裁切；
2. 切换默认裁切为“检测框”，设置文件立即写入；
3. 新建文档并导入 1 张图；
4. 新页面 `colorMode=GRAYSCALE`，`quadSource=import`（检测框候选），输出 `1448×2750`；
5. 设置页显示检测框选中。

开发期截图包含真实作业内容，未随公开仓库发布；设置页与灰度输出已由本地验收确认。

页面 JSON 关键字段：

```json
"colorMode": "GRAYSCALE",
"quadSource": "import"
```

---

## 4. 测试与构建

| 检查 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| App Flutter tests | **41 passed** |
| 插件 tests | **6 passed** |
| 原生 Kotlin tests | **29 passed** |
| arm64 Release | **52.0 MiB**，仅 `arm64-v8a` |
| 字节数 | 54,542,024 |
| SHA-256 | `a24baba3cfe7e84e386b9b3e858bb48f370f99cf24fe462e7a8cbecb86008174` |

新增测试：

- `ScanSettings` 默认值/JSON round-trip；
- `SettingsStore` 持久化、无文件/损坏文件回落；
- 新页面使用默认灰度；
- 默认检测框时优先检测框并保留警告；
- 默认整图时使用 `kDefaultInsetQuad`；
- 设置页可修改默认色彩/裁切。

---

## 5. 限制

1. 设置是全局的，没有“每份文档单独设置”。
2. 没有“恢复默认”按钮；需要手动改回。
3. “检测框”默认更紧，摊开笔记本仍可能切半页；低内容会提示，但不会自动阻止。
4. 设置只影响新页面；改设置不会重处理已有页面。
5. 实体手机仍未连接，真机安装后需再确认设置页与灰度输出。

---

## 6. 结论

Sprint 6 完成“默认检测框/灰度”的可配置版本，没有硬编码，也没有把之前的边界修复推倒。MVP 主流程保持：

**文档库 → 新建/打开 → 拍照/多选导入 → 按默认设置处理 → 修正/排序 → PDF。**
