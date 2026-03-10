package com.henry.amki_wang

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class LockScreenStartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            val prefs = context.getSharedPreferences("lock_screen_prefs", Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("enabled", false)
            if (!enabled) return

            val serviceIntent = Intent(context, LockScreenService::class.java)
            serviceIntent.action = "START_SERVICE"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }
    }
}
