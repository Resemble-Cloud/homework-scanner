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
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import android.os.SystemClock
import android.util.Log
import org.fairscan.imageprocessing.ColorMode
import org.fairscan.imageprocessing.ImageSize
import org.fairscan.imageprocessing.Mode
import org.fairscan.imageprocessing.Point
import org.fairscan.imageprocessing.Quad
import org.fairscan.imageprocessing.autoColorMode
import org.fairscan.imageprocessing.detectDocumentQuad
import org.fairscan.imageprocessing.encodeJpeg
import org.fairscan.imageprocessing.encodePng
import org.fairscan.imageprocessing.extractDocument
import org.fairscan.imageprocessing.resizeForMaxPixels
import org.fairscan.imageprocessing.scaledTo
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.imgproc.Imgproc
import java.io.File

/** Thrown for every failure the Flutter side should show to the user. */
class ScanFailure(
    val code: String,
    override val message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

data class ScanRequest(
    val sourcePath: String,
    val outputDir: File,
    /** Pixel budget of the processed page, same semantics as FairScan's ExportQuality. */
    val maxPixels: Long = 2_000_000,
    val jpegQuality: Int = 80,
    /** null means "reuse FairScan's automatic colour detection". */
    val colorMode: ColorMode? = null,
    /** Cap for the decoded source bitmap (memory guard), FairScan uses 12 MP too. */
    val maxDecodePixels: Int = 12_000_000,
)

data class StageTimings(
    val decodeMs: Long,
    val segmentationMs: Long,
    val detectionMs: Long,
    val colorModeMs: Long,
    val extractMs: Long,
    val encodeMs: Long,
    val totalMs: Long,
)

data class ScanResult(
    val outputFile: File,
    val outputFormat: String,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val outputWidth: Int,
    val outputHeight: Int,
    val fileBytes: Long,
    val detected: Boolean,
    val detectionStage: String,
    val autoColorMode: ColorMode,
    val colorMode: ColorMode,
    val quad: List<Point>?,
    val timings: StageTimings,
)

/**
 * Runs FairScan's document detection / perspective correction / enhancement on
 * a single image file. All heavy work is synchronous and guarded by a lock:
 * the plugin dispatches it to a worker thread.
 */
class FairScanProcessor(
    private val context: Context,
    private val modelAssetName: String = FairScanSegmenter.MODEL_ASSET,
) {
    companion object {
        private const val TAG = "FairScanProcessor"
    }

    private val segmenter = FairScanSegmenter(context, modelAssetName)
    private val lock = Any()
    private var openCvReady = false

    fun initialize() = synchronized(lock) {
        ensureOpenCv()
        segmenter.initialize()
    }

    fun isReady() = segmenter.isReady() && openCvReady

    fun close() = synchronized(lock) {
        segmenter.close()
        openCvReady = false
    }

    fun engineInfo(): Map<String, Any?> {
        val opencv = runCatching { Core.VERSION }.getOrDefault("unknown")
        return mapOf(
            "modelAsset" to modelAssetName,
            "opencvVersion" to opencv,
            "initialized" to isReady(),
            "supportedColorModes" to ColorMode.entries.map { it.name },
        )
    }

    fun process(request: ScanRequest): ScanResult = synchronized(lock) {
        ensureOpenCv()
        segmenter.initialize()

        val source = File(request.sourcePath)
        if (!source.isFile) {
            throw ScanFailure("SOURCE_NOT_FOUND", "找不到输入图片: ${request.sourcePath}")
        }
        if (source.canonicalPath.startsWith(request.outputDir.canonicalPath)) {
            throw ScanFailure("INVALID_ARGS", "输出目录不能包含源图片，避免覆盖原图")
        }

        val totalStart = SystemClock.elapsedRealtime()
        val decodeStart = SystemClock.elapsedRealtime()
        val bitmap = decodeBitmap(source, request.maxDecodePixels)
        val decodeMs = SystemClock.elapsedRealtime() - decodeStart

        val sourceWidth = bitmap.width
        val sourceHeight = bitmap.height
        Log.i(TAG, "decoded ${sourceWidth}x$sourceHeight in ${decodeMs}ms from ${source.name}")

        var rgba: Mat? = null
        var bgr: Mat? = null
        var page: Mat? = null
        try {
            rgba = Mat()
            Utils.bitmapToMat(bitmap, rgba)
            bgr = Mat()
            Imgproc.cvtColor(rgba, bgr, Imgproc.COLOR_RGBA2BGR)

            val segStart = SystemClock.elapsedRealtime()
            val segmentation = segmenter.segment(bitmap)
            val segmentationMs = SystemClock.elapsedRealtime() - segStart

            val detectStart = SystemClock.elapsedRealtime()
            val originalSize = ImageSize(bgr.cols(), bgr.rows())
            // Same two entry points FairScan uses: IMPORT for gallery picks,
            // CAPTURE as the more lenient fallback when that finds nothing.
            var detectionStage = "import"
            var quadInMask: Quad? = detectDocumentQuad(segmentation, originalSize, Mode.IMPORT)
            if (quadInMask == null) {
                quadInMask = detectDocumentQuad(segmentation, originalSize, Mode.CAPTURE)
                detectionStage = if (quadInMask != null) "capture" else "none"
            }
            // detectDocumentQuad works in mask coordinates (FairScan's
            // `extractDocumentFromBitmap` receives `quadInMask` too); everything
            // downstream (colour detection, warping) needs source pixels.
            val quad = quadInMask?.scaledTo(
                segmentation.width,
                segmentation.height,
                bgr.cols(),
                bgr.rows(),
            )
            val detectionMs = SystemClock.elapsedRealtime() - detectStart

            val colorStart = SystemClock.elapsedRealtime()
            val detectedColorMode = if (quad != null) {
                autoColorMode(bgr, segmentation, quad)
            } else {
                ColorMode.COLOR
            }
            val colorModeMs = SystemClock.elapsedRealtime() - colorStart

            val effectiveMode = request.colorMode ?: detectedColorMode
            val budget = maxPixelsFor(effectiveMode, request.maxPixels)

            val extractStart = SystemClock.elapsedRealtime()
            page = if (quad != null) {
                extractDocument(bgr, quad, 0, effectiveMode, budget)
            } else {
                // No document found: never fail the whole scan, hand back the
                // full frame downscaled to the export budget (FairScan does the same).
                resizeForMaxPixels(bgr, budget.toDouble())
            }
            val extractMs = SystemClock.elapsedRealtime() - extractStart

            val encodeStart = SystemClock.elapsedRealtime()
            val blackAndWhite = effectiveMode == ColorMode.BLACK_AND_WHITE
            val bytes = if (blackAndWhite) encodePng(page) else encodeJpeg(page, request.jpegQuality)
            val extension = if (blackAndWhite) "png" else "jpg"
            val encodeMs = SystemClock.elapsedRealtime() - encodeStart

            if (!request.outputDir.exists() && !request.outputDir.mkdirs()) {
                throw ScanFailure("OUTPUT_DIR_FAILED", "无法创建输出目录: ${request.outputDir}")
            }
            val output = File(request.outputDir, "scan_${System.currentTimeMillis()}.$extension")
            output.writeBytes(bytes)

            val outputWidth = page.cols()
            val outputHeight = page.rows()
            val totalMs = SystemClock.elapsedRealtime() - totalStart
            Log.i(
                TAG,
                "scan done: ${outputWidth}x$outputHeight, ${bytes.size} bytes, " +
                    "mode=$effectiveMode (auto=$detectedColorMode), detected=$detectionStage, " +
                    "seg=${segmentationMs}ms detect=${detectionMs}ms extract=${extractMs}ms " +
                    "encode=${encodeMs}ms total=${totalMs}ms",
            )

            ScanResult(
                outputFile = output,
                outputFormat = extension,
                sourceWidth = sourceWidth,
                sourceHeight = sourceHeight,
                outputWidth = outputWidth,
                outputHeight = outputHeight,
                fileBytes = bytes.size.toLong(),
                detected = quad != null,
                detectionStage = detectionStage,
                autoColorMode = detectedColorMode,
                colorMode = effectiveMode,
                quad = quad?.let {
                    listOf(it.topLeft, it.topRight, it.bottomRight, it.bottomLeft)
                },
                timings = StageTimings(
                    decodeMs = decodeMs,
                    segmentationMs = segmentationMs,
                    detectionMs = detectionMs,
                    colorModeMs = colorModeMs,
                    extractMs = extractMs,
                    encodeMs = encodeMs,
                    totalMs = totalMs,
                ),
            )
        } catch (failure: ScanFailure) {
            throw failure
        } catch (t: Throwable) {
            Log.e(TAG, "processing failed", t)
            throw ScanFailure("PROCESS_FAILED", "图像处理失败: ${t.message ?: t.javaClass.simpleName}", t)
        } finally {
            page?.release()
            bgr?.release()
            rgba?.release()
            bitmap.recycle()
        }
    }

    private fun ensureOpenCv() {
        if (openCvReady) return
        val ok = try {
            OpenCVLoader.initLocal()
        } catch (t: Throwable) {
            Log.e(TAG, "OpenCV init threw", t)
            false
        }
        if (!ok) {
            throw ScanFailure("OPENCV_INIT_FAILED", "OpenCV 原生库初始化失败")
        }
        openCvReady = true
    }

    private fun maxPixelsFor(mode: ColorMode, base: Long): Long =
        if (mode == ColorMode.BLACK_AND_WHITE) base * 4 else base

    private fun decodeBitmap(file: File, maxPixels: Int): Bitmap {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                // ImageDecoder applies EXIF orientation and also honours the
                // requested target size, so photos from phones arrive upright.
                val source = ImageDecoder.createSource(file)
                return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    val w = info.size.width
                    val h = info.size.height
                    val scale = decodeScale(w, h, maxPixels)
                    if (scale < 1f) {
                        decoder.setTargetSize(
                            (w * scale).toInt().coerceAtLeast(1),
                            (h * scale).toInt().coerceAtLeast(1),
                        )
                    }
                }
            }
            return decodeWithBitmapFactory(file, maxPixels)
        } catch (t: Throwable) {
            throw ScanFailure("DECODE_FAILED", "无法解码图片: ${file.name}", t)
        }
    }

    private fun decodeWithBitmapFactory(file: File, maxPixels: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw ScanFailure("DECODE_FAILED", "无法读取图片尺寸: ${file.name}")
        }
        val sample = sampleSize(bounds.outWidth, bounds.outHeight, maxPixels)
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeFile(file.absolutePath, options)
            ?: throw ScanFailure("DECODE_FAILED", "无法解码图片: ${file.name}")

        val rotation = exifRotation(file)
        if (rotation == 0) return decoded
        val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
        val rotated = Bitmap.createBitmap(
            decoded, 0, 0, decoded.width, decoded.height, matrix, true,
        )
        if (rotated != decoded) decoded.recycle()
        return rotated
    }

    private fun decodeScale(width: Int, height: Int, maxPixels: Int): Float {
        val pixels = width.toLong() * height.toLong()
        return if (pixels > maxPixels) {
            kotlin.math.sqrt(maxPixels.toDouble() / pixels).toFloat()
        } else {
            1f
        }
    }

    private fun sampleSize(width: Int, height: Int, maxPixels: Int): Int {
        var sample = 1
        while ((width / sample).toLong() * (height / sample).toLong() > maxPixels) {
            sample *= 2
        }
        return sample
    }

    private fun exifRotation(file: File): Int {
        return try {
            when (
                ExifInterface(file.absolutePath)
                    .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            ) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_270 -> 270
                else -> 0
            }
        } catch (t: Throwable) {
            Log.w(TAG, "EXIF read failed for ${file.name}", t)
            0
        }
    }
}
