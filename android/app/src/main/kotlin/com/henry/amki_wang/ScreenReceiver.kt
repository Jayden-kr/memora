package com.henry.amki_wang

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class ScreenReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_SCREEN_OFF) {
            val serviceIntent = Intent(context, LockScreenService::class.java)
            serviceIntent.action = "SHOW_OVERLAY"
            try {
                // Android O+ 에서는 startForegroundService 사용 (서비스 재시작 레이스 방지)
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
