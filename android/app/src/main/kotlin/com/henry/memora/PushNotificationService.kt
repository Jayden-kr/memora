package com.henry.memora

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 푸시 알림 Foreground Service — 시간대 규칙 목록(PushSchedule) 기반.
 * - 앱을 스와이프해서 날려도 살아남음 (START_STICKY)
 * - AlarmManager.setExactAndAllowWhileIdle로 프로세스 사망에도 정확한 간격 알림
 * - SQLite 직접 접근으로 랜덤 카드 조회
 *
 * v1.3.9 재설계: 마스터 활성시간창·전역 폴더·전역 인터벌 개념이 전부 사라졌다.
 * 규칙에 안 걸리는 시각엔 알림이 안 온다(의도적 동작 변경) — [PushSchedule.activeRule]이
 * null이면 그냥 조용히 다음 규칙 시작까지 대기한다.
 */
class PushNotificationService : Service() {
    companion object {
        const val TAG = "PushNotifService"
        const val CHANNEL_ID = "push_notif_service_channel"
        const val SERVICE_NOTIF_ID = 3
        // 카드 알림 ID/requestCode 베이스. cardId를 더해 카드별로 stable한 PendingIntent를 만든다.
        // 100000 베이스로 다른 알림 ID(0,1,3,2001,2002,9001,99999)와 충돌 방지.
        const val CARD_NOTIF_BASE = 100000
        const val REVIEW_CHANNEL_ID = "review_notification_channel"
        const val ACTION_STOP = "STOP"
        const val ACTION_TICK = "TICK"
        const val REQUEST_CODE_TICK = 10000
        const val REQUEST_CODE_RESTART = 9999
        // 활성 규칙이 없을 때(gap) 다음 재평가까지 대기하는 최대 시간. minutesUntilNextStart가
        // 최대 1439를 반환할 수 있으므로, DST/시계 스큐/Doze 오차가 쌓여도 최악의 경우 1시간
        // 안에는 재평가하도록 캡을 씌운다.
        const val MAX_GAP_POLL_MIN = 60
        // 직전 카드 재출현 방지에 기억해 두는 최근 카드 ID 최대 개수.
        const val RECENT_CARD_LIMIT = 5

        // ── 아래 세 함수는 Android API 의존성 0인 순수 로직이라 companion object에
        // 둬서 인스턴스 생성 없이 JVM 유닛테스트가 가능하다(PushNotificationServiceTest.kt).

        /**
         * SharedPreferences의 recentCardIds CSV("id,id,...", 최근이 맨 앞)를 정수 목록으로
         * 파싱. 어떤 입력에도 throw하지 않는다 — 빈 문자열/null/깨진 토큰은 조용히 무시하고,
         * 최대 [RECENT_CARD_LIMIT]개까지만 취한다.
         */
        internal fun parseRecentIds(csv: String?): List<Int> {
            if (csv.isNullOrEmpty()) return emptyList()
            return csv.split(",").mapNotNull { it.trim().toIntOrNull() }.take(RECENT_CARD_LIMIT)
        }

        /** [parseRecentIds]의 역변환. */
        internal fun encodeRecentIds(ids: List<Int>): String = ids.joinToString(",")

        /**
         * 직전 카드 제외 조건을 걸어도 안전한지 판정. [recentSize]개를 전부 제외해도
         * 최소 1건은 남아야 하므로, 안전 조건은 (카드 총 개수 [totalCount]) > (최근 카드
         * 개수 [recentSize]) — 즉 totalCount가 recentSize+1 이상이면 충분하다(그 경우
         * worst-case로도 1건이 남는다). totalCount가 recentSize와 같거나 더 작으면
         * 제외 조건을 걸 경우 0건이 나와 알림이 조용히 끊길 수 있으므로 false(제외
         * 조건 없이 조회)를 반환한다.
         *
         * ⚠️ 1라운드 감사(2026-09-04)에서 발견: 예전엔 `totalCount > recentSize + 1`로
         * 한 단계 더 보수적이었다 — 카드가 정확히 recentSize+1개일 때(예: 최근 5개
         * 기억+카드 6개) 제외해도 1건이 남는데도 가드가 막아, 하필 이 재출현 방지
         * 기능이 막으려던 그 상황(직전 카드가 바로 또 뜸)이 이 경계값에서만 빠져나갔다.
         */
        internal fun shouldExcludeRecentCards(totalCount: Int, recentSize: Int): Boolean =
            recentSize > 0 && totalCount > recentSize
    }

