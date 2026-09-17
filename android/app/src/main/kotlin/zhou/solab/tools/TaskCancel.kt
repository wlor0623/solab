package zhou.solab.tools

import java.util.concurrent.CancellationException

/**
 * 全局任务取消令牌：AI 对话停止 / 显式 cancelTask 时置位，
 * 长任务（DEX 分析、SO 分析、jadx 等）在检查点抛 CancellationException，
 * 由通道层转为 TASK_CANCELLED 结构化错误。
 * 每个新任务开始时 reset()。
 */
object TaskCancel {
    @Volatile
    private var cancelled = false

    fun reset() {
        cancelled = false
    }

    fun cancel() {
        cancelled = true
    }

    val isCancelled: Boolean get() = cancelled

    /** 检查点：已取消则抛 CancellationException。 */
    fun check() {
        if (cancelled) throw CancellationException("task cancelled")
    }
}
