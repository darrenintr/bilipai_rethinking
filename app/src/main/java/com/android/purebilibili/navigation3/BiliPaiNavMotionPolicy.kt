package com.android.purebilibili.navigation3

import com.android.purebilibili.core.store.PredictiveBackAnimationStyle
import com.android.purebilibili.navigation.AppSystemBackAction

internal enum class BiliPaiNavMotionMode {
    CARD_DISABLED,
    CLASSIC_CARD,
    PREDICTIVE_NAV_DISPLAY
}

internal enum class BiliPaiNavRouteTransition {
    NO_OP_SHARED_ELEMENT,
    HOME_VIDEO_SHEET_FORWARD,
    HOME_VIDEO_SHEET_RETURN,
    NAV_DISPLAY_DEFAULT_PREDICTIVE,
    CLASSIC_CARD,
    FALLBACK
}

internal data class BiliPaiNavMotionDecision(
    val mode: BiliPaiNavMotionMode,
    val routeTransition: BiliPaiNavRouteTransition,
    val interceptSystemBack: Boolean
)

internal enum class BiliPaiBackGestureOwner {
    NAV_DISPLAY_PREDICTIVE,
    APP_CLASSIC,
    APP_ACTION
}

internal data class BiliPaiBackGestureDecision(
    val owner: BiliPaiBackGestureOwner,
    val routeTransition: BiliPaiNavRouteTransition
) {
    val interceptSystemBack: Boolean
        get() = owner != BiliPaiBackGestureOwner.NAV_DISPLAY_PREDICTIVE
}

internal fun resolveBiliPaiNavMotionMode(
    predictiveBackAnimationStyle: PredictiveBackAnimationStyle,
    cardTransitionEnabled: Boolean
): BiliPaiNavMotionMode {
    if (!cardTransitionEnabled) return BiliPaiNavMotionMode.CARD_DISABLED
    return if (predictiveBackAnimationStyle.usesPredictiveBack) {
        BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY
    } else {
        BiliPaiNavMotionMode.CLASSIC_CARD
    }
}

internal fun resolveBiliPaiNavMotionDecision(
    fromKey: BiliPaiNavKey?,
    toKey: BiliPaiNavKey?,
    predictiveBackAnimationStyle: PredictiveBackAnimationStyle,
    cardTransitionEnabled: Boolean,
    sharedTransitionReady: Boolean,
    appBackActionRequiresInterception: Boolean = false
): BiliPaiNavMotionDecision {
    val mode = resolveBiliPaiNavMotionMode(
        predictiveBackAnimationStyle = predictiveBackAnimationStyle,
        cardTransitionEnabled = cardTransitionEnabled
    )
    val isVideoToCardReturn = fromKey is BiliPaiNavKey.VideoDetail &&
        toKey != null &&
        isCardReturnTargetNavKey(toKey)
    val isCardToVideoForward = fromKey != null &&
        isCardReturnTargetNavKey(fromKey) &&
        toKey is BiliPaiNavKey.VideoDetail
    val routeTransition = when {
        cardTransitionEnabled &&
            sharedTransitionReady &&
            (isVideoToCardReturn || isCardToVideoForward) ->
            BiliPaiNavRouteTransition.NO_OP_SHARED_ELEMENT
        mode == BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY ->
            BiliPaiNavRouteTransition.NAV_DISPLAY_DEFAULT_PREDICTIVE
        mode == BiliPaiNavMotionMode.CLASSIC_CARD ->
            BiliPaiNavRouteTransition.CLASSIC_CARD
        else -> BiliPaiNavRouteTransition.FALLBACK
    }

    return BiliPaiNavMotionDecision(
        mode = mode,
        routeTransition = routeTransition,
        interceptSystemBack = shouldInterceptSystemBackForNavigation3(
            mode = mode,
            appBackActionRequiresInterception = appBackActionRequiresInterception
        )
    )
}

