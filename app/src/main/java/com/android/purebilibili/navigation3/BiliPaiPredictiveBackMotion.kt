// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 InstallerX Revived contributors
// Adapted for BiliPai Navigation3 predictive back animation styles.
package com.android.purebilibili.navigation3

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.dp
import androidx.navigation3.scene.Scene
import androidx.navigation3.ui.LocalNavAnimatedContentScope
import androidx.navigation3.ui.defaultPopTransitionSpec
import androidx.navigation3.ui.defaultPredictivePopTransitionSpec as navigation3DefaultPredictivePopTransitionSpec
import androidx.navigation3.ui.defaultTransitionSpec
import androidx.navigationevent.NavigationEvent
import androidx.navigationevent.NavigationEvent.Companion.EDGE_LEFT
import androidx.navigationevent.NavigationEventTransitionState
import androidx.navigationevent.NavigationEventTransitionState.InProgress
import com.android.purebilibili.core.store.PredictiveBackAnimationStyle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

@Composable
internal fun rememberBiliPaiPredictiveBackMotion(
    style: PredictiveBackAnimationStyle
): BiliPaiPredictiveBackMotionHandler {
    return remember(style) {
        when (style) {
            PredictiveBackAnimationStyle.NONE -> BiliPaiNoPredictiveBackMotion()
            PredictiveBackAnimationStyle.AOSP -> BiliPaiAospPredictiveBackMotion()
            PredictiveBackAnimationStyle.MIUIX -> BiliPaiMiuixPredictiveBackMotion()
            PredictiveBackAnimationStyle.SCALE -> BiliPaiScalePredictiveBackMotion()
            PredictiveBackAnimationStyle.CLASSIC -> BiliPaiClassicPredictiveBackMotion()
        }
    }
}

internal interface BiliPaiPredictiveBackMotionHandler {
    suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: BiliPaiNavKey?
    )

    fun onPagePop(
        contentPageKey: Any,
        animationScope: CoroutineScope
    ) = Unit

    @Composable
    fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: BiliPaiNavKey?
    ): Modifier

    fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPredictivePopTransitionSpec(
        @NavigationEvent.SwipeEdge swipeEdge: Int
    ): ContentTransform

    fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPopTransitionSpec(): ContentTransform

    fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onTransitionSpec(): ContentTransform
}

internal class BiliPaiNoPredictiveBackMotion : BiliPaiPredictiveBackMotionHandler {
    override suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: BiliPaiNavKey?
    ) = Unit

    @Composable
    override fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: BiliPaiNavKey?
    ): Modifier = this

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPredictivePopTransitionSpec(
        swipeEdge: Int
    ): ContentTransform = ContentTransform(
        targetContentEnter = EnterTransition.None,
        initialContentExit = ExitTransition.None,
        sizeTransform = null
    )

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPopTransitionSpec(): ContentTransform =
        defaultPopTransitionSpec<BiliPaiNavKey>().invoke(this)

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onTransitionSpec(): ContentTransform =
        defaultTransitionSpec<BiliPaiNavKey>().invoke(this)
}

internal class BiliPaiMiuixPredictiveBackMotion : BiliPaiPredictiveBackMotionHandler {
    override suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: BiliPaiNavKey?
    ) = Unit

    @Composable
    override fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: BiliPaiNavKey?
    ): Modifier = this

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPredictivePopTransitionSpec(
        swipeEdge: Int
    ): ContentTransform = navigation3DefaultPredictivePopTransitionSpec<BiliPaiNavKey>().invoke(this, swipeEdge)

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPopTransitionSpec(): ContentTransform =
        defaultPopTransitionSpec<BiliPaiNavKey>().invoke(this)

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onTransitionSpec(): ContentTransform =
        defaultTransitionSpec<BiliPaiNavKey>().invoke(this)
}

internal class BiliPaiClassicPredictiveBackMotion : BiliPaiPredictiveBackMotionHandler {
    override suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: BiliPaiNavKey?
    ) = Unit

    @Composable
    override fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: BiliPaiNavKey?
    ): Modifier = this

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPredictivePopTransitionSpec(
        swipeEdge: Int
    ): ContentTransform = classicPopTransform()

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPopTransitionSpec(): ContentTransform =
        classicPopTransform()

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onTransitionSpec(): ContentTransform =
        defaultTransitionSpec<BiliPaiNavKey>().invoke(this)
}

internal class BiliPaiAospPredictiveBackMotion : BiliPaiPredictiveBackMotionHandler {
    private var exitingPageKey: String? = null
    private val exitAnimatable = Animatable(0f)
    private var inPredictiveBackAnimation = false

