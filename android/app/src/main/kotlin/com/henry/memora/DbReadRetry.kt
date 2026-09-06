package com.henry.memora

import android.database.sqlite.SQLiteDatabaseLockedException
import android.database.sqlite.SQLiteException
import android.util.Log

/**
 * 네이티브(잠금화면·푸시·PDF)의 읽기 전용 DB 접근에 대한 SQLITE_BUSY 재시도.
 *
 * 읽기 전용 핸들에는 enableWriteAheadLogging()이 무효다(AOSP: isReadOnly → false 반환) —
 * 예전 코드의 "WAL 모드: 동시 읽기 허용" 주석이 약속한 보호는 실재하지 않았고, Flutter 쪽
 * 대량 쓰기와 겹치면 잠금 예외가 그대로 빈 결과로 강등됐다(감사 D8-05). 잠금은 짧으니
 * 몇 번 다시 시도한다. 블록 안에서 커서를 끝까지 소비해야 한다(쿼리는 첫 move에서 실행된다).
 */
object DbReadRetry {
    fun <T> run(tag: String, attempts: Int = 4, baseDelayMs: Long = 80, block: () -> T): T {
        var last: SQLiteException? = null
        for (i in 0 until attempts) {
            try {
                return block()
            } catch (e: SQLiteDatabaseLockedException) {
                last = e
            } catch (e: SQLiteException) {
                val m = e.message ?: ""
                if (!m.contains("locked", ignoreCase = true) && !m.contains("busy", ignoreCase = true)) throw e
                last = e
            }
            Log.w(tag, "DB busy, retry ${i + 1}/$attempts")
            try { Thread.sleep(baseDelayMs * (i + 1)) } catch (_: InterruptedException) {}
        }
        throw last ?: IllegalStateException("DbReadRetry: no attempts")
    }
}
