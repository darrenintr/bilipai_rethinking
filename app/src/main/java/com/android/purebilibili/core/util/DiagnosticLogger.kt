package com.android.purebilibili.core.util

import android.content.Context
import java.text.SimpleDateFormat
import java.util.*

/**
 * 诊断日志工具类 - 用于追踪特定的复杂问题
 * 
 * 覆盖范围：
 * 1. 推荐算法归因 (为什么登录了还是公共推荐)
 * 2. 播放状态追踪 (为什么 Loading 圈不消失)
 * 3. 全屏状态追踪 (为什么切换全屏黑屏)
 */
object DiagnosticLogger {

    private val dateFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault())
    private val events = mutableListOf<DiagnosticEvent>()
    private const val MAX_EVENTS = 500

    data class DiagnosticEvent(
        val timestamp: Long,
        val category: Category,
        val message: String,
        val details: Map<String, Any?> = emptyMap()
    ) {
        fun format(): String {
            val time = SimpleDateFormat("HH:mm:ss.SSS", Locale.getDefault()).format(Date(timestamp))
            return "[$time] [${category.name}] $message ${if (details.isNotEmpty()) details.toString() else ""}"
        }
    }

    enum class Category {
        RECOMMENDATION,
        PLAYBACK,
        FULLSCREEN,
        NETWORK,
        AUTH
    }

    @Synchronized
    fun log(category: Category, message: String, details: Map<String, Any?> = emptyMap()) {
        val event = DiagnosticEvent(System.currentTimeMillis(), category, message, details)
        events.add(event)
        if (events.size > MAX_EVENTS) {
            events.removeAt(0)
        }
        
        // 同时输出到普通日志，方便在普通日志里看到上下文
        Logger.i("DIAG/${category.name}", "$message $details")
    }

    @Synchronized
    fun getDiagnosticReport(): String {
        return buildString {
            appendLine("========================================")
            appendLine("BiliPai 深度诊断报告")
            appendLine("生成时间: ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date())}")
            appendLine("========================================")
            appendLine()
            events.forEach { appendLine(it.format()) }
            appendLine()
            appendLine("========================================")
            appendLine("END OF REPORT")
            appendLine("========================================")
        }
    }

    fun exportReport(context: Context): String? {
        val report = getDiagnosticReport()
        return Logger.exportPlayerDiagnostic(context, report)
    }

    // --- Helper methods for specific issues ---

    fun logRecommendFlow(message: String, details: Map<String, Any?> = emptyMap()) {
        log(Category.RECOMMENDATION, message, details)
    }

    fun logPlaybackState(message: String, details: Map<String, Any?> = emptyMap()) {
        log(Category.PLAYBACK, message, details)
    }

    fun logFullscreenTransition(message: String, details: Map<String, Any?> = emptyMap()) {
        log(Category.FULLSCREEN, message, details)
    }
}