internal fun resolveBiliPaiBackGestureDecision(
    predictiveBackAnimationStyle: PredictiveBackAnimationStyle,
    cardTransitionEnabled: Boolean,
    systemBackAction: AppSystemBackAction,
    currentKey: BiliPaiNavKey?,
    previousKey: BiliPaiNavKey?,
    sourceMetadata: BiliPaiNavSourceMetadata
): BiliPaiBackGestureDecision {
    val motionMode = resolveBiliPaiNavMotionMode(
        predictiveBackAnimationStyle = predictiveBackAnimationStyle,
        cardTransitionEnabled = cardTransitionEnabled
    )
    val routeTransition = resolveBiliPaiNavDisplayPredictivePopRouteTransition(
        motionMode = motionMode,
        sourceMetadata = sourceMetadata,
        fromKey = currentKey,
        toKey = previousKey
    )
    val owner = when (systemBackAction) {
        AppSystemBackAction.RETURN_TO_HOME_TAB -> BiliPaiBackGestureOwner.APP_ACTION
        AppSystemBackAction.NAVIGATE_UP -> {
            if (predictiveBackAnimationStyle.usesPredictiveBack) {
                BiliPaiBackGestureOwner.NAV_DISPLAY_PREDICTIVE
            } else {
                BiliPaiBackGestureOwner.APP_CLASSIC
            }
        }
        AppSystemBackAction.FINISH_ACTIVITY -> {
            if (predictiveBackAnimationStyle.usesPredictiveBack) {
                BiliPaiBackGestureOwner.NAV_DISPLAY_PREDICTIVE
            } else {
                BiliPaiBackGestureOwner.APP_CLASSIC
            }
        }
    }
    return BiliPaiBackGestureDecision(
        owner = owner,
        routeTransition = if (owner == BiliPaiBackGestureOwner.APP_ACTION) {
            BiliPaiNavRouteTransition.FALLBACK
        } else {
            routeTransition
        }
    )
}

internal fun resolveBiliPaiNavDisplayPredictivePopRouteTransition(
    motionMode: BiliPaiNavMotionMode,
    sourceMetadata: BiliPaiNavSourceMetadata,
    fromKey: BiliPaiNavKey?,
    toKey: BiliPaiNavKey?
): BiliPaiNavRouteTransition {
    val fromVideoKey = fromKey as? BiliPaiNavKey.VideoDetail
    val normalizedSourceRoute = sourceMetadata.sourceRoute?.substringBefore("?")
    val normalizedVideoRoute = fromVideoKey?.sourceRoute?.substringBefore("?")
    val sourceMatchesCurrentVideo = fromVideoKey != null &&
        normalizedSourceRoute != null &&
        normalizedVideoRoute == normalizedSourceRoute &&
        sourceMetadata.sourceKey == "$normalizedSourceRoute:${fromVideoKey.bvid}"
    val sharedReadyVideoToSourceCard = sourceMetadata.sharedTransitionReady &&
        sourceMatchesCurrentVideo &&
        toKey != null &&
        isCardReturnTargetNavKey(toKey)
    if (sharedReadyVideoToSourceCard) {
        return BiliPaiNavRouteTransition.NO_OP_SHARED_ELEMENT
    }
    return if (shouldUseNavigation3PredictivePop(motionMode)) {
        BiliPaiNavRouteTransition.NAV_DISPLAY_DEFAULT_PREDICTIVE
    } else {
        BiliPaiNavRouteTransition.CLASSIC_CARD
    }
}

internal fun shouldInterceptSystemBackForNavigation3(
    mode: BiliPaiNavMotionMode,
    appBackActionRequiresInterception: Boolean
): Boolean {
    if (appBackActionRequiresInterception) return true
    return mode == BiliPaiNavMotionMode.CLASSIC_CARD
}

internal fun shouldUseNavigation3PredictivePop(mode: BiliPaiNavMotionMode): Boolean {
    return mode == BiliPaiNavMotionMode.PREDICTIVE_NAV_DISPLAY
}