    override suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: BiliPaiNavKey?
    ) {
        val isInterruptingEnter = transitionState is InProgress && !inPredictiveBackAnimation
        if (!isInterruptingEnter) {
            exitingPageKey = currentPageKey.toString()
            exitAnimatable.animateTo(
                targetValue = 1f,
                animationSpec = tween(durationMillis = 150, easing = LinearEasing)
            )
        }
    }

    override fun onPagePop(contentPageKey: Any, animationScope: CoroutineScope) {
        if (exitingPageKey == contentPageKey.toString()) {
            exitingPageKey = null
            animationScope.launch { exitAnimatable.snapTo(0f) }
        }
    }

    @Composable
    override fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: BiliPaiNavKey?
    ): Modifier = composed {
        val windowInfo = LocalWindowInfo.current
        val navContent = LocalNavAnimatedContentScope.current
        val transition = navContent.transition
        val containerHeightPx = windowInfo.containerSize.height
        val pageKey = contentPageKey.toString()
        val enteringStartOffsetPx = with(LocalDensity.current) { 96.dp.toPx() }
        val linearProgress = exitAnimatable.value
        val emphasizedProgress = CubicBezierEasing(0.2f, 0f, 0f, 1f).transform(linearProgress)
        val progressInProgress = transitionState as? InProgress
        val edge = progressInProgress?.latestEvent?.swipeEdge ?: 0
        val touchY = progressInProgress?.latestEvent?.touchY
        val gestureProgress = progressInProgress?.latestEvent?.progress ?: 0f
        val animatedScale by transition.animateFloat(
            transitionSpec = { tween(300) },
            label = "BiliPaiAospPredictiveScale"
        ) { state ->
            when (state) {
                EnterExitState.PostExit -> 0.85f
                else -> 1f
            }
        }

        if (pageKey == currentPageKey.toString()) {
            inPredictiveBackAnimation = animatedScale != 1f
        }

        val directionMultiplier = if (edge == EDGE_LEFT) 1f else -1f
        val isExitingPage = exitingPageKey != null && exitingPageKey == pageKey
        val isCurrentNavTarget = exitingPageKey == null && pageKey == currentPageKey.toString()
        val maxScale = 0.85f
        val dragScale = 1f - (1f - maxScale) * gestureProgress
        val currentPivotY = if (touchY != null && containerHeightPx > 0) {
            (touchY / containerHeightPx).coerceIn(0.1f, 0.9f)
        } else {
            0.5f
        }
        val currentPivotX = if (edge == EDGE_LEFT) 0.8f else 0.2f
        val needsClip = (transitionState is InProgress && inPredictiveBackAnimation) ||
            exitingPageKey != null

        this
            .graphicsLayer {
                if (transitionState is InProgress && !inPredictiveBackAnimation && exitingPageKey == null) {
                    return@graphicsLayer
                }
                if (transitionState is InProgress) {
                    transformOrigin = TransformOrigin(currentPivotX, currentPivotY)
                }
                when {
                    isExitingPage -> {
                        val computedScale = dragScale + (maxScale - dragScale) * emphasizedProgress
                        scaleX = computedScale
                        scaleY = computedScale
                        translationX = enteringStartOffsetPx * directionMultiplier * emphasizedProgress
                        alpha = if (linearProgress >= 0.2f) 0f else (1f - linearProgress * 5f).coerceAtLeast(0f)
                    }
                    isCurrentNavTarget -> {
                        scaleX = dragScale
                        scaleY = dragScale
                        translationX = 0f
                        alpha = 1f
                    }
                    else -> {
                        val initialTranslationX = -enteringStartOffsetPx * directionMultiplier
                        if (exitingPageKey != null) {
                            scaleX = dragScale + (1f - dragScale) * emphasizedProgress
                            scaleY = dragScale + (1f - dragScale) * emphasizedProgress
                            translationX = initialTranslationX * (1f - emphasizedProgress)
                            alpha = 1f
                        } else if (transitionState is InProgress) {
                            scaleX = dragScale
                            scaleY = dragScale
                            translationX = initialTranslationX
                            alpha = 1f
                        }
                    }
                }
            }
            .clip(if (needsClip) RoundedCornerShape(28.dp) else RoundedCornerShape(0.dp))
    }

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPredictivePopTransitionSpec(
        swipeEdge: Int
    ): ContentTransform = noRouteLayerPredictiveTransform()

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPopTransitionSpec(): ContentTransform =
        ContentTransform(
            targetContentEnter = slideInHorizontally(initialOffsetX = { -it / 4 }),
            initialContentExit = scaleOut(targetScale = 0.9f) + fadeOut(),
            sizeTransform = null
        )

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onTransitionSpec(): ContentTransform =
        defaultTransitionSpec<BiliPaiNavKey>().invoke(this)
}

