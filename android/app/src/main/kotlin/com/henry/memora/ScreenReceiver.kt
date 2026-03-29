package com.henry.memora

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log

class ScreenReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_SCREEN_OFF) {
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
    }
}
