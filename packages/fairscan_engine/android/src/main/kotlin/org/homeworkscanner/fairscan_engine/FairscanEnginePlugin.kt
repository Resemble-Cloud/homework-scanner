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
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Flutter bridge for the FairScan image processing engine.
 *
 * Channel: `fairscan_engine`
 *  - `engineInfo`      -> Map with model/OpenCV info
 *  - `scanImage`       -> Map with output path, dimensions, timings
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
            else -> result.notImplemented()
        }
    }

    private fun scanImage(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        if (sourcePath.isNullOrBlank()) {
            result.error("INVALID_ARGS", "缺少 sourcePath 参数", null)
            return
        }
        val maxPixels = (call.argument<Number>("maxPixels") ?: DEFAULT_MAX_PIXELS).toLong()
        if (maxPixels <= 0) {
            result.error("INVALID_ARGS", "maxPixels 必须大于 0", null)
            return
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
                return
            }
        }

        runAsync(result) {
            val ctx = context ?: throw ScanFailure("ENGINE_DETACHED", "引擎已卸载")
            val request = ScanRequest(
                sourcePath = sourcePath,
                outputDir = File(ctx.filesDir, "scans"),
                maxPixels = maxPixels,
                jpegQuality = jpegQuality,
                colorMode = colorMode,
            )
            engine().process(request).toMap()
        }
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
}
