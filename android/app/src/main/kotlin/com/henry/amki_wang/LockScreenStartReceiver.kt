package com.henry.amki_wang

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class LockScreenStartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val prefs = context.getSharedPreferences("lock_screen_prefs", Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("enabled", false)
            if (!enabled) return

            val serviceIntent = Intent(context, LockScreenService::class.java)
            serviceIntent.action = "START_SERVICE"
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (e: Exception) {
                // API 31+ 백그라운드 FGS 시작 제한 (ForegroundServiceStartNotAllowedException)
                Log.w("LockScreenStartReceiver", "Cannot start FGS from background: ${e.message}")
            }
        }
    }
}
