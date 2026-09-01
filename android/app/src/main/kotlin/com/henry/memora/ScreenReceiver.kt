package com.henry.memora

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log

class ScreenReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_OFF -> {
                // Android 12+ 에서는 오버레이 권한 없으면 FGS 시작 불가
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    if (!Settings.canDrawOverlays(context)) {
                        Log.w("ScreenReceiver", "No overlay permission, skipping SHOW_OVERLAY")
                        return
                    }
                }
                val serviceIntent = Intent(context, LockScreenService::class.java)
                serviceIntent.action = "SHOW_OVERLAY"
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(serviceIntent)
                    } else {
                        context.startService(serviceIntent)
                    }
                } catch (e: Exception) {
                    Log.w("ScreenReceiver", "Failed to send SHOW_OVERLAY", e)
                }
            }
            Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_TIME_CHANGED -> {
                // 서비스는 오래 사는 프로세스라 TimeZone.getDefault()가 캐시된 채로 남을 수
                // 있다. 이스라엘(DST 있음)로 이주하는 사용자를 위한 대비 — null로 넘기면
                // 다음 Calendar.getInstance()가 시스템 타임존을 다시 읽는다.
                java.util.TimeZone.setDefault(null)
                Log.d("ScreenReceiver", "TimeZone cache cleared (${intent.action})")
            }
        }
    }
}