internal class BiliPaiScalePredictiveBackMotion : BiliPaiPredictiveBackMotionHandler {
    private var exitingPageKey: String? = null
    private val exitAnimatable = Animatable(0f)
    private var inPredictiveBackAnimation = false

    override suspend fun onBackPressed(
        transitionState: NavigationEventTransitionState?,
        currentPageKey: BiliPaiNavKey?
    ) {
        if (inPredictiveBackAnimation && transitionState is InProgress) {
            exitingPageKey = currentPageKey.toString()
            exitAnimatable.animateTo(
                targetValue = 1f,
                animationSpec = tween(durationMillis = 200, easing = FastOutSlowInEasing)
            )
            exitAnimatable.snapTo(0f)
        }
    }

    override fun onPagePop(contentPageKey: Any, animationScope: CoroutineScope) {
        if (exitingPageKey == contentPageKey.toString()) {
            exitingPageKey = null
        }
    }

    @Composable
    override fun Modifier.predictiveBackAnimationDecorator(
        transitionState: NavigationEventTransitionState?,
        contentPageKey: Any,
        currentPageKey: BiliPaiNavKey?
    ): Modifier {
        val windowInfo = LocalWindowInfo.current
        val navContent = LocalNavAnimatedContentScope.current
        val containerHeightPx = windowInfo.containerSize.height
        val containerWidthPx = windowInfo.containerSize.width.toFloat()
        val pageKey = contentPageKey.toString()
        val transition = navContent.transition

        return if (pageKey == currentPageKey.toString() || exitingPageKey == pageKey) {
            val animatedScale by transition.animateFloat(
                transitionSpec = { tween(300) },
                label = "BiliPaiScalePredictiveScale"
            ) { state ->
                when (state) {
                    EnterExitState.PostExit -> 0.85f
                    else -> 1f
                }
            }
            inPredictiveBackAnimation = animatedScale != 1f

            val progressInProgress = transitionState as? InProgress
            val edge = progressInProgress?.latestEvent?.swipeEdge ?: 0
            val touchY = progressInProgress?.latestEvent?.touchY
            val currentPivotY = if (touchY != null && containerHeightPx > 0) {
                (touchY / containerHeightPx).coerceIn(0.1f, 0.9f)
            } else {
                0.5f
            }
            val currentPivotX = if (edge == EDGE_LEFT) 0.8f else 0.2f
            val directionMultiplier = if (edge == EDGE_LEFT) 1f else -1f
            val exitProgress = if (pageKey != currentPageKey.toString()) 1f else exitAnimatable.value
            val needsClip = inPredictiveBackAnimation || exitingPageKey != null

            graphicsLayer {
                scaleX = animatedScale
                scaleY = animatedScale
                translationX = containerWidthPx * exitProgress * directionMultiplier
                transformOrigin = TransformOrigin(currentPivotX, currentPivotY)
            }.clip(if (needsClip) RoundedCornerShape(28.dp) else RoundedCornerShape(0.dp))
        } else {
            if (transitionState is InProgress) {
                val progress = if (!inPredictiveBackAnimation) 1f else exitAnimatable.value
                val dynamicAlpha = 0.5f * (1f - progress)
                drawWithContent {
                    drawContent()
                    drawRect(color = Color.Black.copy(alpha = dynamicAlpha))
                }
            } else {
                this
            }
        }
    }

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPredictivePopTransitionSpec(
        swipeEdge: Int
    ): ContentTransform = noRouteLayerPredictiveTransform()

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onPopTransitionSpec(): ContentTransform =
        ContentTransform(
            targetContentEnter = slideInHorizontally(initialOffsetX = { -it / 4 }) + fadeIn(),
            initialContentExit = scaleOut(targetScale = 0.9f) + fadeOut(),
            sizeTransform = null
        )

    override fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.onTransitionSpec(): ContentTransform =
        defaultTransitionSpec<BiliPaiNavKey>().invoke(this)
}

internal object BiliPaiPredictiveBackMotion {
    fun <T : Any> defaultPredictivePopTransitionSpec():
        AnimatedContentTransitionScope<Scene<T>>.(@NavigationEvent.SwipeEdge Int) -> ContentTransform {
        return navigation3DefaultPredictivePopTransitionSpec()
    }
}

private fun noRouteLayerPredictiveTransform(): ContentTransform {
    return ContentTransform(
        targetContentEnter = EnterTransition.None,
        initialContentExit = ExitTransition.None,
        sizeTransform = null
    )
}

private fun AnimatedContentTransitionScope<Scene<BiliPaiNavKey>>.classicPopTransform(): ContentTransform {
    return ContentTransform(
        targetContentEnter = slideInHorizontally(initialOffsetX = { fullWidth -> -fullWidth }),
        initialContentExit = scaleOut(targetScale = 0.9f) + fadeOut(),
        sizeTransform = null
    )
}
