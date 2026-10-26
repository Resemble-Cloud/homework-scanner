# Phase 1 手动验证：单张保存到相册

- 分支：`feat/freebuff-gallery-save`
- 设备：Android 模拟器 x86_64 / API 36（`flutter_test` AVD），debug APK
- 样张：`test_assets/fixtures/page.jpg`（合成夹具，非真实作业照片），经系统照片选择器导入

## 步骤

1. `flutter build apk --debug` 后 `adb install -r app-debug.apk`。
2. 启动 App → 空库点「扫描第一份文档」→「从相册导入」→ 选中夹具图 → 等待处理完成。
3. 打开页面详情，AppBar 右上出现「保存图片」图标（下载箭头）。
4. 点击保存 → 底部提示「已保存到相册：Pictures/作业扫描/作业扫描_<yyyyMMdd_HHmmss>_第1页.jpg」。
5. `adb shell ls -l /sdcard/Pictures/作业扫描/` 确认文件存在，大小与页面信息里的处理结果一致（15358 字节）。

## 证据

| 截图 | 内容 |
| --- | --- |
| [step10_doc.png](step10_doc.png) | 文档网格：1 页处理完成（819×941） |
| [step11_detail.png](step11_detail.png) | 页面详情 AppBar 的「保存图片」图标 |
| [step13_saved_v2.png](step13_saved_v2.png) | 保存成功提示与相册相对路径 |

## 结论

- API 36 走 MediaStore `IS_PENDING` 免权限写入，相册可见、文件名与扩展名正确。
- API 26–28 的「回退系统分享面板」分支只在代码路径上实现，本轮未在旧系统设备上实测。
