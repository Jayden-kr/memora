package com.henry.memora

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
        /// 푸시 복원 실패 안내는 별도 ID — 잠금화면 복원과 ID를 공유하면 둘 다 실패했을 때
        /// 한쪽 안내가 다른 쪽을 덮어써 사라졌다(감사 D6-06).
        private const val PUSH_RESTORE_NOTIFICATION_ID = 9002

        /**
         * 앱 언어가 바뀌었을 때 복원 알림 채널의 이름/설명을 새 언어로 갱신한다.
         * 채널 4개 중 이것만 갱신 대상에서 빠져 있어 시스템 알림 설정에서 이 채널만
         * 다른 언어로 남았다(감사 X5-05). 같은 ID로 다시 만드는 것은 비파괴적이며,
         * 채널이 아직 없으면 아무것도 하지 않는다(다음 실패 때 새 언어로 생성됨).
         */
        fun refreshChannelLanguage(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val appContext = context.applicationContext
            val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager ?: return
            if (nm.getNotificationChannel(CHANNEL_ID) == null) return
            val res = AppLang.wrap(appContext)
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    res.getString(R.string.restore_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = res.getString(R.string.restore_channel_desc)
                }
            )
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        // 푸시 알림 서비스 복원 (잠금화면 무관)
        restorePushNotificationService(context)

        val prefs = context.getSharedPreferences("lock_screen_prefs", Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean("enabled", false)
        if (!enabled) return

        // 오버레이 권한 확인 (API 23+ — canDrawOverlays는 Marshmallow부터)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(context)) {
                showRestoreNotification(context)
                Log.w(TAG, "Cannot start FGS: overlay permission not granted")
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
            showRestoreNotification(context)
        }
    }

    private fun restorePushNotificationService(context: Context) {
        val pushPrefs = context.getSharedPreferences("push_notif_prefs", Context.MODE_PRIVATE)
        if (!pushPrefs.getBoolean("running", false)) return

        try {
            val pushIntent = Intent(context, PushNotificationService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(pushIntent)
            } else {
                context.startService(pushIntent)
            }
            Log.i(TAG, "Push notification service restored after boot")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to restore push service: ${e.message}")
            // 서비스 시작 실패 시 사용자에게 알림 (수동 재시작 유도). 잠금화면 복원과 문구를
            // 분리한다 — 잠금화면을 안 쓰는 사용자에게 "잠금화면 카드 복원" 알림이 뜨던 결함.
            showRestoreNotification(context, forPush = true)
        }
    }

    private fun showRestoreNotification(context: Context, forPush: Boolean = false) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        // 부팅 직후라 Flutter는 아직 안 떴지만, 언어는 prefs에 남아 있으므로 그대로 따른다.
        val res = AppLang.wrap(context)

        // 알림 채널 생성 (API 26+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                res.getString(R.string.restore_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = res.getString(R.string.restore_channel_desc)
            }
            nm.createNotificationChannel(channel)
        }

        // 잠금화면 복원 실패와 푸시 복원 실패는 서로 다른 알림이다(문구도 ID도 분리).
        val notifId =
            if (forPush) PUSH_RESTORE_NOTIFICATION_ID else RESTORE_NOTIFICATION_ID

        // 앱 열기 Intent
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        // requestCode는 이 알림 고유값 — 예전엔 0이라 ImportExportService의 진행 알림 PI(같은
        // MainActivity 컴포넌트, requestCode 0)와 FLAG_UPDATE_CURRENT로 서로의 extras를 덮어썼다.
        val pendingIntent = PendingIntent.getActivity(
            context, notifId, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(res.getString(
                if (forPush) R.string.restore_push_notif_title else R.string.restore_notif_title))
            .setContentText(res.getString(
                if (forPush) R.string.restore_push_notif_text else R.string.restore_notif_text))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        nm.notify(notifId, notification)
    }
}
