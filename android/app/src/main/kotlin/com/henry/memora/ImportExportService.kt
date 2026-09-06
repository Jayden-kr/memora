package com.henry.memora

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class ImportExportService : Service() {
    companion object {
        const val CHANNEL_ID = "import_export_channel"
        const val PROGRESS_NOTIFICATION_ID = 2001
        const val COMPLETE_NOTIFICATION_ID = 2002

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
                if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                    val res = AppLang.wrap(context)
                    val channel = NotificationChannel(
                        CHANNEL_ID, res.getString(R.string.ie_channel_name),
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = res.getString(R.string.ie_channel_desc)
                        setShowBadge(false)
                    }
                    manager.createNotificationChannel(channel)
                }
            }
        }

        /**
         * 앱 언어가 바뀌었을 때 채널 이름/설명을 새 언어로 갱신한다.
         * 같은 ID로 다시 만드는 것은 비파괴적이다 — 이름/설명만 바뀌고 사용자가 조정한
         * 중요도·소리 설정은 유지된다. 채널이 아직 없으면 아무것도 하지 않는다
         * (다음 import/export 때 어차피 새 언어로 생성됨).
         */
        fun refreshChannelLanguage(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val appContext = context.applicationContext
            val manager = appContext.getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) == null) return
            val res = AppLang.wrap(appContext)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, res.getString(R.string.ie_channel_name),
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = res.getString(R.string.ie_channel_desc)
                    setShowBadge(false)
                }
            )
        }

        fun updateProgress(context: Context, title: String, message: String, progress: Int, max: Int, type: String = "import") {
            val appContext = context.applicationContext
            // Android 13+: POST_NOTIFICATIONS 권한 없으면 알림 스킵
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                if (androidx.core.content.ContextCompat.checkSelfPermission(appContext,
                        android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
            }
            ensureChannel(appContext)
            val intent = Intent(appContext, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                if (type == "import") {
                    putExtra("navigate_to_import", true)
                } else if (type == "export") {
                    putExtra("navigate_to_export", true)
                }
            }
            // requestCode 0은 부팅 복원 알림(LockScreenStartReceiver)과 공유돼 PI extras가
            // 서로 덮였다 — 이 알림 고유의 ID를 쓴다.
            val pendingIntent = PendingIntent.getActivity(
                appContext, PROGRESS_NOTIFICATION_ID, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val notification = NotificationCompat.Builder(appContext, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(message)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setProgress(max, progress, max == 0)
                .build()

            val manager = appContext.getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
            manager.notify(PROGRESS_NOTIFICATION_ID, notification)
        }

        fun showComplete(context: Context, title: String, message: String, type: String = "import") {
            val appContext = context.applicationContext
            // Android 13+: POST_NOTIFICATIONS 권한 없으면 알림 스킵
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                if (androidx.core.content.ContextCompat.checkSelfPermission(appContext,
                        android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
            }
            ensureChannel(appContext)
            // 진행 알림 제거 (이중 알림 방지)
            val mgr = appContext.getSystemService(NOTIFICATION_SERVICE) as? NotificationManager
            mgr?.cancel(PROGRESS_NOTIFICATION_ID)
            val intent = Intent(appContext, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                if (type == "import") {
                    putExtra("navigate_to_import", true)
                } else if (type == "export") {
                    putExtra("navigate_to_export", true)
                }
            }
            val pendingIntent = PendingIntent.getActivity(
                appContext, 3, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val notification = NotificationCompat.Builder(appContext, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(message)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setOngoing(false)
                .build()

            val manager = appContext.getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
            manager.notify(COMPLETE_NOTIFICATION_ID, notification)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "STOP" -> {
                // startForegroundService로 시작된 경우 반드시 startForeground 호출 필요 (Android 12+ 크래시 방지)
                // 서비스가 이미 destroy 후 재생성된 경우 startForeground 없이 stopSelf하면 ForegroundServiceDidNotStartInTimeException 발생
                try {
                    val stopNotification = NotificationCompat.Builder(this, CHANNEL_ID)
                        .setSmallIcon(R.drawable.ic_notification)
                        .setContentTitle("Memora")
                        .setSilent(true)
                        .build()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        startForeground(PROGRESS_NOTIFICATION_ID, stopNotification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                    } else {
                        startForeground(PROGRESS_NOTIFICATION_ID, stopNotification)
                    }
                } catch (e: Exception) {
                    android.util.Log.w("ImportExportService", "startForeground in STOP failed: ${e.message}")
                }
                // progress 알림도 명시적으로 취소
                val nm = getSystemService(android.app.NotificationManager::class.java)
                nm?.cancel(PROGRESS_NOTIFICATION_ID)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
                return START_NOT_STICKY
            }
        }

        val res = AppLang.wrap(this)
        val title = intent?.getStringExtra("title") ?: res.getString(R.string.ie_processing)
        val type = intent?.getStringExtra("type") ?: "import"
        // requestCode 0은 다른 알림의 PendingIntent와 같은 값이라 FLAG_UPDATE_CURRENT로 서로의
        // extras를 덮어썼다(감사 D4-09/D6-11) — 위 updateProgress와 같은 고유 ID를 쓴다.
        val pi = PendingIntent.getActivity(
            this, PROGRESS_NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).apply {
                this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                if (type == "import") {
                    putExtra("navigate_to_import", true)
                } else if (type == "export") {
                    putExtra("navigate_to_export", true)
                }
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(res.getString(R.string.ie_preparing))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setProgress(0, 0, true)
            .build()

        // 감사 X1-01: STOP 분기는 try/catch로 감싸는데 여기만 노출돼 있었다. Android 12+에서
        // ForegroundServiceStartNotAllowedException이 나면 import/export 시작만으로 앱이 죽는다.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    PROGRESS_NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(PROGRESS_NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            android.util.Log.e("ImportExportService", "startForeground 실패", e)
            // 포그라운드 승격에 실패하면 서비스로 남아 있을 이유가 없다 — 진행 알림은
            // updateProgress가 별도로 띄우므로 사용자에게 보이는 것은 그대로다.
            stopSelf()
        }

        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val res = AppLang.wrap(this)
            val channel = NotificationChannel(
                CHANNEL_ID,
                res.getString(R.string.ie_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = res.getString(R.string.ie_channel_desc)
                setShowBadge(false)
            }
            val manager = getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
            manager.createNotificationChannel(channel)
        }
    }
}
