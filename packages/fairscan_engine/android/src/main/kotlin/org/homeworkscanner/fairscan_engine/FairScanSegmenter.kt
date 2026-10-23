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
import android.graphics.Bitmap.createBitmap
import android.graphics.Color
import android.util.Log
import org.fairscan.imageprocessing.ImageSize
import org.fairscan.imageprocessing.Mask
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.support.common.FileUtil
import org.tensorflow.lite.support.common.ops.NormalizeOp
import org.tensorflow.lite.support.image.ImageProcessor
import org.tensorflow.lite.support.image.TensorImage
import org.tensorflow.lite.support.image.ops.ResizeOp
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Thin wrapper around the FairScan segmentation model (LiteRT).
 *
 * Adapted from FairScan's `app/.../domain/ImageSegmentation.kt`, minus the
 * coroutine locking (the engine already serialises calls) and their Logger.
 * The pre/post-processing must stay byte-identical to FairScan, otherwise the
 * detected mask would differ from what the rest of the pipeline expects.
 */
class FairScanSegmenter(
    private val context: Context,
    private val modelAssetName: String = MODEL_ASSET,
) {
    companion object {
        private const val TAG = "FairScanSegmenter"
        const val MODEL_ASSET = "fairscan-segmentation-model.tflite"
    }

    private var interpreter: Interpreter? = null

    fun initialize() {
        if (interpreter != null) return
        interpreter = try {
            val buffer = FileUtil.loadMappedFile(context, modelAssetName)
            Interpreter(buffer, Interpreter.Options().apply { numThreads = 2 })
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to load LiteRT model $modelAssetName", e)
            throw ScanFailure(
                code = "MODEL_INIT_FAILED",
                message = "无法加载分割模型 $modelAssetName: ${e.message}",
                cause = e,
            )
        }
    }

    fun isReady() = interpreter != null

    /** Runs one inference. Returns the probability map wrapper, never null. */
    fun segment(bitmap: Bitmap): Segmentation {
        val interpreter = interpreter ?: throw ScanFailure(
            code = "MODEL_NOT_INITIALIZED",
            message = "分割模型尚未初始化",
        )

        val start = System.nanoTime()
        val (_, h, w, _) = interpreter.getOutputTensor(0).shape()
        val imageProcessor = ImageProcessor
            .Builder()
            .add(ResizeOp(h, w, ResizeOp.ResizeMethod.BILINEAR))
            .add(NormalizeOp(127.5f, 127.5f))
            .build()
        val tensorImage = TensorImage(DataType.FLOAT32)
        tensorImage.load(bitmap)
        val processedImage = imageProcessor.process(tensorImage)

        val outputBuffer = ByteBuffer.allocateDirect(4 * h * w)
        outputBuffer.order(ByteOrder.nativeOrder())
        outputBuffer.rewind()
        interpreter.run(processedImage.tensorBuffer.buffer, outputBuffer)
        outputBuffer.rewind()

        val probmap = FloatArray(w * h)
        outputBuffer.asFloatBuffer()[probmap]
        for (i in probmap.indices) {
            probmap[i] = probmap[i].coerceIn(0f, 1f)
        }
        Log.d(TAG, "segmentation ${w}x$h in ${(System.nanoTime() - start) / 1_000_000} ms")
        return Segmentation(probmap, w, h)
    }

    fun close() {
        interpreter?.close()
        interpreter = null
    }

    data class Segmentation(
        private val probmap: FloatArray,
        override val width: Int,
        override val height: Int,
    ) : Mask {
        fun get(x: Int, y: Int): Float = probmap[y * width + x]

        fun toBinaryMask(): Bitmap {
            val bmp = createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val pixels = IntArray(width * height)
            for (i in probmap.indices) {
                val v = (probmap[i].coerceIn(0f, 1f) * 255f).toInt()
                pixels[i] = Color.rgb(v, v, v)
            }
            bmp.setPixels(pixels, 0, width, 0, 0, width, height)
            return bmp
        }

        override fun toMat(): Mat {
            val threshold = 0.5f
            val mask = Mat(height, width, CvType.CV_8UC1)
            val data = ByteArray(width * height)
            for (i in probmap.indices) {
                data[i] = if (probmap[i] >= threshold) 255.toByte() else 0.toByte()
            }
            mask.put(0, 0, data)
            return mask
        }

        fun maskSize() = ImageSize(width, height)
    }
}
