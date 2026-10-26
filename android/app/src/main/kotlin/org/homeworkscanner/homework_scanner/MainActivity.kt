package org.homeworkscanner.homework_scanner

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> saveImage(
                        call.argument<String>("path"),
                        call.argument<String>("fileName"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun saveImage(path: String?, fileName: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty() || fileName.isNullOrEmpty()) {
            result.error("bad_args", "缺少图片路径或文件名", null)
            return
        }
        val source = File(path)
        if (!source.isFile) {
            result.error("source_missing", "处理结果文件不存在", path)
            return
        }
        val mime = mimeTypeFor(source.name)
        if (mime == null) {
            result.error("not_image", "只支持 JPG/PNG 图片", source.name)
            return
        }
        // Extension always follows the real file, so a black-and-white PNG page
        // can never be saved as `.jpg`.
        val safeName = sanitizeFileName(fileName, source.name.substringAfterLast('.', "jpg"))

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Writing MediaStore below API 29 needs WRITE_EXTERNAL_STORAGE,
            // which this app does not hold on purpose. Dart falls back to the
            // system share sheet and says so in the snackbar.
            result.success(mapOf("ok" to false, "code" to "share_fallback"))
            return
        }

        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, safeName)
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                "${Environment.DIRECTORY_PICTURES}$ALBUM",
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val resolver = applicationContext.contentResolver
        var inserted: Uri? = null
        try {
            inserted = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            if (inserted == null) {
                result.error("insert_failed", "相册无法创建条目", null)
                return
            }
            val uri = inserted
            val written = resolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            }
            if (written == null) {
                runCatching { resolver.delete(uri, null, null) }
                result.error("write_failed", "无法写入相册", null)
                return
            }
            val clear = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
            resolver.update(uri, clear, null, null)
            result.success(
                mapOf(
                    "ok" to true,
                    "savedPath" to "${Environment.DIRECTORY_PICTURES}$ALBUM/$safeName",
                ),
            )
        } catch (error: Exception) {
            inserted?.let { uri -> runCatching { resolver.delete(uri, null, null) } }
            result.error("write_failed", error.message ?: "写入相册失败", null)
        }
    }

    private fun mimeTypeFor(name: String): String? =
        when (name.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            else -> null
        }

    /**
     * Strips any path segment and separators so a crafted file name cannot
     * escape `Pictures/作业扫描`, then restores the real image extension.
     */
    private fun sanitizeFileName(raw: String, extension: String): String {
        val withoutPath = raw
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_")
            .trim()
        val base = withoutPath.substringBeforeLast('.', withoutPath).trim('.')
        val clipped = if (base.length > 80) base.take(80) else base
        val safeBase = clipped.ifBlank { "作业扫描_${System.currentTimeMillis()}" }
        return "$safeBase.$extension"
    }

    companion object {
        private const val CHANNEL_NAME = "homework_scanner/gallery"
        private const val ALBUM = "/作业扫描"
    }
}
