package com.henry.amki_wang

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
                    val channel = NotificationChannel(
                        CHANNEL_ID, "Import/Export 진행",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = "Import/Export 진행 상태를 표시합니다"
                        setShowBadge(false)
                    }
                    manager.createNotificationChannel(channel)
                }
            }
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
            val pendingIntent = PendingIntent.getActivity(
                appContext, 0, intent,
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
                appContext, 1, intent,
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

        val title = intent?.getStringExtra("title") ?: "처리 중..."
        val type = intent?.getStringExtra("type") ?: "import"
        val pi = PendingIntent.getActivity(
            this, 0,
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
            .setContentText("준비 중...")
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setProgress(0, 0, true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                PROGRESS_NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(PROGRESS_NOTIFICATION_ID, notification)
        }

        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Import/Export 진행",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Import/Export 진행 상태를 표시합니다"
                setShowBadge(false)
            }
            val manager = getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
            manager.createNotificationChannel(channel)
        }
    }
}
