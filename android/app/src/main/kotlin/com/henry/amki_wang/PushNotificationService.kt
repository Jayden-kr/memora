package com.henry.amki_wang

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
 * - Handler.postDelayed로 정확한 간격 알림
 * - SQLite 직접 접근으로 랜덤 카드 조회
 */
class PushNotificationService : Service() {
    companion object {
        const val TAG = "PushNotifService"
        const val CHANNEL_ID = "push_notif_service_channel"
        const val SERVICE_NOTIF_ID = 3
        const val CARD_NOTIF_BASE = 50000
        const val ACTION_STOP = "STOP"
    }

    private val handler = Handler(Looper.getMainLooper())
    private var intervalMin = 30
    private var startTotal = 540   // 09:00
    private var endTotal = 1320    // 22:00
    private var folderId: Int? = null
    private var soundEnabled = true
    private var tickCount = 0

    private val tickRunnable = object : Runnable {
        override fun run() {
            fireIfInRange()
            handler.postDelayed(this, intervalMin * 60 * 1000L)
        }
    }

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
            handler.removeCallbacks(tickRunnable)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            saveRunning(false)
            return START_NOT_STICKY
        }

        // 설정 읽기
        val prefs = getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
        intervalMin = intent?.getIntExtra("intervalMin", prefs.getInt("intervalMin", 30)) ?: prefs.getInt("intervalMin", 30)
        startTotal = intent?.getIntExtra("startTotal", prefs.getInt("startTotal", 540)) ?: prefs.getInt("startTotal", 540)
        endTotal = intent?.getIntExtra("endTotal", prefs.getInt("endTotal", 1320)) ?: prefs.getInt("endTotal", 1320)
        folderId = intent?.getIntExtra("folderId", prefs.getInt("folderId", -1))?.let { if (it == -1) null else it }
            ?: prefs.getInt("folderId", -1).let { if (it == -1) null else it }
        soundEnabled = intent?.getBooleanExtra("soundEnabled", prefs.getBoolean("soundEnabled", true))
            ?: prefs.getBoolean("soundEnabled", true)

        // 설정 저장 (재시작 시 복원용)
        prefs.edit()
            .putInt("intervalMin", intervalMin)
            .putInt("startTotal", startTotal)
            .putInt("endTotal", endTotal)
            .putInt("folderId", folderId ?: -1)
            .putBoolean("soundEnabled", soundEnabled)
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

        // 타이머 시작 — 시간대에 맞춰 정확한 딜레이 계산
        handler.removeCallbacks(tickRunnable)
        val cal = java.util.Calendar.getInstance()
        val nowMin = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)

        val delayMin: Int = when {
            nowMin < startTotal -> {
                // 시작 시간 전 → startTotal까지 대기
                startTotal - nowMin
            }
            nowMin > endTotal -> {
                // 종료 시간 후 → 다음날 startTotal까지 대기
                (1440 - nowMin) + startTotal
            }
            else -> {
                // 범위 내 → 다음 interval 시점까지
                val elapsed = (nowMin - startTotal) % intervalMin
                if (elapsed == 0) intervalMin else (intervalMin - elapsed)
            }
        }

        val delayMs = delayMin * 60 * 1000L
        Log.d(TAG, "${delayMin}분 후 첫 알림 (현재분=$nowMin, start=$startTotal, end=$endTotal)")
        handler.postDelayed(tickRunnable, delayMs)

        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tickRunnable)
        Log.d(TAG, "onDestroy")
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.d(TAG, "onTaskRemoved — AlarmManager로 서비스 재시작 예약")
        // Samsung에서 직접 startService 호출은 무시될 수 있으므로 AlarmManager로 예약
        val restartIntent = Intent(applicationContext, PushNotificationService::class.java)
        val pi = PendingIntent.getForegroundService(
            applicationContext, 9999, restartIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = getSystemService(Context.ALARM_SERVICE) as? android.app.AlarmManager
        am?.setExactAndAllowWhileIdle(
            android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP,
            android.os.SystemClock.elapsedRealtime() + 3000, // 3초 후 재시작
            pi
        )
    }

    private fun fireIfInRange() {
        val cal = java.util.Calendar.getInstance()
        val nowTotal = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)

        // end inclusive: 22:00 설정 시 22:00까지 발사
        if (nowTotal < startTotal || nowTotal > endTotal) {
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

            // 랜덤 카드 조회
            val where = if (folderId != null) "folder_id = ?" else null
            val args = if (folderId != null) arrayOf(folderId.toString()) else null
            val cursor = db.query("cards", arrayOf("id", "folder_id", "question"),
                where, args, null, null, "RANDOM()", "1")

            var question = "카드를 복습할 시간입니다!"
            var payload: String? = null
            cursor.use {
                if (it.moveToFirst()) {
                    val q = it.getString(it.getColumnIndexOrThrow("question"))
                    val cardId = it.getInt(it.getColumnIndexOrThrow("id"))
                    val cardFolderId = it.getInt(it.getColumnIndexOrThrow("folder_id"))
                    if (!q.isNullOrEmpty()) question = q
                    payload = "$cardFolderId:$cardId"
                }
            }

            // 알림 탭 → 해당 카드로 이동하는 Intent
            val launchIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                if (payload != null) {
                    putExtra("notification_payload", payload)
                }
            }
            val pi = PendingIntent.getActivity(this, tickCount, launchIntent,
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

            val nm = getSystemService(NotificationManager::class.java)
            // review_notification_channel은 Flutter 플러그인이 생성/관리
            // 채널이 없으면 알림이 안 뜨므로 fallback 생성
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (nm?.getNotificationChannel("review_notification_channel") == null) {
                    val channel = NotificationChannel(
                        "review_notification_channel", "복습 알림",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply {
                        description = "설정한 시간에 랜덤 카드 알림"
                        enableVibration(true)
                    }
                    nm.createNotificationChannel(channel)
                }
            }

            // Android 13+: POST_NOTIFICATIONS 권한 확인
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                    Log.w(TAG, "POST_NOTIFICATIONS 권한 없음, 알림 스킵")
                    return
                }
            }
            nm?.notify(CARD_NOTIF_BASE + (tickCount++ % 500), builder.build())
            Log.d(TAG, "알림 표시 완료: $question")
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
            getDatabasePath("amki_wang.db"),
            java.io.File(dataDir, "app_flutter/amki_wang.db"),
            java.io.File(filesDir, "app_flutter/amki_wang.db"),
            java.io.File(filesDir, "amki_wang.db"),
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
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        val pi = PendingIntent.getActivity(this, 0, launchIntent,
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

    private fun saveRunning(running: Boolean) {
        getSharedPreferences("push_notif_prefs", MODE_PRIVATE)
            .edit().putBoolean("running", running).commit()
    }
}
