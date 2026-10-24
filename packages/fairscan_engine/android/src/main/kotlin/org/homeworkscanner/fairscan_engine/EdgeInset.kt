/*
 * Copyright 2025-2026 The FairScan authors
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version.
 */
package org.homeworkscanner.fairscan_engine

/**
 * Removes the outermost interpolated pixels produced by perspective warping.
 *
 * OpenCV's warp can sample outside the source at the border; on high-contrast
 * pages this shows up as a thin black line along the top/left edge. Insetting
 * by 2 px removes it without a second encode and without changing the page
 * aspect in any measurable way.
 */
object EdgeInset {
    const val DEFAULT_PX = 2

    /** Returns `[x, y, width, height]` after insetting, or the full image. */
    fun rect(width: Int, height: Int, insetPx: Int = DEFAULT_PX): IntArray {
        val inset = insetPx.coerceAtLeast(0)
        if (width <= inset * 2 || height <= inset * 2) {
            return intArrayOf(0, 0, width.coerceAtLeast(0), height.coerceAtLeast(0))
        }
        return intArrayOf(inset, inset, width - inset * 2, height - inset * 2)
    }
}
