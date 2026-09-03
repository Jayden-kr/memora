package com.henry.memora

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 간격 반복 푸시 알림 Foreground Service
 * - 앱을 스와이프해서 날려도 살아남음 (START_STICKY)
 * - AlarmManager.setExactAndAllowWhileIdle로 프로세스 사망에도 정확한 간격 알림
 * - SQLite 직접 접근으로 랜덤 카드 조회
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
    }

    private var intervalMin = 30
    private var startTotal = 540   // 09:00
    private var endTotal = 1320    // 22:00
    private var folderId: Int? = null
    private var soundEnabled = true
    private var lang = "ko"
    // 시간대별 폴더·주기 자동 전환(PushSchedule.kt). OFF면 slots는 항상 emptyList —
    // "켜졌는데 슬롯 0개"라는 모호함을 만들지 않는다(LockScreenService와 동일 규율).
    private var scheduleEnabled = false
    private var slots: List<PushSchedule.Slot> = emptyList()

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

            // 현재 시각을 한 번만 계산 → 활성 슬롯(폴더+간격 오버라이드) 판정 → 그 간격으로
            // 다음 알람 예약. 슬롯 전환은 "지연 수용" 설계다: 폴더는 이번 TICK에서 바로
            // 반영되지만(fireIfInRange가 이 slot 그대로 발화), 간격은 "다음" 예약부터만
            // 반영된다 — 드리프트 방지 while 루프가 몇 TICK 안에 새 간격으로 자연히
            // 수렴하므로 경계 전용 정확 알람은 의도적으로 추가하지 않는다.
            val now = nowMinutes()
            val slot = activeSlotNow(now)
            Log.d(TAG, "Schedule: now=%02d:%02d slots=%d matched=%s effInterval=%d effFolder=%s".format(
                now / 60, now % 60, slots.size,
                slot?.let { "[${it.start}-${it.end})->folder=${it.folderId},interval=${it.intervalMin}" } ?: "none",
                effectiveIntervalMin(slot),
                effectiveFolderId(slot)?.toString() ?: "all"
            ))

            // 다음 알람을 먼저 예약 (프로세스가 fireIfInRange 도중 죽어도 체인 유지)
            // 핵심: 예정시각(savedNextFireTime) 기준으로 다음 계산 → 드리프트 누적 방지
            val intervalMs = effectiveIntervalMin(slot) * 60 * 1000L
            val savedFireTime = prefs.getLong("nextFireTime", System.currentTimeMillis())
            var nextFireTime = savedFireTime + intervalMs
            // 만약 nextFireTime이 이미 과거면 → 다음 슬롯까지 건너뛰기
            while (nextFireTime <= System.currentTimeMillis()) {
                nextFireTime += intervalMs
            }
            saveNextFireTime(nextFireTime)
            scheduleNextAlarm(nextFireTime - System.currentTimeMillis())

            // 예약 완료 후 발화 (프로세스 사망 시 이번 알림만 유실, 체인은 유지)
            fireIfInRange(now, slot)

            return START_STICKY
        }

        // 설정 읽기
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        intervalMin = maxOf(5, intent?.getIntExtra("intervalMin", prefs.getInt("intervalMin", 30)) ?: prefs.getInt("intervalMin", 30))
        startTotal = intent?.getIntExtra("startTotal", prefs.getInt("startTotal", 540)) ?: prefs.getInt("startTotal", 540)
        endTotal = intent?.getIntExtra("endTotal", prefs.getInt("endTotal", 1320)) ?: prefs.getInt("endTotal", 1320)
        // -1은 '전체 폴더'를 의미한다. 예전 코드는 intent의 -1을 .let으로 null로 바꾼 뒤
        // 엘비스(?:)가 그 null을 '값 없음'으로 오해해 prefs의 이전 폴더로 폴백했다 → '특정 폴더
        // → 전체 폴더' 전환이 무시되고 이전 필터가 영구 고착됐다(#2). intent가 folderId를
        // 명시적으로 넘겼는지를 hasExtra로 판별해, 넘겼으면 prefs 폴백 없이 그 값(-1→null=전체)을 쓴다.
        folderId = if (intent != null && intent.hasExtra("folderId")) {
            intent.getIntExtra("folderId", -1).let { if (it == -1) null else it }
        } else {
            prefs.getInt("folderId", -1).let { if (it == -1) null else it }
        }
        soundEnabled = intent?.getBooleanExtra("soundEnabled", prefs.getBoolean("soundEnabled", true))
            ?: prefs.getBoolean("soundEnabled", true)
        lang = AppLang.normalize(intent?.getStringExtra("lang") ?: prefs.getString("lang", null))

        // 시간대별 스케줄. folderId와 같은 hasExtra 패턴 — "전달 안 함=보존" vs
        // "명시적으로 넘김(켜짐/꺼짐, CSV)"을 구분한다. MainActivity가 scheduleEnabled/
        // scheduleCsv를 ?.let으로 조건부 전달하므로(신규 키 보존 규율), 여기서도 값이
        // 없으면 prefs의 기존 값을 그대로 쓴다.
        scheduleEnabled = if (intent != null && intent.hasExtra("scheduleEnabled")) {
            intent.getBooleanExtra("scheduleEnabled", false)
        } else {
            prefs.getBoolean("scheduleEnabled", false)
        }
        val scheduleCsvRaw = if (intent != null && intent.hasExtra("scheduleCsv")) {
            intent.getStringExtra("scheduleCsv") ?: ""
        } else {
            prefs.getString("scheduleCsv", "") ?: ""
        }
        // OFF면 파싱조차 하지 않는다 — "켜졌는데 슬롯 0개"의 모호함 제거(LockScreenService와 동일 규율).
        slots = if (scheduleEnabled) PushSchedule.parse(scheduleCsvRaw) else emptyList()
        // prefs에는 정규화된 CSV를 저장 — 공백/순서 차이가 timingKey를 불필요하게 리셋하지
        // 않게 하고, scheduleEnabled가 꺼져 있어도 유효한 슬롯 데이터를 보존해 다시 켜면
        // 그대로 복원되게 한다.
        val canonicalCsv = PushSchedule.encode(PushSchedule.parse(scheduleCsvRaw))

        // 타이밍 설정 변경 여부 판별 (폴더/알림음은 타이밍과 무관).
        // ⚠️ scheduleEnabled/스케줄 CSV를 반드시 포함해야 한다 — 안 그러면 슬롯만
        // 편집해서 저장해도 "타이밍 변경 없음"으로 오판돼 실행 중이던 타이머가 새
        // 스케줄을 영영 반영하지 못한다.
        val timingKey = "$intervalMin:$startTotal:$endTotal:${if (scheduleEnabled) 1 else 0}:$canonicalCsv"
        val savedTimingKey = prefs.getString("timingKey", "") ?: ""
        val wasRunning = prefs.getBoolean("running", false)

        // 설정 저장 (재시작 시 복원용)
        prefs.edit()
            .putInt("intervalMin", intervalMin)
            .putInt("startTotal", startTotal)
            .putInt("endTotal", endTotal)
            .putInt("folderId", folderId ?: -1)
            .putBoolean("soundEnabled", soundEnabled)
            .putBoolean("scheduleEnabled", scheduleEnabled)
            .putString("scheduleCsv", canonicalCsv)
            .putString("timingKey", timingKey)
            .putString("lang", lang)
            .commit()  // apply() 대신 commit() — 서비스 kill 전 데이터 보존 보장

        Log.d(TAG, "시작: ${startTotal/60}:${String.format(java.util.Locale.US, "%02d", startTotal%60)}~${endTotal/60}:${String.format(java.util.Locale.US, "%02d", endTotal%60)}, ${intervalMin}분 간격")

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

        if (wasRunning && timingKey == savedTimingKey) {
            // 설정 동일 + 이미 실행 중이었음 → 남은 시간만 대기
            val nextFireTime = prefs.getLong("nextFireTime", 0L)
            val now = System.currentTimeMillis()
            val remaining = nextFireTime - now
            val intervalMs = intervalMin * 60 * 1000L

            // interval 알람이므로 remaining은 정상적으로 intervalMs를 넘을 수 없다. 기기
            // 시계를 과거로 돌리면 remaining이 intervalMs보다 훨씬 커질 수 있는데(시계 스큐),
            // 그대로 유지하면 시계가 따라잡을 때까지 며칠씩 알림이 멈춘다 — 그런 경우도
            // 새 interval로 리셋한다.
            if (remaining in 1L..intervalMs) {
                scheduleNextAlarm(remaining)
                Log.d(TAG, "타이머 유지: ${remaining / 60000}분 ${(remaining % 60000) / 1000}초 남음")
            } else {
                // 이전 예약 시간이 이미 지났거나(remaining<=0) 시계 스큐로 비정상적으로 먼
                // 미래임(remaining>intervalMs) → 새 interval 시작 (즉시 발화 X)
                // 알림은 TICK 알람만 발사해야 함. 앱 열기 = 알림 트리거 아님.
                saveNextFireTime(System.currentTimeMillis() + intervalMs)
                scheduleNextAlarm(intervalMs)
                Log.d(TAG, "타이머 리셋 → ${intervalMin}분 후 다음 알림 예약")
            }
        } else {
            // 새로 시작 or 설정 변경 → 전체 interval 타이머
            val delayMs = intervalMin * 60 * 1000L
            saveNextFireTime(System.currentTimeMillis() + delayMs)
            scheduleNextAlarm(delayMs)
            Log.d(TAG, "${intervalMin}분 후 첫 알림 (설정 변경, start=$startTotal, end=$endTotal)")
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
     * SharedPreferences에서 설정값 복원 (TICK 액션에서 프로세스 재생성 시 사용)
     */
    private fun loadSettingsFromPrefs() {
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        intervalMin = maxOf(5, prefs.getInt("intervalMin", 30))
        startTotal = prefs.getInt("startTotal", 540)
        endTotal = prefs.getInt("endTotal", 1320)
        folderId = prefs.getInt("folderId", -1).let { if (it == -1) null else it }
        soundEnabled = prefs.getBoolean("soundEnabled", true)
        lang = prefs.getString("lang", "ko") ?: "ko"
        scheduleEnabled = prefs.getBoolean("scheduleEnabled", false)
        slots = if (scheduleEnabled) PushSchedule.parse(prefs.getString("scheduleCsv", null)) else emptyList()
    }

    /** 자정 기준 경과 분(0~1439). minSdk 24라 java.time 대신 Calendar 사용. */
    private fun nowMinutes(): Int {
        val cal = java.util.Calendar.getInstance()
        return cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
    }

    /**
     * 마스터 활성시간창(양끝 포함, overnight 지원) 판정. fireIfInRange()가 원래 인라인으로
     * 하던 계산을 순수 추출만 한 것 — 의미(양끝 포함)는 절대 바꾸지 않는다. 반열림으로
     * "통일"하지 말 것: PushSchedule.Slot 쪽 판정(FolderSchedule.slotContains)은
     * 하루를 여러 슬롯으로 분할하므로 반열림이 맞고, 여긴 "쏠지 말지"를 정하는 단일
     * 범위라 경계 포함이 자연스럽다 — 둘 다 각자 맥락에서 옳다.
     */
    private fun inMasterWindow(now: Int): Boolean {
        return if (startTotal <= endTotal) {
            now in startTotal..endTotal
        } else {
            now >= startTotal || now <= endTotal
        }
    }

    /**
     * 마스터 창 밖이면 슬롯 자체가 무시된다(슬롯이 있어도 즉시 null 반환) — 스케줄
     * 기능이 없던 오늘 코드와 완전히 동일한 동작을 보장하는 지점.
     */
    private fun activeSlotNow(now: Int): PushSchedule.Slot? {
        if (!inMasterWindow(now)) return null
        return PushSchedule.activeSlot(now, slots)
    }

    private fun effectiveIntervalMin(slot: PushSchedule.Slot?): Int {
        if (slot == null || slot.intervalMin == PushSchedule.INHERIT) return intervalMin
        return slot.intervalMin
    }

    private fun effectiveFolderId(slot: PushSchedule.Slot?): Int? {
        return slot?.folderId ?: folderId
    }

    private fun fireIfInRange(nowTotal: Int, slot: PushSchedule.Slot?) {
        if (!inMasterWindow(nowTotal)) {
            Log.d(TAG, "시간 범위 밖 ($nowTotal not in [$startTotal, $endTotal]), 스킵")
            return
        }

        Log.d(TAG, "알림 발사! ($nowTotal)")
        val targetFolderId = effectiveFolderId(slot)
        // DB I/O를 백그라운드 스레드에서 실행 (ANR 방지)
        Thread {
            try {
                showCardNotification(targetFolderId)
            } catch (e: Exception) {
                Log.e(TAG, "showCardNotification 실패", e)
            }
        }.start()
    }

    /**
     * cards 테이블에서 [folderIdFilter](null이면 전체)로 필터링한 랜덤 카드 1건을 조회.
     * 반환: Triple(cardId, cardFolderId, question) — cardId<=0이면 조회 실패(0건).
     */
    private fun queryRandomCard(db: SQLiteDatabase, folderIdFilter: Int?): Triple<Int, Int, String> {
        val where = if (folderIdFilter != null) "folder_id = ?" else null
        val args = if (folderIdFilter != null) arrayOf(folderIdFilter.toString()) else null
        val cursor = db.query("cards", arrayOf("id", "folder_id", "question"),
            where, args, null, null, "RANDOM()", "1")
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

            // 랜덤 카드 조회 (시간대 슬롯이 지정한 폴더 우선)
            var (cardId, cardFolderId, question) = queryRandomCard(db, targetFolderId)

            // 카드 0건 폴백: 슬롯이 가리키는 폴더가 삭제되었거나 카드가 비어 있으면
            // 전역 폴더로 1회 재조회 — 슬롯 폴더가 무효해졌다고 알림 자체가 조용히
            // 끊기지 않게 한다. targetFolderId == folderId(슬롯이 없거나 전역과 같은
            // 폴더)면 재조회해도 결과가 같으므로 스킵.
            if (cardId <= 0 && targetFolderId != folderId) {
                Log.w(TAG, "슬롯 폴더($targetFolderId) 카드 없음, 전역 폴더($folderId)로 재조회")
                val fallback = queryRandomCard(db, folderId)
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

            if (!soundEnabled) {
                builder.setSilent(true)
            }

            nm?.notify(notifId, builder.build())
            Log.d(TAG, "알림 표시 완료: cardId=$cardId, payload=$payload, body=$question")
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

    private fun createServiceNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("navigate_to", "push_notification_settings")
        }
        val pi = PendingIntent.getActivity(this, 2, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        val startH = startTotal / 60
        val startM = startTotal % 60
        val endH = endTotal / 60
        val endM = endTotal % 60

        // 상주 알림이 스와이프로 제거되면 서비스가 다시 알림을 생성
        val recreateIntent = Intent(this, PushNotificationService::class.java).apply {
            action = "RECREATE_NOTIFICATION"
        }
        val deletePi = foregroundServicePendingIntent(
            this, 200, recreateIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val rangeText = "${String.format(java.util.Locale.US, "%02d:%02d", startH, startM)}~${String.format(java.util.Locale.US, "%02d:%02d", endH, endM)}"
        // 상주 알림에 보여줄 간격은 "지금" 시각 기준 실효 간격 — 시간대 슬롯이 간격을
        // 오버라이드하고 있다면 전역 intervalMin이 아니라 그 값을 보여줘야 한다.
        val contentText = AppLang.wrap(this, lang)
            .getString(R.string.push_service_text, rangeText, effectiveIntervalMin(activeSlotNow(nowMinutes())))

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