    private var lang = "ko"
    private var rules: List<PushSchedule.Rule> = emptyList()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // createNotificationChannel()이 intent 파싱(onStartCommand)보다 먼저 실행되므로,
        // lang 필드가 기본값(ko)인 채로 채널이 생성되지 않도록 마지막 저장값을 미리 로드한다.
        // main-branch/TICK에서 실제 intent 값으로 다시 갱신됨.
        lang = AppLang.normalize(
            getSharedPreferences("push_notif_prefs", MODE_PRIVATE).getString("lang", null)
        )
        createNotificationChannel()
        Log.d(TAG, "onCreate")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "RECREATE_NOTIFICATION") {
            Log.d(TAG, "상주 알림 재생성")
            val notification = createServiceNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(SERVICE_NOTIF_ID, notification)
            }
            return START_STICKY
        }

        if (intent?.action == AppLang.ACTION_SET_LANG) {
            // 앱 언어 변경 통지. push_notif_prefs는 :push 프로세스만 쓰기 때문에(메인이 쓰면
            // :push가 기록한 스케줄을 되돌릴 위험) 메인이 직접 쓰지 않고 여기로 넘겨준다.
            val running = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                .getBoolean("running", false)
            lang = AppLang.normalize(intent.getStringExtra(AppLang.EXTRA_LANG))
            getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                .edit().putString("lang", lang).commit()
            // 채널 이름은 서비스가 꺼져 있어도 시스템 설정에 남으므로 먼저 갱신한다.
            // (이미 있는 채널만 — 안 쓰던 사용자에게 채널을 새로 만들지 않는다)
            val nm = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                nm?.getNotificationChannel(CHANNEL_ID) != null
            ) {
                createNotificationChannel()
            }
            ensureReviewChannel(nm, force = true)
            if (!running) {
                // 알림이 꺼져 있는데 이 인텐트로 프로세스가 깨어난 경우 — 저장만 하고 종료.
                stopSelf()
                return START_NOT_STICKY
            }
            // 프로세스가 새로 떴을 수 있으므로 시간/간격을 복원한 뒤 알림을 다시 만든다.
            loadSettingsFromPrefs()
            nm?.notify(SERVICE_NOTIF_ID, createServiceNotification())
            return START_STICKY
        }

        if (intent?.action == ACTION_STOP) {
            Log.d(TAG, "STOP 수신 — 서비스 종료")
            // stopService는 startForegroundService(ACTION_STOP)로 호출되므로, 서비스가
            // 미실행 상태였다면 여기서 콜드스타트된다. 그 경우 startForeground를 먼저 호출하지
            // 않으면 ForegroundServiceDidNotStartInTimeException으로 크래시한다(TICK 분기와 동일
            // 이유). 아래에서 곧바로 stopForeground로 제거하므로 알림은 사용자에게 보이지 않는다.
            createNotificationChannel()
            try {
                val notification = createServiceNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                } else {
                    startForeground(SERVICE_NOTIF_ID, notification)
                }
            } catch (e: Exception) {
                Log.e(TAG, "STOP startForeground 실패", e)
            }
            // AlarmManager PendingIntent 취소 (tick + restart)
            cancelTickAlarm()
            cancelRestartAlarm()
            // nextFireTime 정리 (OFF→ON 시 새 타이머 시작을 위해)
            getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
                .edit().remove("nextFireTime").remove("timingKey").commit()
            saveRunning(false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent?.action == ACTION_TICK) {
            Log.d(TAG, "TICK 수신 — 알림 체크")
            // 설정 복원 (프로세스가 재생성됐을 수 있으므로)
            loadSettingsFromPrefs()

            // startForeground 필수: getForegroundService PendingIntent로 시작되므로
            // 프로세스 재생성(cold start) 시 startForeground 미호출 → ForegroundServiceDidNotStartInTimeException 방지
            createNotificationChannel()
            val notification = createServiceNotification()
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                } else {
                    startForeground(SERVICE_NOTIF_ID, notification)
                }
            } catch (e: Exception) {
                Log.e(TAG, "TICK startForeground 실패", e)
                return START_NOT_STICKY
            }

            val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)

            // STOP이 이 TICK 디스패치 직후 처리된 경쟁 상태 대비: AlarmManager.cancel()은 이미
            // 디스패치된 PendingIntent를 회수하지 못한다. STOP은 running=false로 바꾸고
            // nextFireTime을 지우므로, 둘 중 하나라도 tombstone이면 즉시 종료해야 사용자가
            // 방금 끈 알림이 되살아나지 않는다.
            if (!prefs.getBoolean("running", false) || !prefs.contains("nextFireTime")) {
                Log.d(TAG, "TICK — STOP 이후 잔여 알람 감지, 종료")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return START_NOT_STICKY
            }

            saveRunning(true)

            // 현재 시각을 한 번만 계산 → 활성 규칙 판정 → 있으면 그 간격으로, 없으면(gap)
            // 다음 규칙 시작까지(최대 MAX_GAP_POLL_MIN분) 다음 알람 예약.
            val now = nowMinutes()
            val rule = PushSchedule.activeRule(now, rules)
            Log.d(TAG, "Schedule: now=%02d:%02d rules=%d matched=%s".format(
                now / 60, now % 60, rules.size,
                rule?.let { "[${it.start}-${it.end})->folder=${it.folderId},interval=${it.intervalMin}" } ?: "none(gap)"
            ))

            // 다음 알람을 먼저 예약 (프로세스가 발화 도중 죽어도 체인 유지)
            if (rule != null) {
                // 핵심: 예정시각(savedNextFireTime) 기준으로 다음 계산 → 드리프트 누적 방지
                val intervalMs = rule.intervalMin * 60_000L
                val savedFireTime = prefs.getLong("nextFireTime", System.currentTimeMillis())
                var nextFireTime = savedFireTime + intervalMs
                while (nextFireTime <= System.currentTimeMillis()) {
                    nextFireTime += intervalMs
                }
                saveNextFireTime(nextFireTime)
                scheduleNextAlarm(nextFireTime - System.currentTimeMillis())
            } else {
                val gapMin = minOf(PushSchedule.minutesUntilNextStart(now, rules), MAX_GAP_POLL_MIN)
                val nextFireTime = System.currentTimeMillis() + gapMin * 60_000L
                saveNextFireTime(nextFireTime)
                scheduleNextAlarm(nextFireTime - System.currentTimeMillis())
            }

            // 예약 완료 후 발화 (프로세스 사망 시 이번 알림만 유실, 체인은 유지). 규칙이
            // 없으면(gap) 발화하지 않는다 — 이게 이 재설계의 핵심 동작 변경이다.
            if (rule != null) fire(rule)

            return START_STICKY
        }

        // 설정 읽기 (Flutter의 startService 호출, 또는 부팅 복원처럼 extras 없는 콜드스타트)
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        lang = AppLang.normalize(intent?.getStringExtra("lang") ?: prefs.getString("lang", null))

        // 규칙 CSV. hasExtra 패턴 — "전달 안 함=보존" vs "명시적으로 넘김(빈 문자열 포함)"을
        // 구분한다. 프레퍼런스 키 이름은 이전 버전과 동일하게 "scheduleCsv"로 유지한다
        // (§5.3 콜드스타트 폴백이 이 키를 그대로 재사용하기 때문).
        val rulesCsvRaw = if (intent != null && intent.hasExtra("rulesCsv")) {
            intent.getStringExtra("rulesCsv") ?: ""
        } else {
            prefs.getString("scheduleCsv", "") ?: ""
        }
        val hasFreshRulesFromIntent = intent != null && intent.hasExtra("rulesCsv") &&
            !intent.getStringExtra("rulesCsv").isNullOrEmpty()

        rules = PushSchedule.parse(rulesCsvRaw)
        if (rules.isEmpty()) {
            val fallback = legacyFallbackRules(prefs)
            if (fallback.isNotEmpty()) {
                Log.w(TAG, "scheduleCsv 비어있음 — 레거시 prefs(startTotal/endTotal/intervalMin/folderId)로 규칙 폴백")
                rules = fallback
            }
        }

        // ⚠️ canonicalCsv/timingKey는 rulesCsvRaw(마이그레이션 전 상태 그대로) 기준이다 —
        // 위의 레거시 폴백으로 합성된 rules를 여기 반영하지 않는다. loadSettingsFromPrefs()가
        // 매 TICK마다 같은 레거시 prefs로 동일한 폴백을 재현하므로(레거시 키를 지우기 전까진)
        // 실제 발화·표시는 rules 필드가 이미 담당하고, canonicalCsv는 순수하게 "Flutter가
        // 실제로 보낸 값"만 반영해 Flutter가 진짜 새 CSV를 보내는 순간 timingKey가 정확히
        // 갈라지게 한다.
        val canonicalCsv = PushSchedule.encode(PushSchedule.parse(rulesCsvRaw))

        // 타이밍 설정 변경 여부 판별. "v2:" 프리픽스는 업데이트 직후 남아있는 구
        // timingKey("$intervalMin:$startTotal:..." 형식)와 절대 충돌하지 않게 하기 위함 —
        // 프리픽스가 없으면 구 timingKey와 우연히 같은 문자열이 나올 여지가 있어 강제로
        // 다르게 만든다.
        val timingKey = "v2:$canonicalCsv"
        val savedTimingKey = prefs.getString("timingKey", "") ?: ""
        val wasRunning = prefs.getBoolean("running", false)

        val editor = prefs.edit()
            .putString("scheduleCsv", canonicalCsv)
            .putString("timingKey", timingKey)
            .putString("lang", lang)
        if (hasFreshRulesFromIntent) {
            // Flutter가 실제로 비어있지 않은 규칙을 보냈다 — 이제부터는 §5.3 콜드스타트
            // 폴백이 더 이상 필요 없으므로(scheduleCsv가 항상 최신 상태) 레거시 키를 지운다.
            // 한 번 지워지면 폴백은 영구히 비활성화된다(다시 살아나 새 규칙을 덮어쓰지 않음).
            editor.remove("startTotal").remove("endTotal").remove("intervalMin").remove("folderId")
        }
        editor.commit()  // apply() 대신 commit() — 서비스 kill 전 데이터 보존 보장

        Log.d(TAG, "시작: 규칙 ${rules.size}개")

        // Foreground 알림
        val notification = createServiceNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(SERVICE_NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(SERVICE_NOTIF_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startForeground 실패", e)
            return START_NOT_STICKY
        }

        saveRunning(true)

        // 기존 tick 알람 취소
        cancelTickAlarm()

        // 메인 분기도 activeRule(now, rules)을 호출해 delayMs를 계산한다 — 이전 설계의
        // "메인 분기는 슬롯을 조회하지 않는다"는 규율은 v1.3.9에서 의도적으로 뒤집혔다.
        // 규칙 하나뿐이던 전역 인터벌 개념 자체가 사라졌으므로, 지금 활성 규칙이 있는지
        // 없는지에 따라 delayMs가 달라져야 첫 알람이 올바른 시각에 잡힌다.
        val now = nowMinutes()
        val rule = PushSchedule.activeRule(now, rules)
        val delayMs: Long = if (rule != null) {
            rule.intervalMin * 60_000L
        } else {
            minOf(PushSchedule.minutesUntilNextStart(now, rules), MAX_GAP_POLL_MIN) * 60_000L
        }

        if (wasRunning && timingKey == savedTimingKey) {
            // 설정 동일 + 이미 실행 중이었음 → 남은 시간만 대기
            val nextFireTime = prefs.getLong("nextFireTime", 0L)
            val nowMs = System.currentTimeMillis()
            val remaining = nextFireTime - nowMs

            // remaining은 정상적으로 delayMs를 넘을 수 없다. 기기 시계를 과거로 돌리면
            // remaining이 delayMs보다 훨씬 커질 수 있는데(시계 스큐), 그대로 유지하면
            // 시계가 따라잡을 때까지 며칠씩 알림이 멈춘다 — 그런 경우도 새로 리셋한다.
            if (remaining in 1L..delayMs) {
                scheduleNextAlarm(remaining)
                Log.d(TAG, "타이머 유지: ${remaining / 60000}분 ${(remaining % 60000) / 1000}초 남음")
            } else {
                saveNextFireTime(System.currentTimeMillis() + delayMs)
                scheduleNextAlarm(delayMs)
                Log.d(TAG, "타이머 리셋 → ${delayMs / 60000}분 후 다음 알림 예약")
            }
        } else {
            // 새로 시작 or 설정 변경 → 전체 타이머
            saveNextFireTime(System.currentTimeMillis() + delayMs)
            scheduleNextAlarm(delayMs)
            Log.d(TAG, "${delayMs / 60000}분 후 첫 알림 (설정 변경)")
        }

        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "onDestroy")
        super.onDestroy()
    }

    /**
     * getForegroundService()는 API 26+ 전용 — minSdk 24 기기(Android 7.0/7.1)에서 가드 없이
     * 호출하면 NoSuchMethodError(Error, onStartCommand의 catch(Exception)에 안 잡힘)로
     * 프로세스가 죽는다. Pre-O는 getService로 충분(당시 startForeground는
     * startForegroundService 경유를 요구하지 않음). LockScreenService.kt와 동일 패턴 —
     * 이 파일은 호출 지점이 여러 곳이라 헬퍼로 통합.
     */
    private fun foregroundServicePendingIntent(context: Context, reqCode: Int, intent: Intent, flags: Int): PendingIntent {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(context, reqCode, intent, flags)
        } else {
            PendingIntent.getService(context, reqCode, intent, flags)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // running 상태가 아니면 재시작 불필요
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        if (!prefs.getBoolean("running", false)) {
            Log.d(TAG, "onTaskRemoved — running=false, 재시작 예약 안 함")
            return
        }
        Log.d(TAG, "onTaskRemoved — AlarmManager로 서비스 재시작 예약")
        val restartIntent = Intent(applicationContext, PushNotificationService::class.java)
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_RESTART, restartIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        val triggerAt = System.currentTimeMillis() + 3000
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
            if (am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            } else {
                am.setAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            }
        } else {
            am?.setExactAndAllowWhileIdle(
                android.app.AlarmManager.RTC_WAKEUP,
                triggerAt,
                pi
            )
        }
    }

    /**
     * AlarmManager를 사용하여 delayMs 후 ACTION_TICK Intent를 예약
     */
    private fun scheduleNextAlarm(delayMs: Long) {
        val tickIntent = Intent(applicationContext, PushNotificationService::class.java).apply {
            action = ACTION_TICK
        }
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_TICK, tickIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        val triggerAt = System.currentTimeMillis() + delayMs
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
            if (am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            } else {
                am.setAndAllowWhileIdle(
                    android.app.AlarmManager.RTC_WAKEUP,
                    triggerAt,
                    pi
                )
            }
        } else {
            am?.setExactAndAllowWhileIdle(
                android.app.AlarmManager.RTC_WAKEUP,
                triggerAt,
                pi
            )
        }
        Log.d(TAG, "다음 알람 예약: ${delayMs / 60000}분 ${(delayMs % 60000) / 1000}초 후")
    }

    /**
     * Tick 알람 PendingIntent 취소
     */
    private fun cancelTickAlarm() {
        val tickIntent = Intent(applicationContext, PushNotificationService::class.java).apply {
            action = ACTION_TICK
        }
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_TICK, tickIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        am?.cancel(pi)
    }

    /**
     * Restart 알람 PendingIntent 취소
     */
    private fun cancelRestartAlarm() {
        val restartIntent = Intent(applicationContext, PushNotificationService::class.java)
        val pi = foregroundServicePendingIntent(
            applicationContext, REQUEST_CODE_RESTART, restartIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        am?.cancel(pi)
    }

    /**
     * §5.3 콜드스타트 갭 폴백: scheduleCsv가 비어 있고(아직 Flutter 마이그레이션이 돌지
     * 않은 상태) 레거시 단일 인터벌 알람 prefs(startTotal/endTotal/intervalMin/folderId
     * — v1.3.8 이전부터 있던 키)가 남아있으면 그 값으로 규칙 1개를 합성한다. 부팅
     * 리시버(LockScreenStartReceiver.restorePushNotificationService)가 extras 없이
     * 이 서비스를 띄우는 경로에서, Flutter가 아직 한 번도 열리지 않아 push_rules
     * 마이그레이션이 돌지 않았다면 이 폴백이 없으면 규칙 0개 → 영구 무음이 된다.
     */
    private fun legacyFallbackRules(prefs: SharedPreferences): List<PushSchedule.Rule> {
        if (!prefs.contains("startTotal") || !prefs.contains("endTotal")) return emptyList()
        val s = prefs.getInt("startTotal", 540)
        val e = prefs.getInt("endTotal", 1320)
        if (s == e) return emptyList()
        val folderId = prefs.getInt("folderId", -1)
        val intervalMin = maxOf(5, prefs.getInt("intervalMin", 30))
        return listOf(PushSchedule.Rule(s, e, folderId, intervalMin))
    }

    /**
     * SharedPreferences에서 설정값 복원 (TICK/ACTION_SET_LANG에서 프로세스 재생성 시 사용)
     */
    private fun loadSettingsFromPrefs() {
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        lang = prefs.getString("lang", "ko") ?: "ko"
        rules = PushSchedule.parse(prefs.getString("scheduleCsv", null))
        if (rules.isEmpty()) {
            val fallback = legacyFallbackRules(prefs)
            if (fallback.isNotEmpty()) rules = fallback
        }
    }

    /** 자정 기준 경과 분(0~1439). minSdk 24라 java.time 대신 Calendar 사용. */
    private fun nowMinutes(): Int {
        val cal = java.util.Calendar.getInstance()
        return cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
    }

    /** 활성 규칙 하나를 발화. 규칙의 folderId==ALL_FOLDERS(-1)면 전체 폴더(null 필터). */
    private fun fire(rule: PushSchedule.Rule) {
        Log.d(TAG, "알림 발사! (folder=${rule.folderId}, interval=${rule.intervalMin})")
        val targetFolderId = if (rule.folderId == PushSchedule.ALL_FOLDERS) null else rule.folderId
        // DB I/O를 백그라운드 스레드에서 실행 (ANR 방지)
        Thread {
            try {
                showCardNotification(targetFolderId)
            } catch (e: Exception) {
                Log.e(TAG, "showCardNotification 실패", e)
            }
        }.start()
    }

    /** cards 테이블에서 [folderIdFilter](null이면 전체)로 필터링한 카드 총 개수. */
    private fun countCards(db: SQLiteDatabase, folderIdFilter: Int?): Int {
        val where = if (folderIdFilter != null) "folder_id = ?" else null
        val args = if (folderIdFilter != null) arrayOf(folderIdFilter.toString()) else null
        val cursor = db.query("cards", arrayOf("COUNT(*) AS cnt"), where, args, null, null, null)
        cursor.use {
            if (it.moveToFirst()) return it.getInt(it.getColumnIndexOrThrow("cnt"))
        }
        return 0
    }

    /**
     * cards 테이블에서 [folderIdFilter](null이면 전체)로 필터링한 랜덤 카드 1건을 조회.
     * [recentCardIds]에 담긴 카드는 가능하면 제외해 직전에 뜬 카드가 바로 다음에 또
     * 뜨지 않게 한다 — 단, 대상 범위의 카드 총 개수가 (recentCardIds 크기 + 1) 이하면
     * 제외 조건 없이 조회한다(그렇지 않으면 0건이 나와 알림이 조용히 끊긴다).
     * 반환: Triple(cardId, cardFolderId, question) — cardId<=0이면 조회 실패(0건).
     */
    private fun queryRandomCard(
        db: SQLiteDatabase,
        folderIdFilter: Int?,
        recentCardIds: List<Int> = emptyList()
    ): Triple<Int, Int, String> {
        val totalCount = countCards(db, folderIdFilter)
        val applyExclusion = shouldExcludeRecentCards(totalCount, recentCardIds.size)

        val whereClauses = mutableListOf<String>()
        val args = mutableListOf<String>()
        if (folderIdFilter != null) {
            whereClauses.add("folder_id = ?")
            args.add(folderIdFilter.toString())
        }
        if (applyExclusion) {
            val placeholders = recentCardIds.joinToString(",") { "?" }
            whereClauses.add("id NOT IN ($placeholders)")
            args.addAll(recentCardIds.map { it.toString() })
        }
        val where = if (whereClauses.isNotEmpty()) whereClauses.joinToString(" AND ") else null
        val whereArgs = if (args.isNotEmpty()) args.toTypedArray() else null

        val cursor = db.query("cards", arrayOf("id", "folder_id", "question"),
            where, whereArgs, null, null, "RANDOM()", "1")
        cursor.use {
            if (it.moveToFirst()) {
                val q = it.getString(it.getColumnIndexOrThrow("question"))
                val cardId = it.getInt(it.getColumnIndexOrThrow("id"))
                val cardFolderId = it.getInt(it.getColumnIndexOrThrow("folder_id"))
                return Triple(cardId, cardFolderId, if (!q.isNullOrEmpty()) q else "")
            }
        }
        return Triple(-1, -1, "")
    }

    private fun showCardNotification(targetFolderId: Int?) {
        val dbFile = findDbFile() ?: return
        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            try { db.enableWriteAheadLogging() } catch (_: Exception) {} // WAL 모드: Flutter sqflite와 동시 읽기 허용 (별도 :push 프로세스)

            // 직전에 뜬 카드 재출현 방지용 최근 카드 ID 목록. push_notif_prefs는
            // :push 프로세스(이 서비스)만 읽고 쓴다.
            val pushPrefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            val recentCardIds = parseRecentIds(pushPrefs.getString("recentCardIds", null))

            // 랜덤 카드 조회 (규칙이 지정한 폴더 우선, 직전 카드들 제외)
            var (cardId, cardFolderId, question) = queryRandomCard(db, targetFolderId, recentCardIds)

            // 카드 0건 폴백: 규칙이 가리키는 폴더가 삭제되었거나 카드가 비어 있으면
            // 전체 폴더로 1회 재조회 — 규칙 폴더가 무효해졌다고 알림 자체가 조용히
            // 끊기지 않게 한다. targetFolderId가 이미 null(전체 폴더)이면 재조회해도
            // 결과가 같으므로 스킵.
            if (cardId <= 0 && targetFolderId != null) {
                Log.w(TAG, "규칙 폴더($targetFolderId) 카드 없음, 전체 폴더로 재조회")
                val fallback = queryRandomCard(db, null, recentCardIds)
                cardId = fallback.first
                cardFolderId = fallback.second
                question = fallback.third
            }

            // 카드 조회 실패 시 알림 자체를 건너뜀.
            // payload 없이 알림을 띄우면 탭해도 네비게이션이 안 되므로 무의미.
            if (cardId <= 0) {
                Log.w(TAG, "랜덤 카드 조회 실패, 알림 스킵")
                return
            }
            if (question.isEmpty()) {
                question = AppLang.wrap(this, lang).getString(R.string.push_review_default_body)
            }

            // notifId = requestCode = CARD_NOTIF_BASE + cardId
            // 카드별로 stable한 PendingIntent — 같은 카드가 또 뽑혀도 자기자신만 교체하므로
            // 본문/payload가 항상 일치한다. 다른 카드끼리는 ID가 달라 PI extras 누수 불가능.
            val notifId = CARD_NOTIF_BASE + cardId
            val payload = "$cardFolderId:$cardId"

            val nm = getSystemService(NotificationManager::class.java)
            ensureReviewChannel(nm)

            // Android 13+: POST_NOTIFICATIONS 권한 확인.
            // PendingIntent 생성을 이 체크 이후로 미뤄야 권한 거부 시 기존 PI extras 누수 방지.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                    Log.w(TAG, "POST_NOTIFICATIONS 권한 없음, 알림 스킵")
                    return
                }
            }

            // 알림 탭 → 해당 카드로 이동하는 Intent (권한 통과 후 PI 생성)
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra("notification_payload", payload)
            }
            val pi = PendingIntent.getActivity(this, notifId, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

            val builder = NotificationCompat.Builder(this, REVIEW_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentText(question)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)

            nm?.notify(notifId, builder.build())
            Log.d(TAG, "알림 표시 완료: cardId=$cardId, payload=$payload, body=$question")

            // 발화 성공 후 recentCardIds 갱신: 새 카드를 맨 앞에 추가, 5개 초과분은 버림.
            // 이 prefs는 :push 프로세스(이 서비스 자신)만 읽고 쓴다.
            val updatedRecent = (listOf(cardId) + recentCardIds.filter { it != cardId })
                .take(RECENT_CARD_LIMIT)
            pushPrefs.edit().putString("recentCardIds", encodeRecentIds(updatedRecent)).apply()
        } catch (e: Exception) {
            Log.e(TAG, "알림 표시 실패", e)
        } finally {
            db?.close()
        }
    }

    private fun findDbFile(): java.io.File? {
        val dataDir = applicationInfo.dataDir
        // getDatabasePath를 우선 시도 (공식 API)
        val candidates = listOf(
            getDatabasePath("memora.db"),
            java.io.File(dataDir, "app_flutter/memora.db"),
            java.io.File(filesDir, "app_flutter/memora.db"),
            java.io.File(filesDir, "memora.db"),
        )
        for (candidate in candidates) {
            if (candidate.exists() && candidate.canRead()) return candidate
        }
        Log.w(TAG, "DB 파일을 찾을 수 없음. 검색 경로: ${candidates.map { it.path }}")
        return null
    }

    /**
     * 복습 알림 채널 보장. [REVIEW_CHANNEL_ID]는 원래 Flutter 플러그인이 만들지만,
     * 없으면 알림이 아예 안 뜨므로 여기서도 fallback으로 만든다.
     * [force]면 이미 있어도 다시 만들어 이름/설명을 현재 언어로 갱신한다
     * (같은 ID 재생성은 비파괴적 — 사용자가 조정한 중요도·소리는 유지된다).
     */
    private fun ensureReviewChannel(nm: NotificationManager?, force: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || nm == null) return
        val exists = nm.getNotificationChannel(REVIEW_CHANNEL_ID) != null
        if (if (force) !exists else exists) return
        val res = AppLang.wrap(this, lang)
        nm.createNotificationChannel(
            NotificationChannel(
                REVIEW_CHANNEL_ID,
                res.getString(R.string.push_review_channel_name),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = res.getString(R.string.push_review_channel_desc)
                enableVibration(true)
            }
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val res = AppLang.wrap(this, lang)
            val channel = NotificationChannel(
                CHANNEL_ID,
                res.getString(R.string.push_service_channel_name),
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = res.getString(R.string.push_service_channel_desc)
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(channel)
        }
    }

    private fun fmtClock(totalMinutes: Int): String {
        val h = totalMinutes / 60
        val m = totalMinutes % 60
        return String.format(java.util.Locale.US, "%02d:%02d", h, m)
    }

    private fun createServiceNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("navigate_to", "push_notification_settings")
        }
        val pi = PendingIntent.getActivity(this, 2, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        // 상주 알림에 보여줄 문구는 지금 이 순간의 실제 상태를 반영한다: 활성 규칙이
        // 있으면 그 시간대/간격을, 없으면(gap) 다음 규칙이 언제 시작하는지를, 규칙
        // 자체가 없으면(스위치는 켜져 있는데 아직 규칙을 못 만든 극단적 상태) 일시중지를.
        val now = nowMinutes()
        val rule = PushSchedule.activeRule(now, rules)
        val res = AppLang.wrap(this, lang)
        val contentText = if (rule != null) {
            val rangeText = "${fmtClock(rule.start)}~${fmtClock(rule.end)}"
            res.getString(R.string.push_service_text_active, rangeText, rule.intervalMin)
        } else if (rules.isNotEmpty()) {
            val nextStartMin = (now + PushSchedule.minutesUntilNextStart(now, rules)) % 1440
            res.getString(R.string.push_service_text_idle, fmtClock(nextStartMin))
        } else {
            res.getString(R.string.push_service_text_paused)
        }

        // 상주 알림이 스와이프로 제거되면 서비스가 다시 알림을 생성
        val recreateIntent = Intent(this, PushNotificationService::class.java).apply {
            action = "RECREATE_NOTIFICATION"
        }
        val deletePi = foregroundServicePendingIntent(
            this, 200, recreateIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Memora")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pi)
            .setDeleteIntent(deletePi)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun saveNextFireTime(time: Long) {
        getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            .edit().putLong("nextFireTime", time).commit()
    }

    private fun saveRunning(running: Boolean) {
        getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            .edit().putBoolean("running", running).commit()
    }
}
