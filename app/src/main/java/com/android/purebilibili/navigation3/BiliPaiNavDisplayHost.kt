package com.android.purebilibili.navigation3

import android.app.Application
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.HasDefaultViewModelProviderFactory
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.CreationExtras
import androidx.lifecycle.viewmodel.MutableCreationExtras
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.navigation3.runtime.NavEntryDecorator
import androidx.navigation3.runtime.rememberDecoratedNavEntries
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.LocalNavAnimatedContentScope
import androidx.navigation3.ui.NavDisplay
import androidx.navigation3.scene.SceneInfo
import androidx.navigation3.scene.SinglePaneSceneStrategy
import androidx.navigation3.scene.rememberSceneState
import androidx.navigationevent.compose.NavigationBackHandler
import androidx.navigationevent.compose.NavigationEventState
import androidx.navigationevent.compose.rememberNavigationEventState
import com.android.purebilibili.core.store.PredictiveBackAnimationStyle
import com.android.purebilibili.core.ui.ProvideAnimatedVisibilityScope
import com.android.purebilibili.core.ui.transition.LocalVideoCardSharedElementSourceRoute
import kotlinx.coroutines.launch

@Composable
internal fun BiliPaiNavDisplayHost(
    backStack: List<BiliPaiNavKey>,
    motionMode: BiliPaiNavMotionMode,
    predictiveBackAnimationStyle: PredictiveBackAnimationStyle,
    sourceMetadata: BiliPaiNavSourceMetadata,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    sharedTransitionScope: SharedTransitionScope? = null,
    visibleBottomBarRoutes: Set<String> = emptySet(),
    content: @Composable (BiliPaiNavKey) -> Unit
) {
    val safeBackStack = remember(backStack) {
        backStack.ifEmpty { listOf(BiliPaiNavKey.MainHost) }
    }
    val application = LocalContext.current.applicationContext as Application
    val navigationScope = rememberCoroutineScope()
    val predictiveBackMotion = rememberBiliPaiPredictiveBackMotion(predictiveBackAnimationStyle)
    var navigationEventState: NavigationEventState<SceneInfo<BiliPaiNavKey>>? = null
    val scopedContent: @Composable (BiliPaiNavKey) -> Unit = remember(content, application) {
        { key ->
            ProvideAnimatedVisibilityScope(
                animatedVisibilityScope = LocalNavAnimatedContentScope.current
            ) {
                CompositionLocalProvider(
                    LocalVideoCardSharedElementSourceRoute provides key.toLegacyRoute()
                ) {
                    ProvideNavigation3ViewModelApplicationExtras(application) {
                        content(key)
                    }
                }
            }
        }
    }
    val entryProvider = remember(sourceMetadata, visibleBottomBarRoutes, scopedContent) {
        biliPaiNavEntryProvider(
            sourceMetadata = sourceMetadata,
            visibleBottomBarRoutes = visibleBottomBarRoutes,
            content = scopedContent
        )
    }
    val entries = rememberDecoratedNavEntries(
        backStack = safeBackStack,
        entryDecorators = listOf(
            rememberSaveableStateHolderNavEntryDecorator(),
            rememberViewModelStoreNavEntryDecorator(),
            NavEntryDecorator(
                onPop = { key ->
                    predictiveBackMotion.onPagePop(
                        contentPageKey = key,
                        animationScope = navigationScope
                    )
                }
            ) { content ->
                with(predictiveBackMotion) {
                    Box(
                        modifier = Modifier.predictiveBackAnimationDecorator(
                            transitionState = navigationEventState?.transitionState,
                            contentPageKey = content.contentKey,
                            currentPageKey = safeBackStack.lastOrNull()
                        )
                    ) {
                        content.Content()
                    }
                }
            }
        ),
        entryProvider = entryProvider
    )
    val sceneState = rememberSceneState(
        entries = entries,
        sceneStrategies = listOf(SinglePaneSceneStrategy()),
        sceneDecoratorStrategies = emptyList(),
        sharedTransitionScope = sharedTransitionScope,
        onBack = onBack
    )
    val scene = sceneState.currentScene
    val currentInfo = SceneInfo(scene)
    val previousSceneInfos = sceneState.previousScenes.map { SceneInfo(it) }
    navigationEventState = rememberNavigationEventState(
        currentInfo = currentInfo,
        backInfo = previousSceneInfos
    )
    val predictivePopRouteTransition = remember(motionMode, sourceMetadata, safeBackStack) {
        resolveBiliPaiNavDisplayPredictivePopRouteTransition(
            motionMode = motionMode,
            sourceMetadata = sourceMetadata,
            fromKey = safeBackStack.lastOrNull(),
            toKey = safeBackStack.getOrNull(safeBackStack.lastIndex - 1)
        )
    }

    NavigationBackHandler(
        state = navigationEventState,
        isBackEnabled = scene.previousEntries.isNotEmpty(),
        onBackCompleted = {
            navigationScope.launch {
                predictiveBackMotion.onBackPressed(
                    transitionState = navigationEventState.transitionState,
                    currentPageKey = safeBackStack.lastOrNull()
                )
                onBack()
            }
        }
    )

    NavDisplay(
        sceneState = sceneState,
        navigationEventState = navigationEventState,
        modifier = modifier,
        contentAlignment = Alignment.TopStart,
        sizeTransform = null,
        transitionSpec = {
            resolveBiliPaiNavContentTransform(BiliPaiNavRouteTransition.FALLBACK)
        },
        popTransitionSpec = {
            with(predictiveBackMotion) {
                onPopTransitionSpec()
            }
        },
        predictivePopTransitionSpec = { swipeEdge ->
            // 预测性返回必须由顶层统一分发，否则普通路由的 entry fallback 会抢走
            // InstallerX 风格 handler，导致手势过程中只能看到淡入淡出。
            resolveBiliPaiNavPredictivePopContentTransform(predictivePopRouteTransition)
                ?: with(predictiveBackMotion) {
                    onPredictivePopTransitionSpec(swipeEdge)
                }
        },
    )

}

@Composable
private fun ProvideNavigation3ViewModelApplicationExtras(
    application: Application,
    content: @Composable () -> Unit
) {
    val navEntryOwner = LocalViewModelStoreOwner.current
    if (navEntryOwner == null) {
        content()
        return
    }

    val patchedOwner = remember(navEntryOwner, application) {
        buildNavigation3ViewModelStoreOwner(navEntryOwner, application)
    }
    CompositionLocalProvider(LocalViewModelStoreOwner provides patchedOwner) {
        content()
    }
}

private fun buildNavigation3ViewModelStoreOwner(
    navEntryOwner: ViewModelStoreOwner,
    application: Application
): ViewModelStoreOwner {
    val defaultFactoryOwner = navEntryOwner as? HasDefaultViewModelProviderFactory
    val defaultCreationExtras = defaultFactoryOwner?.defaultViewModelCreationExtras
        ?: CreationExtras.Empty
    val patchedCreationExtras = MutableCreationExtras(defaultCreationExtras).apply {
        set(ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY, application)
    }

    return object : ViewModelStoreOwner, HasDefaultViewModelProviderFactory {
        override val viewModelStore = navEntryOwner.viewModelStore
        override val defaultViewModelProviderFactory =
            defaultFactoryOwner?.defaultViewModelProviderFactory
                ?: ViewModelProvider.AndroidViewModelFactory.getInstance(application)
        override val defaultViewModelCreationExtras: CreationExtras = patchedCreationExtras
    }
}
