# Sprint 5 验收报告 · 多文档与相册多选

- 基线：`456909c`（Sprint 4 裁切缓存修复）
- 目标：一份文档完成后能继续新建第二份；相册可以一次导入多张
- 结果：**MVP 主流程打通**（多份文档 + 多选导入 + 原有拍摄/裁切/PDF）
- 设备：Android 模拟器 `sdk_gphone64_x86_64`，Android 16 / API 36
- 实体手机仍未连接，真机验收仍为阻塞项

---

## 1. 完成内容

### 多文档

- App 根页面改为“我的扫描”文档库：
  - 卡片展示标题、日期、页数、预览图、处理状态/已导出；
  - 点击卡片打开对应文档；
  - “扫描新文档”按钮新建一份独立文档；
  - 从文档页返回后自动刷新列表。
- 每份文档仍使用独立目录：
  `documents/<docId>/session.json + originals/ + processed/`
- 新建文档不会覆盖上一份。
- `DocumentController.openDocument` 支持在文档间切换；切换前等待当前队列结束，避免两个文档的页面同时进入原生引擎。
- 旧文档（包括“扫描文档”这种历史标题）仍可打开。

### 相册多选

- 导入按钮改用 `ImagePicker.pickMultiImage()`；
- 选中多张后按顺序调用 `addCapturedPages`，逐张复制原图并串行处理；
- 提示“已导入 N 页，后台处理中”；
- 原有单张导入/测试注入仍保留兼容。

---

## 2. 模拟器验收

### 两份文档

1. 启动进入“我的扫描”，显示原有 2 页文档；
2. 点“扫描新文档”，进入 0 页的新文档；
3. 一次相册多选 2 张图片，提示“已导入 2 页，后台处理中”；
4. 两页处理完成后返回文档库，显示两份独立文档。

开发期截图包含真实作业内容，未随公开仓库发布；本地私有备份保留完整证据。

### 行为确认

- 新文档创建后，旧文档仍保留；
- 文档库卡片标题使用创建时间，如 `扫描_20261024_1328`；
- 返回目录后没有退出/清数据，直接可以打开第二份；
- 原有单文档的页面裁切、排序、删除、PDF 逻辑未改。

---

## 3. 测试与构建

| 检查 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| App Flutter tests | **34 passed** |
| 插件 tests | **6 passed** |
| 原生 Kotlin tests | **29 passed** |
| arm64 Release | **52.0 MiB**，仅 `arm64-v8a` |
| 字节数 | 54,476,092 |
| SHA-256 | `75d2525e27a184909d644a31d3c4c9c323c68312e7db359e528e811d9be9045a` |

新增测试：

- `SessionStore.listDocuments`（由文档库使用）；
- `DocumentController.openDocument` 切换文档；
- `addCapturedPages` 一次导入 3 张按顺序入队；
- 文档库显示多份文档并新建第三份；
- 原有相机、排序、重裁、失败重试、PDF、20 页导出测试保持通过。

---

## 4. 未完成 / 限制

1. **实体手机仍未连接**。本轮的文档库/多选导入只在模拟器验证；你的手机端需要安装本版再确认。
2. 文档库 MVP **不做**删除、重命名、文件夹管理；只有新建/打开/继续。
3. 打开另一份文档时会等待当前处理队列结束；没有“后台同时处理两个文档”。
4. 多选导入是逐张复制、串行处理；没有逐文件进度条，只有总数提示。
5. 自动裁切仍可能把桌面带入结果；手动四角/候选切换是兜底。这个属于检测质量问题，不是本轮文档管理问题。
6. 实体手机 PDF 阅读器未验收。

---

## 5. 修改文件

新增：

- `lib/features/documents/document_library_page.dart`
- `docs/Sprint5-验收报告.md`

修改：

- `lib/main.dart` — 根页面改为文档库，保留 pickImages
- `lib/services/session_store.dart` — listDocuments、默认文档标题
- `lib/services/document_controller.dart` — openDocument、addCapturedPages、启动恢复不自动打开
- `lib/features/document/document_screen.dart` — 多选导入
- `test/widget_test.dart`、`test/document_controller_test.dart`、`test/support/fakes.dart`

未触碰 `study_course_manager`，未执行 `git push`。

---

## 6. MVP 结论

现在主流程为：

**我的扫描（多文档） → 新建/打开 → 拍照或相册多选 → 逐页处理 → 修正/排序 → PDF → 返回继续下一份。**

多文档和单次多图导入这两个阻塞项已解决。真实手机验证仍是最后一步。
