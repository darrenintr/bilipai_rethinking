package com.android.purebilibili.navigation3

import com.android.purebilibili.core.store.PredictiveBackAnimationStyle
import com.android.purebilibili.navigation.AppSystemBackAction
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BiliPaiNavMotionPolicyTest {

    @Test
    fun predictiveEnabledWithCards_usesNavDisplayPredictiveMode() {
        assertEquals(
            BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY,
            resolveBiliPaiNavMotionMode(
                predictiveBackAnimationStyle = PredictiveBackAnimationStyle.AOSP,
                cardTransitionEnabled = true
            )
        )
    }

    @Test
    fun predictiveDisabledWithCards_usesClassicCardMode() {
        assertEquals(
            BiliPaiNavMotionMode.CLASSIC_CARD,
            resolveBiliPaiNavMotionMode(
                predictiveBackAnimationStyle = PredictiveBackAnimationStyle.NONE,
                cardTransitionEnabled = true
            )
        )
    }

    @Test
    fun installerXStylesWithCards_useNavDisplayPredictiveMode() {
        listOf(
            PredictiveBackAnimationStyle.AOSP,
            PredictiveBackAnimationStyle.MIUIX,
            PredictiveBackAnimationStyle.SCALE,
            PredictiveBackAnimationStyle.CLASSIC
        ).forEach { style ->
            assertEquals(
                BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY,
                resolveBiliPaiNavMotionMode(
                    predictiveBackAnimationStyle = style,
                    cardTransitionEnabled = true
                )
            )
        }
    }

    @Test
    fun sharedElementReady_videoReturn_prefersNoOpRouteLayer() {
        val decision = resolveBiliPaiNavMotionDecision(
            fromKey = BiliPaiNavKey.VideoDetail("BV1"),
            toKey = BiliPaiNavKey.Home,
            predictiveBackAnimationStyle = PredictiveBackAnimationStyle.AOSP,
            cardTransitionEnabled = true,
            sharedTransitionReady = true
        )

        assertEquals(BiliPaiNavRouteTransition.NO_OP_SHARED_ELEMENT, decision.routeTransition)
        assertFalse(decision.interceptSystemBack)
    }

    @Test
    fun predictiveEnabledSharedVideoReturnLetsNavDisplayOwnBackGesture() {
        val decision = resolveBiliPaiBackGestureDecision(
            predictiveBackAnimationStyle = PredictiveBackAnimationStyle.AOSP,
            cardTransitionEnabled = true,
            systemBackAction = AppSystemBackAction.NAVIGATE_UP,
            currentKey = BiliPaiNavKey.VideoDetail("BV1", sourceRoute = "home"),
            previousKey = BiliPaiNavKey.Home,
            sourceMetadata = BiliPaiNavSourceMetadata(
                sourceKey = "home:BV1",
                sourceRoute = "home",
                clickedBoundsRecorded = true,
                cardFullyVisible = true
            )
        )

        assertEquals(BiliPaiBackGestureOwner.NAV_DISPLAY_PREDICTIVE, decision.owner)
        assertEquals(BiliPaiNavRouteTransition.NO_OP_SHARED_ELEMENT, decision.routeTransition)
        assertFalse(decision.interceptSystemBack)
    }

    @Test
    fun predictiveEnabledStaleVideoReturnUsesNavDisplayDefaultPredictivePop() {
        val decision = resolveBiliPaiBackGestureDecision(
            predictiveBackAnimationStyle = PredictiveBackAnimationStyle.AOSP,
            cardTransitionEnabled = true,
            systemBackAction = AppSystemBackAction.NAVIGATE_UP,
            currentKey = BiliPaiNavKey.VideoDetail("BV2", sourceRoute = "home"),
            previousKey = BiliPaiNavKey.Home,
            sourceMetadata = BiliPaiNavSourceMetadata(
                sourceKey = "home:BV1",
                sourceRoute = "home",
                clickedBoundsRecorded = true,
                cardFullyVisible = true
            )
        )

        assertEquals(BiliPaiBackGestureOwner.NAV_DISPLAY_PREDICTIVE, decision.owner)
        assertEquals(BiliPaiNavRouteTransition.NAV_DISPLAY_DEFAULT_PREDICTIVE, decision.routeTransition)
        assertFalse(decision.interceptSystemBack)
    }

    @Test
    fun predictiveDisabledNavigateUpUsesClassicAppBack() {
        val decision = resolveBiliPaiBackGestureDecision(
            predictiveBackAnimationStyle = PredictiveBackAnimationStyle.NONE,
            cardTransitionEnabled = true,
            systemBackAction = AppSystemBackAction.NAVIGATE_UP,
            currentKey = BiliPaiNavKey.VideoDetail("BV1", sourceRoute = "home"),
            previousKey = BiliPaiNavKey.Home,
            sourceMetadata = BiliPaiNavSourceMetadata(
                sourceKey = "home:BV1",
                sourceRoute = "home",
                clickedBoundsRecorded = true,
                cardFullyVisible = true
            )
        )

        assertEquals(BiliPaiBackGestureOwner.APP_CLASSIC, decision.owner)
        assertEquals(BiliPaiNavRouteTransition.NO_OP_SHARED_ELEMENT, decision.routeTransition)
        assertTrue(decision.interceptSystemBack)
    }

    @Test
    fun returnToHomeTabAlwaysUsesAppActionBack() {
        val decision = resolveBiliPaiBackGestureDecision(
            predictiveBackAnimationStyle = PredictiveBackAnimationStyle.AOSP,
            cardTransitionEnabled = true,
            systemBackAction = AppSystemBackAction.RETURN_TO_HOME_TAB,
            currentKey = BiliPaiNavKey.MainHost,
            previousKey = null,
            sourceMetadata = BiliPaiNavSourceMetadata()
        )

        assertEquals(BiliPaiBackGestureOwner.APP_ACTION, decision.owner)
        assertEquals(BiliPaiNavRouteTransition.FALLBACK, decision.routeTransition)
        assertTrue(decision.interceptSystemBack)
    }

    @Test
    fun navDisplayPredictivePop_sharedReadyVideoReturn_keepsRouteLayerNoOp() {
        val transition = resolveBiliPaiNavDisplayPredictivePopRouteTransition(
            motionMode = BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY,
            sourceMetadata = BiliPaiNavSourceMetadata(
                sourceKey = "history:BV1",
                sourceRoute = "history",
                clickedBoundsRecorded = true,
                cardFullyVisible = true
            ),
            fromKey = BiliPaiNavKey.VideoDetail("BV1", sourceRoute = "history"),
            toKey = BiliPaiNavKey.History
        )

        assertEquals(BiliPaiNavRouteTransition.NO_OP_SHARED_ELEMENT, transition)
    }

    @Test
    fun navDisplayPredictivePop_withoutSharedReady_usesNavDisplayDefaultPredictivePop() {
        val transition = resolveBiliPaiNavDisplayPredictivePopRouteTransition(
            motionMode = BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY,
            sourceMetadata = BiliPaiNavSourceMetadata(
                sourceKey = "history:BV1",
                sourceRoute = "history",
                clickedBoundsRecorded = true,
                cardFullyVisible = false
            ),
            fromKey = BiliPaiNavKey.VideoDetail("BV1", sourceRoute = "history"),
            toKey = BiliPaiNavKey.History
        )

        assertEquals(BiliPaiNavRouteTransition.NAV_DISPLAY_DEFAULT_PREDICTIVE, transition)
    }

    @Test
    fun navDisplayPredictivePop_withStaleVideoSource_usesNavDisplayDefaultPredictivePop() {
        val transition = resolveBiliPaiNavDisplayPredictivePopRouteTransition(
            motionMode = BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY,
            sourceMetadata = BiliPaiNavSourceMetadata(
                sourceKey = "history:BV1",
                sourceRoute = "history",
                clickedBoundsRecorded = true,
                cardFullyVisible = true
            ),
            fromKey = BiliPaiNavKey.VideoDetail("BV2", sourceRoute = "history"),
            toKey = BiliPaiNavKey.History
        )

        assertEquals(BiliPaiNavRouteTransition.NAV_DISPLAY_DEFAULT_PREDICTIVE, transition)
    }

    @Test
    fun sharedElementReady_homeVideoForward_prefersNoOpRouteLayer() {
        val decision = resolveBiliPaiNavMotionDecision(
            fromKey = BiliPaiNavKey.Home,
            toKey = BiliPaiNavKey.VideoDetail("BV1", sourceRoute = "home"),
            predictiveBackAnimationStyle = PredictiveBackAnimationStyle.NONE,
            cardTransitionEnabled = true,
            sharedTransitionReady = true
        )

        assertEquals(BiliPaiNavRouteTransition.NO_OP_SHARED_ELEMENT, decision.routeTransition)
        assertTrue(decision.interceptSystemBack)
    }

    @Test
    fun classicCardMode_interceptsSystemBackSoNavDisplayDoesNotOwnPrediction() {
        val decision = resolveBiliPaiNavMotionDecision(
            fromKey = BiliPaiNavKey.VideoDetail("BV1"),
            toKey = BiliPaiNavKey.Home,
            predictiveBackAnimationStyle = PredictiveBackAnimationStyle.NONE,
            cardTransitionEnabled = true,
            sharedTransitionReady = false
        )

        assertEquals(BiliPaiNavMotionMode.CLASSIC_CARD, decision.mode)
        assertEquals(BiliPaiNavRouteTransition.CLASSIC_CARD, decision.routeTransition)
        assertTrue(decision.interceptSystemBack)
    }

    @Test
    fun appBackActionInterception_winsEvenWhenPredictiveBackIsEnabled() {
        assertTrue(
            shouldInterceptSystemBackForNavigation3(
                mode = BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY,
                appBackActionRequiresInterception = true
            )
        )
        assertFalse(
            shouldInterceptSystemBackForNavigation3(
                mode = BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY,
                appBackActionRequiresInterception = false
            )
        )
    }
}
