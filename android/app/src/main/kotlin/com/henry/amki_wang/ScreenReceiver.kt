package com.henry.amki_wang

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class ScreenReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_SCREEN_OFF) {
            val serviceIntent = Intent(context, LockScreenService::class.java)
            serviceIntent.action = "SHOW_OVERLAY"
            // 서비스가 이미 foreground로 실행 중이므로 startService 사용
            try {
                context.startService(serviceIntent)
            } catch (e: Exception) {
                Log.w("ScreenReceiver", "Failed to send SHOW_OVERLAY", e)
            }
        }
    }
}
