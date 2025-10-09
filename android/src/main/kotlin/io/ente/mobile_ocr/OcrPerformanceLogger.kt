package io.ente.mobile_ocr

import android.os.SystemClock
import android.util.Log
import java.util.Locale

object OcrPerformanceLogger {
    private const val TAG = "OnnxOcrPerf"

    fun <T> trace(section: String, block: () -> T): T {
        val start = SystemClock.elapsedRealtimeNanos()
        return try {
            block()
        } finally {
            val durationMs = (SystemClock.elapsedRealtimeNanos() - start) / 1_000_000.0
            Log.i(TAG, "$section took ${formatDuration(durationMs)}")
        }
    }

    fun logStage(section: String, durationNanos: Long) {
        val durationMs = durationNanos / 1_000_000.0
        Log.i(TAG, "$section took ${formatDuration(durationMs)}")
    }

    fun log(message: String) {
        Log.i(TAG, message)
    }

    private fun formatDuration(durationMs: Double): String {
        return String.format(Locale.US, "%.2f ms", durationMs)
    }
}
