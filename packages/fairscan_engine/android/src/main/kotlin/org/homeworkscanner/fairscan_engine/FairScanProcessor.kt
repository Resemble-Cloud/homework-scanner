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
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
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
    /**
     * Optional user-corrected quad in normalized [0,1] image coordinates
     * (topLeft, topRight, bottomRight, bottomLeft). When present, the automatic
     * detection is skipped and this quad drives the perspective correction,
     * so a mis-detected page frame can never silently drop formulas again.
     */
    val manualQuad: List<Point>? = null,
)

/** Result of running only the paper-detection stage (no warp/enhance). */
data class DetectResult(
    val quad: List<Point>?,
    /** Combined confidence: paper fill x page coverage (see [scoreQuad]). */
    val score: Double,
    /** Mean paper probability inside the quad. */
    val meanProb: Double? = null,
    /** Share of the visible paper mask the quad covers. */
    val coverage: Double? = null,
    /** Share of the photo the quad covers. */
    val frameFill: Double? = null,
    val stage: String,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val segmentationMs: Long,
    val detectionMs: Long,
)

/** Result of cropping to a (manual or auto) quad, kept for the UI. */
data class CropResult(
    val outputFile: File,
    val outputFormat: String,
    val outputWidth: Int,
    val outputHeight: Int,
    val fileBytes: Long,
    val colorMode: ColorMode,
    val timings: StageTimings,
)

/** Input for the detection-only call, which skips warp/enhance entirely. */
data class DetectRequest(
    val sourcePath: String,
    val maxDecodePixels: Int = 12_000_000,
)

