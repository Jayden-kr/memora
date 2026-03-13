package com.henry.amki_wang

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat

class LockScreenStartReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "LockScreenStartReceiver"
        private const val CHANNEL_ID = "lock_screen_restore_channel"
        private const val RESTORE_NOTIFICATION_ID = 9001
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        val prefs = context.getSharedPreferences("lock_screen_prefs", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("enabled", false)
        if (!enabled) return

        // API 31+: SYSTEM_ALERT_WINDOW 권한이 있으면 백그라운드 FGS 시작 면제
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!Settings.canDrawOverlays(context)) {
                // 오버레이 권한 없이는 FGS 시작 불가 → 사용자에게 앱 열기 안내 알림
                showRestoreNotification(context)
                Log.w(TAG, "Cannot start FGS: overlay permission not granted on API 31+")
                return
            }
        }

        val serviceIntent = Intent(context, LockScreenService::class.java)
        serviceIntent.action = "START_SERVICE"
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.i(TAG, "Lock screen service started after ${intent.action}")
        } catch (e: Exception) {
            Log.w(TAG, "Cannot start FGS from background: ${e.message}")
            // 서비스 시작 실패 시 사용자에게 안내 알림
            showRestoreNotification(context)
        }
    }

    private fun showRestoreNotification(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // 알림 채널 생성 (API 26+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "잠금화면 복원",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "부팅 후 잠금화면 서비스 복원 안내"
            }
            nm.createNotificationChannel(channel)
        }

        // 앱 열기 Intent
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Memora 잠금화면")
            .setContentText("잠금화면 카드를 복원하려면 앱을 열어주세요.")
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        nm.notify(RESTORE_NOTIFICATION_ID, notification)
    }
}
