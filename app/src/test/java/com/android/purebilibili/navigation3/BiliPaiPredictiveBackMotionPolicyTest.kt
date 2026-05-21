package com.android.purebilibili.navigation3

import com.android.purebilibili.core.store.PredictiveBackAnimationStyle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class BiliPaiPredictiveBackMotionPolicyTest {

    @Test
    fun predictiveBackMotionClasses_preserveInstallerXStyleMapping() {
        val handlers: List<Any> = listOf(
            BiliPaiNoPredictiveBackMotion(),
            BiliPaiAospPredictiveBackMotion(),
            BiliPaiMiuixPredictiveBackMotion(),
            BiliPaiScalePredictiveBackMotion(),
            BiliPaiClassicPredictiveBackMotion()
        )

        handlers.forEach { handler ->
            assertTrue(handler is BiliPaiPredictiveBackMotionHandler)
        }
    }

    @Test
    fun predictiveBackStyleValues_matchPersistedWireValues() {
        assertEquals("none", PredictiveBackAnimationStyle.NONE.value)
        assertEquals("aosp", PredictiveBackAnimationStyle.AOSP.value)
        assertEquals("miuix", PredictiveBackAnimationStyle.MIUIX.value)
        assertEquals("scale", PredictiveBackAnimationStyle.SCALE.value)
        assertEquals("ksu_classic", PredictiveBackAnimationStyle.CLASSIC.value)
    }
}
