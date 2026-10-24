/*
 * Copyright 2025-2026 The FairScan authors
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <https://www.gnu.org/licenses/>.
 */
package org.homeworkscanner.fairscan_engine

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.fairscan.imageprocessing.ColorMode
import org.fairscan.imageprocessing.Point
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Flutter bridge for the FairScan image processing engine.
 *
 * Channel: `fairscan_engine`
 *  - `engineInfo`      -> Map with model/OpenCV info
 *  - `scanImage`       -> Map with output path, dimensions, timings
 *  - `detectDocument`  -> Map with normalized quad, score, timing (no warp)
 *  - `cropImage`       -> Map with output path, dimensions, timings (manual quad)
 *  - `initialize`      -> loads OpenCV + LiteRT ahead of the first scan
 */
class FairscanEnginePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "fairscan_engine"
        const val DEFAULT_MAX_PIXELS = 2_000_000L
        const val DEFAULT_JPEG_QUALITY = 80
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var processor: FairScanProcessor? = null
    private var executor: ExecutorService? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        executor = Executors.newSingleThreadExecutor()
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        executor?.shutdownNow()
        executor = null
        // Releases the LiteRT interpreter and OpenCV state.
        processor?.close()
        processor = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engineInfo" -> runAsync(result) { engine().engineInfo() }
            "initialize" -> runAsync(result) { engine().initialize(); true }
            "scanImage" -> scanImage(call, result)
            "detectDocument" -> detectDocument(call, result)
            "cropImage" -> cropImage(call, result)
            else -> result.notImplemented()
        }
    }

    private fun scanImage(call: MethodCall, result: MethodChannel.Result) {
        val common = commonScanArgs(call, result) ?: return
        val manualQuad = parseQuad(call.argument<List<Any?>>("quad"), result) ?: return

        runAsync(result) {
            val ctx = context ?: throw ScanFailure("ENGINE_DETACHED", "引擎已卸载")
            val request = ScanRequest(
                sourcePath = common.sourcePath,
                outputDir = File(ctx.filesDir, "scans"),
                maxPixels = common.maxPixels,
                jpegQuality = common.jpegQuality,
                colorMode = common.colorMode,
                manualQuad = manualQuad,
                shadowFlatten = common.shadowFlatten,
            )
            engine().process(request).toMap()
        }
    }

    private fun detectDocument(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        if (sourcePath.isNullOrBlank()) {
            result.error("INVALID_ARGS", "缺少 sourcePath 参数", null)
            return
        }
        runAsync(result) {
            engine().detectDocument(DetectRequest(sourcePath = sourcePath)).toMap()
        }
    }

    private fun cropImage(call: MethodCall, result: MethodChannel.Result) {
        val common = commonScanArgs(call, result) ?: return
        val quad = parseQuad(call.argument<List<Any?>>("quad"), result) ?: return

        runAsync(result) {
            val ctx = context ?: throw ScanFailure("ENGINE_DETACHED", "引擎已卸载")
            val request = CropRequest(
                sourcePath = common.sourcePath,
                outputDir = File(ctx.filesDir, "crops"),
                quad = quad,
                maxPixels = common.maxPixels,
                jpegQuality = common.jpegQuality,
                colorMode = common.colorMode,
                shadowFlatten = common.shadowFlatten,
            )
            engine().cropImage(request).toMap()
        }
    }

    /** Shared validation for scanImage / cropImage. Returns null if invalid (error already sent). */
    private data class CommonArgs(
        val sourcePath: String,
        val maxPixels: Long,
        val jpegQuality: Int,
        val colorMode: ColorMode?,
        val shadowFlatten: Boolean,
    )

    private fun commonScanArgs(call: MethodCall, result: MethodChannel.Result): CommonArgs? {
        val sourcePath = call.argument<String>("sourcePath")
        if (sourcePath.isNullOrBlank()) {
            result.error("INVALID_ARGS", "缺少 sourcePath 参数", null)
            return null
        }
        val maxPixels = (call.argument<Number>("maxPixels") ?: DEFAULT_MAX_PIXELS).toLong()
        if (maxPixels <= 0) {
            result.error("INVALID_ARGS", "maxPixels 必须大于 0", null)
            return null
        }
        val jpegQuality = (call.argument<Number>("jpegQuality") ?: DEFAULT_JPEG_QUALITY)
            .toInt().coerceIn(1, 100)
        val colorModeArg = call.argument<String>("colorMode")
        val colorMode = when (colorModeArg?.uppercase()) {
            null, "AUTO" -> null
            "COLOR" -> ColorMode.COLOR
            "GRAYSCALE" -> ColorMode.GRAYSCALE
            "BLACK_AND_WHITE" -> ColorMode.BLACK_AND_WHITE
            else -> {
                result.error("INVALID_ARGS", "未知色彩模式: $colorModeArg", null)
                return null
            }
        }
        return CommonArgs(
            sourcePath,
            maxPixels,
            jpegQuality,
            colorMode,
            call.argument<Boolean>("shadowFlatten") ?: true,
        )
    }

    /** Accepts `[[x,y], [x,y], [x,y], [x,y]]` in normalized [0,1] coords; null when absent. */
    private fun parseQuad(raw: List<Any?>?, result: MethodChannel.Result): List<Point>? {
        if (raw == null) return null
        if (raw.size != 4) {
            result.error("INVALID_QUAD", "四角坐标必须是 4 个点，实际 ${raw.size} 个", null)
            return null
        }
        val points = mutableListOf<Point>()
        for (item in raw) {
            val pair = item as? List<*>
            val x = (pair?.getOrNull(0) as? Number)?.toDouble()
            val y = (pair?.getOrNull(1) as? Number)?.toDouble()
            if (x == null || y == null) {
                result.error("INVALID_QUAD", "每个角点必须是 [x, y] 数字对", null)
                return null
            }
            if (x < 0 || x > 1 || y < 0 || y > 1) {
                result.error("INVALID_QUAD", "角点坐标必须在 [0, 1] 区间: ($x, $y)", null)
                return null
            }
            points.add(Point(x, y))
        }
        return points
    }

    private fun engine(): FairScanProcessor {
        processor?.let { return it }
        val ctx = context ?: throw ScanFailure("ENGINE_DETACHED", "引擎已卸载")
        return FairScanProcessor(ctx).also { processor = it }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        val executor = executor
        if (executor == null || executor.isShutdown) {
            result.error("ENGINE_DETACHED", "引擎已卸载", null)
            return
        }
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (failure: ScanFailure) {
                mainHandler.post { result.error(failure.code, failure.message, null) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("ENGINE_ERROR", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun ScanResult.toMap(): Map<String, Any?> = mapOf(
        "outputPath" to outputFile.absolutePath,
        "outputFormat" to outputFormat,
        "sourceWidth" to sourceWidth,
        "sourceHeight" to sourceHeight,
        "outputWidth" to outputWidth,
        "outputHeight" to outputHeight,
        "fileBytes" to fileBytes,
        "detected" to detected,
        "detectionStage" to detectionStage,
        "autoColorMode" to autoColorMode.name,
        "colorMode" to colorMode.name,
        "quad" to quad?.map { listOf(it.x, it.y) },
        "timings" to mapOf(
            "decodeMs" to timings.decodeMs,
            "segmentationMs" to timings.segmentationMs,
            "detectionMs" to timings.detectionMs,
            "colorModeMs" to timings.colorModeMs,
            "extractMs" to timings.extractMs,
            "encodeMs" to timings.encodeMs,
            "totalMs" to timings.totalMs,
        ),
    )

    private fun DetectResult.toMap(): Map<String, Any?> = mapOf(
        "quad" to quad?.map { listOf(it.x, it.y) },
        "score" to score,
        "meanProb" to meanProb,
        "coverage" to coverage,
        "frameFill" to frameFill,
        "detectionStage" to stage,
        "sourceWidth" to sourceWidth,
        "sourceHeight" to sourceHeight,
        "segmentationMs" to segmentationMs,
        "detectionMs" to detectionMs,
        "candidates" to candidates.map { candidate ->
            mapOf(
                "source" to candidate.source,
                "quad" to candidate.quad.map { listOf(it.x, it.y) },
                "score" to candidate.score,
                "meanProb" to candidate.meanProb,
                "coverage" to candidate.coverage,
                "frameFill" to candidate.frameFill,
            )
        },
    )

    private fun CropResult.toMap(): Map<String, Any?> = mapOf(
        "outputPath" to outputFile.absolutePath,
        "outputFormat" to outputFormat,
        "outputWidth" to outputWidth,
        "outputHeight" to outputHeight,
        "fileBytes" to fileBytes,
        "colorMode" to colorMode.name,
        "timings" to mapOf(
            "decodeMs" to timings.decodeMs,
            "segmentationMs" to timings.segmentationMs,
            "detectionMs" to timings.detectionMs,
            "colorModeMs" to timings.colorModeMs,
            "extractMs" to timings.extractMs,
            "encodeMs" to timings.encodeMs,
            "totalMs" to timings.totalMs,
        ),
    )
}
