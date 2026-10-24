/*
 * Copyright 2025-2026 The FairScan authors
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */
package org.homeworkscanner.fairscan_engine

import android.util.Log
import org.fairscan.imageprocessing.percentileL
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.max

/**
 * Conservative low-frequency illumination flattening applied after FairScan's
 * normal enhancement.
 *
 * The existing Retinex stage handles most of the tone work. A large soft shadow
 * can still leave a 20-40 grey-level gradient across a page; this pass estimates
 * that low-frequency field with a wide Gaussian and lifts dark regions toward
 * the paper background by a capped amount. Ink edges are high-frequency and are
 * deliberately left mostly untouched.
 */
object ShadowCorrection {
    private const val TAG = "ShadowCorrection"
    private const val STRENGTH = 0.22
    private const val MIN_RANGE = 14.0

    fun applyIfNeeded(input: Mat): Mat {
        if (input.channels() != 3) return input
        val maxDim = max(input.cols(), input.rows()).toDouble()
        if (maxDim < 64) return input

        val lab = Mat()
        Imgproc.cvtColor(input, lab, Imgproc.COLOR_BGR2Lab)
        val channels = ArrayList<Mat>(3)
        Core.split(lab, channels)
        val l = channels[0]
        val lFloat = Mat()
        l.convertTo(lFloat, CvType.CV_32F)
        val background = Mat()
        try {
            Imgproc.GaussianBlur(
                lFloat,
                background,
                Size(0.0, 0.0),
                (maxDim / 12.0).coerceAtLeast(8.0),
            )
            val background8u = Mat()
            background.convertTo(background8u, CvType.CV_8U)
            val range = percentileL(background8u, 0.95) - percentileL(background8u, 0.05)
            background8u.release()
            if (range < MIN_RANGE) return input

            val target = percentileL(l, 0.75)
            val corrected = Mat()
            // L + strength * (target - background)
            Core.addWeighted(
                lFloat,
                1.0,
                background,
                -STRENGTH,
                target * STRENGTH,
                corrected,
            )
            Core.min(corrected, org.opencv.core.Scalar(255.0), corrected)
            Core.max(corrected, org.opencv.core.Scalar(0.0), corrected)
            corrected.convertTo(channels[0], CvType.CV_8U)
            corrected.release()

            val merged = Mat()
            Core.merge(channels, merged)
            val out = Mat()
            Imgproc.cvtColor(merged, out, Imgproc.COLOR_Lab2BGR)
            merged.release()
            Log.i(TAG, "shadow flatten applied, background range=${"%.1f".format(range)}")
            return out
        } finally {
            lFloat.release()
            background.release()
            channels.forEach { it.release() }
            lab.release()
        }
    }

    /** Exposed for a small JVM unit test of the activation guard. */
    fun shouldApply(range: Double): Boolean = range >= MIN_RANGE
}
