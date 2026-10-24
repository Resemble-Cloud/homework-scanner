package org.homeworkscanner.fairscan_engine

import org.assertj.core.api.Assertions.assertThat
import org.junit.Test

class ShadowCorrectionTest {

    @Test
    fun `flat pages do not trigger the shadow pass`() {
        assertThat(ShadowCorrection.shouldApply(0.0)).isFalse()
        assertThat(ShadowCorrection.shouldApply(13.9)).isFalse()
    }

    @Test
    fun `real illumination gradients trigger the shadow pass`() {
        assertThat(ShadowCorrection.shouldApply(14.0)).isTrue()
        assertThat(ShadowCorrection.shouldApply(60.0)).isTrue()
    }
}