/** Input for re-cropping with a user-corrected quad. */
data class CropRequest(
    val sourcePath: String,
    val outputDir: File,
    /** Four normalized [0,1] points: topLeft, topRight, bottomRight, bottomLeft. */
    val quad: List<Point>,
    val maxPixels: Long = 2_000_000,
    val jpegQuality: Int = 80,
    val colorMode: ColorMode? = null,
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

        /** Corner order matches FairScan's [Quad]: topLeft, topRight, bottomRight, bottomLeft. */
        const val CORNER_COUNT = 4

        /** See [FrameScore.MIN_FRAME_FILL] for the calibration behind this value. */
        const val MIN_FRAME_FILL = FrameScore.MIN_FRAME_FILL
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
            // downstream (colour detection, warping) needs source pixels. We
            // normalize once to [0,1] so the UI overlay can draw/edit it, then
            // expand back to source pixels at each consumer.
            val detectedQuad: Quad? = quadInMask?.scaledTo(
                segmentation.width.toDouble(),
                segmentation.height.toDouble(),
                bgr.cols().toDouble(),
                bgr.rows().toDouble(),
            )?.scaledTo(
                bgr.cols().toDouble(),
                bgr.rows().toDouble(),
                1.0,
                1.0,
            )
            val detectionMs = SystemClock.elapsedRealtime() - detectStart

            // Sprint 1: a user-corrected quad wins over whatever detection said,
            // so a bad frame can never silently drop formulas again.
            val requestedQuad: Quad? = request.manualQuad?.let(::quadFromNormalized)
                ?: detectedQuad
            val requestedInPixels: Quad? = requestedQuad?.scaledTo(
                1.0,
                1.0,
                bgr.cols().toDouble(),
                bgr.rows().toDouble(),
            )

            val colorStart = SystemClock.elapsedRealtime()
            val detectedColorMode = if (requestedInPixels != null) {
                autoColorMode(bgr, segmentation, requestedInPixels)
            } else {
                ColorMode.COLOR
            }
            val colorModeMs = SystemClock.elapsedRealtime() - colorStart

            val effectiveMode = request.colorMode ?: detectedColorMode
            val budget = maxPixelsFor(effectiveMode, request.maxPixels)

            val extractStart = SystemClock.elapsedRealtime()
            page = if (requestedInPixels != null) {
                extractDocument(
                    bgr,
                    requestedInPixels,
                    0,
                    effectiveMode,
                    budget,
                )
            } else {
                // No document found: never fail the whole scan, hand back the
                // full frame downscaled to the export budget (FairScan does the same).
                resizeForMaxPixels(bgr, budget.toDouble())
            }
            // Trim the interpolated edge before encoding: this is the cheap fix
            // for the black 1-2 px line that perspective warping can leave on
            // the top/left border. It is a crop, not a re-encode.
            page = trimOuterEdge(page)
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
                detected = requestedQuad != null,
                detectionStage = if (request.manualQuad != null) "manual" else detectionStage,
                autoColorMode = detectedColorMode,
                colorMode = effectiveMode,
                quad = detectedQuad?.let {
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

    /**
     * Runs only the segmentation + paper-detection stages and hands back the quad
     * in normalized [0,1] coordinates, so the Flutter overlay can draw and edit it
     * without shipping a second copy of the mask.
     */
    fun detectDocument(request: DetectRequest): DetectResult = synchronized(lock) {
        ensureOpenCv()
        segmenter.initialize()

        val source = File(request.sourcePath)
        if (!source.isFile) {
            throw ScanFailure("SOURCE_NOT_FOUND", "找不到输入图片: ${request.sourcePath}")
        }

        val decodeStart = SystemClock.elapsedRealtime()
        val bitmap = decodeBitmap(source, request.maxDecodePixels)
        val decodeMs = SystemClock.elapsedRealtime() - decodeStart
        val sourceWidth = bitmap.width
        val sourceHeight = bitmap.height

        var rgba: Mat? = null
        var bgr: Mat? = null
        try {
            rgba = Mat()
            Utils.bitmapToMat(bitmap, rgba)
            bgr = Mat()
            Imgproc.cvtColor(rgba, bgr, Imgproc.COLOR_RGBA2BGR)

            val segStart = SystemClock.elapsedRealtime()
            val segmentation = segmenter.segment(bitmap)
            val segmentationMs = SystemClock.elapsedRealtime() - segStart

            val detectStart = SystemClock.elapsedRealtime()
            val (quad, stage) = detectQuad(segmentation, ImageSize(bgr.cols(), bgr.rows()))
            val score = quad?.let { scoreQuad(segmentation, it) }
            val detectionMs = SystemClock.elapsedRealtime() - detectStart

            Log.i(
                TAG,
                "detect done: stage=$stage score=${"%.3f".format(score?.score ?: 0.0)} " +
                    "(paper=${"%.3f".format(score?.meanProb ?: 0.0)} " +
                    "coverage=${"%.3f".format(score?.coverage ?: 0.0)} " +
                    "fill=${"%.3f".format(score?.frameFill ?: 0.0)}) " +
                    "in ${detectionMs}ms (seg ${segmentationMs}ms)",
            )

            DetectResult(
                quad = quad?.let {
                    listOf(it.topLeft, it.topRight, it.bottomRight, it.bottomLeft)
                },
                score = score?.score ?: 0.0,
                meanProb = score?.meanProb,
                coverage = score?.coverage,
                frameFill = score?.frameFill,
                stage = stage,
                sourceWidth = sourceWidth,
                sourceHeight = sourceHeight,
                segmentationMs = segmentationMs,
                detectionMs = detectionMs,
            )
        } catch (failure: ScanFailure) {
            throw failure
        } catch (t: Throwable) {
            Log.e(TAG, "detection failed", t)
            throw ScanFailure("DETECT_FAILED", "纸张检测失败: ${t.message ?: t.javaClass.simpleName}", t)
        } finally {
            bgr?.release()
            rgba?.release()
            bitmap.recycle()
        }
    }

    /**
     * Crops to [quad] (normalized [0,1] coordinates, corner order topLeft,
     * topRight, bottomRight, bottomLeft) then runs FairScan's perspective
     * correction and enhancement. The source file is only ever read.
     */
    fun cropImage(request: CropRequest): CropResult {
        val result = process(
            ScanRequest(
                sourcePath = request.sourcePath,
                outputDir = request.outputDir,
                maxPixels = request.maxPixels,
                jpegQuality = request.jpegQuality,
                colorMode = request.colorMode,
                maxDecodePixels = request.maxDecodePixels,
                manualQuad = request.quad,
            ),
        )
        return CropResult(
            outputFile = result.outputFile,
            outputFormat = result.outputFormat,
            outputWidth = result.outputWidth,
            outputHeight = result.outputHeight,
            fileBytes = result.fileBytes,
            colorMode = result.colorMode,
            timings = result.timings,
        )
    }

    /**
     * IMPORT first (FairScan's gallery entry point: single 0.9 threshold), then
     * CAPTURE (multi-threshold + min-area-rect fallback) when that finds nothing.
     * This is the exact fallback ladder FairScan ships, surfaced so callers can
     * tell which path produced the frame. The quad is returned in normalized
     * [0,1] coordinates so the Flutter overlay can draw it resolution-
     * independently; re-expand to source pixels with
     * `quad.scaledTo(1.0, 1.0, width, height)`.
     */
    private fun detectQuad(
        segmentation: FairScanSegmenter.Segmentation,
        size: ImageSize,
    ): Pair<Quad?, String> {
        val importQuad = detectDocumentQuad(segmentation, size, Mode.IMPORT)
        val inMask = importQuad ?: detectDocumentQuad(segmentation, size, Mode.CAPTURE)
            ?: return null to "none"
        // `detectDocumentQuad` returns mask coordinates; rescale to source, then
        // normalize so the UI overlay is resolution independent.
        val normalized = inMask
            .scaledTo(
                segmentation.width.toDouble(),
                segmentation.height.toDouble(),
                size.width.toDouble(),
                size.height.toDouble(),
            )
            .scaledTo(size.width.toDouble(), size.height.toDouble(), 1.0, 1.0)
        return normalized to (if (importQuad != null) "import" else "capture")
    }

    /** Confidence of a detected frame, broken into its two failure modes. */
    data class QuadScore(
        /** Final confidence in [0,1]; the UI compares this with its threshold. */
        val score: Double,
        /** Mean paper probability inside the quad — "is this all page?". */
        val meanProb: Double,
        /** Share of the model's paper mask the quad covers — "is the whole page in frame?". */
        val coverage: Double,
        /** Share of the photo the quad covers — "does this frame look like a page or a strip?". */
        val frameFill: Double,
    )

    /**
     * Scores a detected frame against the segmentation mask. [quad] is
     * normalized [0,1]; it is expanded to the mask's pixel grid so
     * `fillConvexPoly` and the mask Mat agree.
     *
     * A high interior probability alone is not enough: a frame that lands
     * entirely inside the page scores ~1.0 while silently cutting off formulas.
     * The second term therefore measures how much of the *visible paper* the
     * quad actually covers, so a frame that only grabs a strip of the page
     * drops below the UI threshold and is routed to the corner editor.
     */
    private fun scoreQuad(
        segmentation: FairScanSegmenter.Segmentation,
        quad: Quad,
    ): QuadScore {
        val inMask = quad.scaledTo(
            1.0,
            1.0,
            segmentation.width.toDouble(),
            segmentation.height.toDouble(),
        )
        val points = listOf(inMask.topLeft, inMask.topRight, inMask.bottomRight, inMask.bottomLeft)
            .map { org.opencv.core.Point(it.x, it.y) }
        val poly = MatOfPoint(*points.toTypedArray())
        val mask = Mat.zeros(segmentation.height, segmentation.width, CvType.CV_8UC1)
        val binMask: Mat? = segmentation.toMat()
        try {
            Imgproc.fillConvexPoly(mask, poly, org.opencv.core.Scalar(255.0))
            val meanProb = (Core.mean(binMask, mask).`val`[0] / 255.0).coerceIn(0.0, 1.0)
            val paperPixels = Core.countNonZero(binMask)
            // Overlap = (share of the quad that is paper) x (quad mask area);
            // avoids an extra bitwise temp Mat for a plain pixel count.
            val maskPixels = Core.countNonZero(mask).toDouble()
            val coverage = if (paperPixels > 0 && maskPixels > 0.0) {
                (meanProb * maskPixels / paperPixels).coerceIn(0.0, 1.0)
            } else {
                0.0
            }
            // Quad area as a share of the photo, straight from the normalized
            // corners, so a frame that grabs a strip of the page is penalised
            // even when that strip is 100% paper.
            val frameFill = FrameScore.polygonArea(quad)
            return QuadScore(
                score = FrameScore.combine(meanProb, coverage, frameFill),
                meanProb = meanProb,
                coverage = coverage,
                frameFill = frameFill,
            )
        } finally {
            poly.release()
            mask.release()
            binMask?.release()
        }
    }

    /** Builds a [Quad] from four normalized points, rejecting malformed input
     *  early so a bad drag from the UI can't produce a garbage warp. */
    private fun quadFromNormalized(points: List<Point>?): Quad {
        if (points == null || points.size != CORNER_COUNT) {
            throw ScanFailure("INVALID_QUAD", "四角坐标必须是 4 个点，实际 ${points?.size ?: 0} 个")
        }
        val quad = Quad(points[0], points[1], points[2], points[3])
        if (!quad.isConvex()) {
            throw ScanFailure("INVALID_QUAD", "四角顺序需要按左上、右上、右下、左下且不自交")
        }
        return quad
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

    /** Crops [EdgeInset.DEFAULT_PX] from each edge, returning a new Mat. */
    private fun trimOuterEdge(input: Mat): Mat {
        val rect = EdgeInset.rect(input.cols(), input.rows())
        if (rect[0] == 0 && rect[1] == 0 && rect[2] == input.cols() && rect[3] == input.rows()) {
            return input
        }
        val cropped = input.submat(rect[1], rect[1] + rect[3], rect[0], rect[0] + rect[2]).clone()
        input.release()
        return cropped
    }

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
