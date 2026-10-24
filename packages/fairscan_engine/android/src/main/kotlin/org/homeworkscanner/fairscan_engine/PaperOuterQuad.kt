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
 */
package org.homeworkscanner.fairscan_engine

import org.fairscan.imageprocessing.ImageSize
import org.fairscan.imageprocessing.Mask
import org.fairscan.imageprocessing.Point
import org.fairscan.imageprocessing.Quad
import org.fairscan.imageprocessing.createQuad
import org.fairscan.imageprocessing.refineMask
import org.fairscan.imageprocessing.scaledTo
import org.opencv.core.Mat
import org.opencv.core.MatOfInt
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.imgproc.Imgproc
import kotlin.math.abs
import kotlin.math.max

/**
 * Builds a conservative "whole sheet" candidate from the paper mask.
 *
 * The normal detector is tuned for a single document edge and can settle on one
 * half of an open notebook. This candidate takes the convex hull of all
 * meaningful paper contours and fits a minimum-area rectangle around it, so both
 * pages of a spread stay inside the crop. It deliberately does not replace the
 * detector; the UI/controller compares its content coverage and background with
 * the detector's quad.
 */
object PaperOuterQuad {
    private const val MIN_CONTOUR_SHARE = 0.03
    private const val MIN_RELATIVE_CONTOUR_SHARE = 0.08
    private const val MIN_OUTPUT_AREA = 0.05

    fun detect(mask: Mask, sourceSize: ImageSize): Quad? {
        val maskMat = mask.toMat()
        val refined = refineMask(maskMat)
        maskMat.release()
        val contours = mutableListOf<MatOfPoint>()
        val hierarchy = Mat()
        var hullIndices: MatOfInt? = null
        var hull2f: MatOfPoint2f? = null
        try {
            Imgproc.findContours(
                refined,
                contours,
                hierarchy,
                Imgproc.RETR_EXTERNAL,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )
            if (contours.isEmpty()) return null
            val maskArea = refined.cols().toDouble() * refined.rows()
            val areas = contours.map { abs(Imgproc.contourArea(it)) }
            val maxArea = areas.maxOrNull() ?: return null
            val minArea = max(maskArea * MIN_CONTOUR_SHARE, maxArea * MIN_RELATIVE_CONTOUR_SHARE)

            val points = mutableListOf<org.opencv.core.Point>()
            contours.forEachIndexed { index, contour ->
                if (areas[index] >= minArea) points.addAll(contour.toList())
            }
            if (points.size < 4) return null

            val allPoints = MatOfPoint(*points.toTypedArray())
            hullIndices = MatOfInt()
            try {
                Imgproc.convexHull(allPoints, hullIndices)
                val hullPoints = hullIndices.toArray().map { points[it] }
                if (hullPoints.size < 4) return null

                hull2f = MatOfPoint2f(*hullPoints.toTypedArray())
                val rect = Imgproc.minAreaRect(hull2f)
                val raw = Array(4) { org.opencv.core.Point() }
                rect.points(raw)
                val sorted = createQuad(raw.map { Point(it.x, it.y) })
                val normalized = sorted
                    .scaledTo(
                        refined.cols().toDouble(),
                        refined.rows().toDouble(),
                        sourceSize.width.toDouble(),
                        sourceSize.height.toDouble(),
                    )
                    .scaledTo(
                        sourceSize.width.toDouble(),
                        sourceSize.height.toDouble(),
                        1.0,
                        1.0,
                    )
                val clamped = Quad(
                    normalized.topLeft.clamp(),
                    normalized.topRight.clamp(),
                    normalized.bottomRight.clamp(),
                    normalized.bottomLeft.clamp(),
                )
                if (!clamped.isConvex()) return null
                if (FrameScore.polygonArea(clamped) < MIN_OUTPUT_AREA) return null
                return clamped
            } finally {
                allPoints.release()
            }
        } finally {
            hull2f?.release()
            hullIndices?.release()
            contours.forEach { it.release() }
            hierarchy.release()
            refined.release()
        }
    }

    private fun Point.clamp(): Point = Point(
        x.coerceIn(0.0, 1.0),
        y.coerceIn(0.0, 1.0),
    )
}
