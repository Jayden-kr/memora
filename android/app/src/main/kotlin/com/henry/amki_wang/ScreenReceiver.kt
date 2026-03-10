package com.henry.amki_wang

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ScreenReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_SCREEN_OFF) {
            val serviceIntent = Intent(context, LockScreenService::class.java)
            serviceIntent.action = "SHOW_OVERLAY"
            context.startService(serviceIntent)
        }
    }
}
