package org.homeworkscanner.fairscan_engine

import org.assertj.core.api.Assertions.assertThat
import org.junit.Test

class EdgeInsetTest {

    @Test
    fun `default inset removes two pixels from every edge`() {
        assertThat(EdgeInset.rect(4000, 3000)).containsExactly(2, 2, 3996, 2996)
    }

    @Test
    fun `zero inset keeps the full image`() {
        assertThat(EdgeInset.rect(100, 80, 0)).containsExactly(0, 0, 100, 80)
    }

    @Test
    fun `too-small images are not cropped into invalid dimensions`() {
        assertThat(EdgeInset.rect(4, 3)).containsExactly(0, 0, 4, 3)
    }

    @Test
    fun `negative inset is clamped to zero`() {
        assertThat(EdgeInset.rect(10, 10, -5)).containsExactly(0, 0, 10, 10)
    }
}
