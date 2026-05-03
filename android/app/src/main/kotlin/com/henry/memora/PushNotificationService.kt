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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
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

        if (intent?.action == ACTION_STOP) {
            Log.d(TAG, "STOP 수신 — 서비스 종료")
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

            saveRunning(true)

            // 다음 알람을 먼저 예약 (프로세스가 fireIfInRange 도중 죽어도 체인 유지)
            // 핵심: 예정시각(savedNextFireTime) 기준으로 다음 계산 → 드리프트 누적 방지
            val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            val intervalMs = intervalMin * 60 * 1000L
            val savedFireTime = prefs.getLong("nextFireTime", System.currentTimeMillis())
            var nextFireTime = savedFireTime + intervalMs
            // 만약 nextFireTime이 이미 과거면 → 다음 슬롯까지 건너뛰기
            while (nextFireTime <= System.currentTimeMillis()) {
                nextFireTime += intervalMs
            }
            saveNextFireTime(nextFireTime)
            scheduleNextAlarm(nextFireTime - System.currentTimeMillis())

            // 예약 완료 후 발화 (프로세스 사망 시 이번 알림만 유실, 체인은 유지)
            fireIfInRange()

            return START_STICKY
        }

        // 설정 읽기
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        intervalMin = maxOf(5, intent?.getIntExtra("intervalMin", prefs.getInt("intervalMin", 30)) ?: prefs.getInt("intervalMin", 30))
        startTotal = intent?.getIntExtra("startTotal", prefs.getInt("startTotal", 540)) ?: prefs.getInt("startTotal", 540)
        endTotal = intent?.getIntExtra("endTotal", prefs.getInt("endTotal", 1320)) ?: prefs.getInt("endTotal", 1320)
        folderId = intent?.getIntExtra("folderId", prefs.getInt("folderId", -1))?.let { if (it == -1) null else it }
            ?: prefs.getInt("folderId", -1).let { if (it == -1) null else it }
        soundEnabled = intent?.getBooleanExtra("soundEnabled", prefs.getBoolean("soundEnabled", true))
            ?: prefs.getBoolean("soundEnabled", true)

        // 타이밍 설정 변경 여부 판별 (폴더/알림음은 타이밍과 무관)
        val timingKey = "$intervalMin:$startTotal:$endTotal"
        val savedTimingKey = prefs.getString("timingKey", "") ?: ""
        val wasRunning = prefs.getBoolean("running", false)

        // 설정 저장 (재시작 시 복원용)
        prefs.edit()
            .putInt("intervalMin", intervalMin)
            .putInt("startTotal", startTotal)
            .putInt("endTotal", endTotal)
            .putInt("folderId", folderId ?: -1)
            .putBoolean("soundEnabled", soundEnabled)
            .putString("timingKey", timingKey)
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

            if (remaining > 0) {
                scheduleNextAlarm(remaining)
                Log.d(TAG, "타이머 유지: ${remaining / 60000}분 ${(remaining % 60000) / 1000}초 남음")
            } else {
                // 이전 예약 시간이 이미 지남 → 새 interval 시작 (즉시 발화 X)
                // 알림은 TICK 알람만 발사해야 함. 앱 열기 = 알림 트리거 아님.
                val delayMs = intervalMin * 60 * 1000L
                saveNextFireTime(System.currentTimeMillis() + delayMs)
                scheduleNextAlarm(delayMs)
                Log.d(TAG, "타이머 만료 → ${intervalMin}분 후 다음 알림 예약")
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
        val pi = PendingIntent.getForegroundService(
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
        val pi = PendingIntent.getForegroundService(
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
        val pi = PendingIntent.getForegroundService(
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
        val pi = PendingIntent.getForegroundService(
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
    }

    private fun fireIfInRange() {
        val cal = java.util.Calendar.getInstance()
        val nowTotal = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)

        // 시간 범위 체크 (overnight 지원: start > end인 경우 자정 넘김)
        val inRange = if (startTotal <= endTotal) {
            nowTotal in startTotal..endTotal
        } else {
            // overnight: 22:00~06:00 → nowTotal >= 22:00 OR nowTotal <= 06:00
            nowTotal >= startTotal || nowTotal <= endTotal
        }
        if (!inRange) {
            Log.d(TAG, "시간 범위 밖 ($nowTotal not in [$startTotal, $endTotal]), 스킵")
            return
        }

        Log.d(TAG, "알림 발사! ($nowTotal)")
        // DB I/O를 백그라운드 스레드에서 실행 (ANR 방지)
        Thread {
            try {
                showCardNotification()
            } catch (e: Exception) {
                Log.e(TAG, "showCardNotification 실패", e)
            }
        }.start()
    }

    private fun showCardNotification() {
        val dbFile = findDbFile() ?: return
        var db: SQLiteDatabase? = null
        try {
            db = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS)
            try { db.enableWriteAheadLogging() } catch (_: Exception) {} // WAL 모드: Flutter sqflite와 동시 읽기 허용 (별도 :push 프로세스)

            // 랜덤 카드 조회
            val where = if (folderId != null) "folder_id = ?" else null
            val args = if (folderId != null) arrayOf(folderId.toString()) else null
            val cursor = db.query("cards", arrayOf("id", "folder_id", "question"),
                where, args, null, null, "RANDOM()", "1")

            var question = ""
            var cardId = -1
            var cardFolderId = -1
            cursor.use {
                if (it.moveToFirst()) {
                    val q = it.getString(it.getColumnIndexOrThrow("question"))
                    cardId = it.getInt(it.getColumnIndexOrThrow("id"))
                    cardFolderId = it.getInt(it.getColumnIndexOrThrow("folder_id"))
                    if (!q.isNullOrEmpty()) question = q
                }
            }

            // 카드 조회 실패 시 알림 자체를 건너뜀.
            // payload 없이 알림을 띄우면 탭해도 네비게이션이 안 되므로 무의미.
            if (cardId <= 0) {
                Log.w(TAG, "랜덤 카드 조회 실패, 알림 스킵")
                return
            }
            if (question.isEmpty()) {
                question = "카드를 복습할 시간입니다!"
            }

            // notifId = requestCode = CARD_NOTIF_BASE + cardId
            // 카드별로 stable한 PendingIntent — 같은 카드가 또 뽑혀도 자기자신만 교체하므로
            // 본문/payload가 항상 일치한다. 다른 카드끼리는 ID가 달라 PI extras 누수 불가능.
            val notifId = CARD_NOTIF_BASE + cardId
            val payload = "$cardFolderId:$cardId"

            val nm = getSystemService(NotificationManager::class.java)
            // review_notification_channel은 Flutter 플러그인이 생성/관리.
            // 채널이 없으면 알림이 안 뜨므로 fallback 생성.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (nm?.getNotificationChannel("review_notification_channel") == null) {
                    val channel = NotificationChannel(
                        "review_notification_channel", "복습 알림",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "설정한 시간에 랜덤 카드 알림"
                        enableVibration(true)
                    }
                    nm?.createNotificationChannel(channel)
                }
            }

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

            val builder = NotificationCompat.Builder(this, "review_notification_channel")
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Memora")
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

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "푸시 알림 서비스",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "간격 반복 알림 백그라운드 서비스"
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
        val deletePi = PendingIntent.getForegroundService(
            this, 200, recreateIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Memora")
            .setContentText("${String.format(java.util.Locale.US, "%02d:%02d", startH, startM)}~${String.format(java.util.Locale.US, "%02d:%02d", endH, endM)}, ${intervalMin}분 간격 알림 활성화")
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
