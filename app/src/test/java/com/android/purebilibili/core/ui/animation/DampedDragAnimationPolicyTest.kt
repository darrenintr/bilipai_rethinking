package com.android.purebilibili.core.ui.animation

import com.android.purebilibili.core.ui.motion.resolveBottomBarMotionSpec
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DampedDragAnimationPolicyTest {

    @Test
    fun `release target caps fast fling to configured step count`() {
        val motionSpec = resolveBottomBarMotionSpec()

        val target = resolveDampedDragReleaseTargetIndex(
            currentValue = 2.1f,
            velocityPxPerSecond = 6400f,
            itemWidthPx = 80f,
            itemCount = 6,
            motionSpec = motionSpec
        )

        assertEquals(3, target)
    }

    @Test
    fun `release target clamps overscroll to bounds`() {
        val motionSpec = resolveBottomBarMotionSpec()

        val startTarget = resolveDampedDragReleaseTargetIndex(
            currentValue = -0.42f,
            velocityPxPerSecond = -2800f,
            itemWidthPx = 72f,
            itemCount = 5,
            motionSpec = motionSpec
        )
        val endTarget = resolveDampedDragReleaseTargetIndex(
            currentValue = 4.42f,
            velocityPxPerSecond = 2800f,
            itemWidthPx = 72f,
            itemCount = 5,
            motionSpec = motionSpec
        )

        assertEquals(0, startTarget)
        assertEquals(4, endTarget)
    }

    @Test
    fun `velocity conversion guards invalid item width`() {
        assertEquals(
            0f,
            resolveDampedDragVelocityItemsPerSecond(
                velocityPxPerSecond = 1200f,
                itemWidthPx = 0f
            )
        )
    }

    @Test
    fun `drag position snaps immediately while glass offset uses damped spring`() {
        val source = listOf(
            File("app/src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt"),
            File("src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt")
        ).first { it.exists() }.readText()
        val dragSource = source
            .substringAfter("fun onDrag(")
            .substringBefore("fun setPressed(pressed: Boolean)")
        val releaseSource = source
            .substringAfter("fun onDragEnd(")
            .substringBefore("fun updateIndex(index: Int)")

        // 指示器位置必须即时更新,否则底栏/首页指示器会像失去滑动能力。
        // 玻璃偏移单独走阻尼弹簧,只过滤折射采样抖动。
        assertTrue(source.contains("private val dragFollowSpring = spring<Float>("))
        assertTrue(dragSource.contains("animatable.snapTo(newValue)"))
        assertTrue(dragSource.contains("offsetAnimation.animateTo(desiredDragOffsetPx, dragFollowSpring)"))
        assertFalse(dragSource.contains("animatable.animateTo(newValue, dragFollowSpring)"))
        assertTrue(dragSource.contains("dragVelocityItemsPerSecond = resolveDampedDragVelocityItemsPerSecond("))
        assertTrue(releaseSource.contains("animatable.animateTo("))
        assertTrue(releaseSource.contains("offsetAnimation.animateTo(0f"))
    }

    @Test
    fun `drag velocity is spring filtered for indicator deformation`() {
        val source = listOf(
            File("app/src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt"),
            File("src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt")
        ).first { it.exists() }.readText()

        assertTrue(source.contains("private val deformationVelocitySpring = spring<Float>("))
        assertTrue(source.contains("val deformationVelocityItemsPerSecond: Float get() = deformationVelocityAnimation.value"))
        assertTrue(source.contains("deformationVelocityAnimation.animateTo("))
        assertTrue(source.contains("targetValue = dragVelocityItemsPerSecond"))
        assertTrue(source.contains("val velocity = velocityTracker.calculateVelocity()"))
        assertTrue(source.contains("dragState.onDrag(dragAmount, itemWidthPx, velocity.x)"))
        assertFalse(source.contains("get() = if (isDragging) dragVelocityItemsPerSecond else velocity"))
    }

    @Test
    fun `settle pulse counters distinguish drag release and click selection`() {
        val source = listOf(
            File("app/src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt"),
            File("src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt")
        ).first { it.exists() }.readText()
        val releaseSource = source
            .substringAfter("fun onDragEnd(")
            .substringBefore("fun updateIndex(index: Int)")
        val updateIndexSource = source
            .substringAfter("fun updateIndex(index: Int)")
            .substringBefore("}\n}\n\n/**\n * 创建并记住阻尼拖拽动画状态")

        assertTrue(source.contains("var settledReleaseCount by mutableIntStateOf(0)"))
        assertTrue(source.contains("var settledSelectionCount by mutableIntStateOf(0)"))
        assertTrue(releaseSource.contains("settledReleaseCount += 1"))
        assertFalse(updateIndexSource.contains("settledReleaseCount += 1"))
        assertTrue(updateIndexSource.contains("settledSelectionCount += 1"))
        assertFalse(releaseSource.contains("settledSelectionCount += 1"))
    }

    @Test
    fun `click index update keeps press progress until target settles`() {
        val source = listOf(
            File("app/src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt"),
            File("src/main/java/com/android/purebilibili/core/ui/animation/DampedDragAnimation.kt")
        ).first { it.exists() }.readText()
        val updateIndexSource = source
            .substringAfter("fun updateIndex(index: Int)")
            .substringBefore("}\n}\n\n/**\n * 创建并记住阻尼拖拽动画状态")

        assertTrue(updateIndexSource.contains("pressProgressAnimation.animateTo(1f"))
        assertTrue(updateIndexSource.contains("animatable.animateTo("))
        assertTrue(updateIndexSource.contains("pressProgressAnimation.animateTo(0f"))
        assertTrue(updateIndexSource.indexOf("pressProgressAnimation.animateTo(1f") <
            updateIndexSource.indexOf("animatable.animateTo("))
        assertTrue(updateIndexSource.indexOf("animatable.animateTo(") <
            updateIndexSource.indexOf("pressProgressAnimation.animateTo(0f"))
    }
}
