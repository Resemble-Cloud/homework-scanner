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

import org.fairscan.imageprocessing.Point
import org.fairscan.imageprocessing.Quad
import kotlin.math.abs

/**
 * Pure (OpenCV-free) half of the detected-frame confidence score, kept separate
 * so it can be unit tested on the JVM.
 *
 * The score answers three questions, each of which used to be invisible:
 *  1. is the frame filled with paper?            -> [combine] `meanProb`
 *  2. did the frame keep the whole visible page? -> [combine] `coverage`
 *  3. does the frame look like a page at all,    -> [combine] `frameFill`
 *     or like a strip cut out of one?
 */
object FrameScore {

    /**
     * Smallest share of the photo an auto-detected page may occupy before the
     * frame is treated as suspicious.
     *
     * Calibrated on the fixed samples (docs/quality/): the accepted frame for
     * 1.jpg fills 80% of the photo, while the two frames that clipped writing
     * filled 22% and 41%. A page photographed from further away also lands
     * below this line, and asking the user to confirm its corners is the cheap
     * outcome — silently dropping formulas is not.
     */
    const val MIN_FRAME_FILL = 0.5

    /** Area of a normalized quad, i.e. its share of the frame (shoelace). */
    fun polygonArea(quad: Quad): Double {
        val points = listOf(quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft)
        var sum = 0.0
        for (i in points.indices) {
            val a: Point = points[i]
            val b: Point = points[(i + 1) % points.size]
            sum += a.x * b.y - b.x * a.y
        }
        return (abs(sum) / 2.0).coerceIn(0.0, 1.0)
    }

    /**
     * Combines the three signals into one confidence in `[0,1]`.
     *
     * `meanProb` and `coverage` are multiplied, not averaged, so both a frame
     * full of desk and a frame holding a fragment of the page fail. `frameFill`
     * only starts to bite below [minFrameFill], which keeps normal, loosely
     * framed shots scoring high while catching "detected a strip of the page".
     */
    fun combine(
        meanProb: Double,
        coverage: Double,
        frameFill: Double,
        minFrameFill: Double = MIN_FRAME_FILL,
    ): Double {
        val paper = meanProb.coerceIn(0.0, 1.0)
        val kept = coverage.coerceIn(0.0, 1.0)
        val fill = if (minFrameFill <= 0.0) 1.0
        else (frameFill / minFrameFill).coerceIn(0.0, 1.0)
        return paper * (0.5 + 0.5 * kept) * fill
    }
}
