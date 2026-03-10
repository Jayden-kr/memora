package com.henry.amki_wang

import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.henry.amki_wang/lockscreen"
    private val TAG = "AmkiWang"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startService" -> {
                            val settings = call.arguments as? Map<String, Any?> ?: emptyMap()
                            saveSettings(settings)
                            startLockScreenService()
                            result.success(true)
                        }
                        "stopService" -> {
                            stopLockScreenService()
                            result.success(true)
                        }
                        "saveSettings" -> {
                            val settings = call.arguments as? Map<String, Any?> ?: emptyMap()
                            saveSettings(settings)
                            result.success(true)
                        }
                        "isRunning" -> {
                            result.success(isServiceRunning())
                        }
                        "canDrawOverlays" -> {
                            result.success(Settings.canDrawOverlays(this))
                        }
                        "requestOverlayPermission" -> {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                android.net.Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(true)
                        }
                        "getSettings" -> {
                            result.success(loadSettings())
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "MethodChannel error: ${call.method}", e)
                    result.error("ERROR", e.message, e.stackTraceToString())
                }
            }
    }

    private fun saveSettings(settings: Map<String, Any?>) {
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        val editor = prefs.edit()
        editor.putBoolean("enabled", settings["enabled"] as? Boolean ?: false)

        // folderIds: Dart List<int> → Kotlin List<*> (Integer or Long)
        val folderIds = settings["folderIds"]
        val folderIdsStr = when (folderIds) {
            is List<*> -> folderIds.filterNotNull().joinToString(",") { it.toString() }
            else -> ""
        }
        editor.putString("folder_ids", folderIdsStr)

        editor.putInt("finished_filter",
            (settings["finishedFilter"] as? Number)?.toInt() ?: -1)
        editor.putBoolean("random_order",
            settings["randomOrder"] as? Boolean ?: true)
        editor.putBoolean("reversed",
            settings["reversed"] as? Boolean ?: false)
        editor.putInt("bg_color",
            (settings["bgColor"] as? Number)?.toInt() ?: 0xFF1A1A2E.toInt())
        editor.apply()

        Log.d(TAG, "Settings saved: enabled=${settings["enabled"]}, folders=$folderIdsStr")
    }

    private fun loadSettings(): Map<String, Any?> {
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        return mapOf(
            "enabled" to prefs.getBoolean("enabled", false),
            "folderIds" to (prefs.getString("folder_ids", "")
                ?.split(",")
                ?.filter { it.isNotEmpty() }
                ?.mapNotNull { it.toIntOrNull() } ?: emptyList<Int>()),
            "finishedFilter" to prefs.getInt("finished_filter", -1),
            "randomOrder" to prefs.getBoolean("random_order", true),
            "reversed" to prefs.getBoolean("reversed", false),
            "bgColor" to prefs.getInt("bg_color", 0xFF1A1A2E.toInt())
        )
    }

    private fun startLockScreenService() {
        try {
            val intent = Intent(this, LockScreenService::class.java)
            intent.action = "START_SERVICE"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            Log.d(TAG, "startLockScreenService called")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start service", e)
        }
    }

    private fun stopLockScreenService() {
        try {
            val intent = Intent(this, LockScreenService::class.java)
            stopService(intent)
            Log.d(TAG, "stopLockScreenService called")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop service", e)
        }
    }

    private fun isServiceRunning(): Boolean {
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        return prefs.getBoolean("service_running", false)
    }
}
