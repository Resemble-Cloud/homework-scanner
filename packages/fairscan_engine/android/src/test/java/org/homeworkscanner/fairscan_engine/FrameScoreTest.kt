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

import org.assertj.core.api.Assertions.assertThat
import org.fairscan.imageprocessing.Point
import org.fairscan.imageprocessing.Quad
import org.junit.Test

class FrameScoreTest {

    private fun quad(x0: Double, y0: Double, x1: Double, y1: Double) = Quad(
        topLeft = Point(x0, y0),
        topRight = Point(x1, y0),
        bottomRight = Point(x1, y1),
        bottomLeft = Point(x0, y1),
    )

    @Test
    fun `polygonArea 返回归一化四角占取景框的比例`() {
        assertThat(FrameScore.polygonArea(quad(0.0, 0.0, 1.0, 1.0))).isCloseTo(
            1.0,
            org.assertj.core.data.Offset.offset(1e-9),
        )
        // Half-width, full-height frame: the failure mode seen on sample 2.jpg.
        assertThat(FrameScore.polygonArea(quad(0.25, 0.0, 0.75, 1.0))).isCloseTo(
            0.5,
            org.assertj.core.data.Offset.offset(1e-9),
        )
        assertThat(FrameScore.polygonArea(quad(0.25, 0.25, 0.75, 0.75))).isCloseTo(
            0.25,
            org.assertj.core.data.Offset.offset(1e-9),
        )
    }

    @Test
    fun `polygonArea 与角点书写方向无关`() {
        val clockwise = quad(0.1, 0.2, 0.9, 0.8)
        val reversed = Quad(
            clockwise.topLeft,
            clockwise.bottomLeft,
            clockwise.bottomRight,
            clockwise.topRight,
        )
        assertThat(FrameScore.polygonArea(reversed)).isCloseTo(
            FrameScore.polygonArea(clockwise),
            org.assertj.core.data.Offset.offset(1e-9),
        )
    }

    @Test
    fun `整页取景在纸面完全命中时得分接近满分`() {
        // Sample 1.jpg: 80% of the photo, all paper, whole page kept.
        assertThat(FrameScore.combine(meanProb = 0.95, coverage = 0.99, frameFill = 0.80))
            .isGreaterThan(0.85)
    }

    @Test
    fun `只框住纸面一条时得分被压到阈值以下`() {
        // Sample 2.jpg measured 0.89 paper fill but only 22% of the frame.
        val score = FrameScore.combine(meanProb = 0.89, coverage = 0.85, frameFill = 0.22)
        assertThat(score).isLessThan(0.85)
    }

    @Test
    fun `框到桌面时得分被压到阈值以下`() {
        // Sample 3.jpg: frame overshot the page, half of it was desk.
        val score = FrameScore.combine(meanProb = 0.55, coverage = 1.0, frameFill = 0.42)
        assertThat(score).isLessThan(0.85)
    }

    @Test
    fun `取景占比在阈值以上不再继续加分`() {
        val atThreshold = FrameScore.combine(1.0, 1.0, FrameScore.MIN_FRAME_FILL)
        val wholeFrame = FrameScore.combine(1.0, 1.0, 1.0)
        assertThat(wholeFrame).isCloseTo(atThreshold, org.assertj.core.data.Offset.offset(1e-9))
        assertThat(wholeFrame).isLessThanOrEqualTo(1.0)
    }
}
