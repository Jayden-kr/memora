package com.henry.amki_wang

import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.henry.amki_wang/lockscreen"
    private val IMPORT_EXPORT_CHANNEL = "com.henry.amki_wang/import_export"
    private val TAG = "AmkiWang"

    private var importExportChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Import/Export Foreground Service MethodChannel
        val ieChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IMPORT_EXPORT_CHANNEL)
        importExportChannel = ieChannel
        ieChannel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startService" -> {
                            val title = call.argument<String>("title") ?: "처리 중..."
                            val type = call.argument<String>("type") ?: "import"
                            // 알림을 즉시 표시 (foreground service 시작 전)
                            ImportExportService.updateProgress(this, title, "준비 중...", 0, 0, type)
                            val intent = Intent(this, ImportExportService::class.java)
                            intent.putExtra("title", title)
                            intent.putExtra("type", type)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        }
                        "updateProgress" -> {
                            val title = call.argument<String>("title") ?: ""
                            val message = call.argument<String>("message") ?: ""
                            val progress = call.argument<Int>("progress") ?: 0
                            val max = call.argument<Int>("max") ?: 0
                            val type = call.argument<String>("type") ?: "import"
                            ImportExportService.updateProgress(this, title, message, progress, max, type)
                            result.success(true)
                        }
                        "complete" -> {
                            val title = call.argument<String>("title") ?: "완료"
                            val message = call.argument<String>("message") ?: ""
                            val type = call.argument<String>("type") ?: "import"
                            // Stop foreground service
                            val stopIntent = Intent(this, ImportExportService::class.java)
                            stopIntent.action = "STOP"
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startForegroundService(stopIntent)
                                } else {
                                    startService(stopIntent)
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "Failed to send STOP to ImportExportService: ${e.message}")
                            }
                            // Show completion notification
                            ImportExportService.showComplete(this, title, message, type)
                            result.success(true)
                        }
                        "cancel" -> {
                            val stopIntent = Intent(this, ImportExportService::class.java)
                            stopIntent.action = "STOP"
                            try {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startForegroundService(stopIntent)
                                } else {
                                    startService(stopIntent)
                                }
                            } catch (e: Exception) {
                                Log.w(TAG, "Failed to send STOP to ImportExportService: ${e.message}")
                            }
                            result.success(true)
                        }
                        "generatePdf" -> {
                            val outputPath = call.argument<String>("outputPath")!!
                            val folderId = call.argument<Int>("folderId")!!
                            val folderIndex = call.argument<Int>("folderIndex") ?: 0
                            val totalFolders = call.argument<Int>("totalFolders") ?: 1
                            val channel = ieChannel
                            Thread {
                                try {
                                    PdfGenerator(this).generate(
                                        outputPath = outputPath,
                                        folderId = folderId,
                                        folderIndex = folderIndex,
                                        totalFolders = totalFolders,
                                        onProgress = { current, total, message ->
                                            runOnUiThread {
                                                channel?.invokeMethod("pdfProgress", mapOf(
                                                    "current" to current,
                                                    "total" to total,
                                                    "message" to message,
                                                ))
                                            }
                                        }
                                    )
                                    runOnUiThread { result.success(true) }
                                } catch (e: Exception) {
                                    Log.e(TAG, "PDF generation failed", e)
                                    runOnUiThread { result.error("PDF_ERROR", e.message, null) }
                                }
                            }.start()
                        }
                        "moveToBackground" -> {
                            moveTaskToBack(true)
                            result.success(true)
                        }
                        "saveToDownloads" -> {
                            val sourcePath = call.argument<String>("sourcePath")
                            val fileName = call.argument<String>("fileName")
                            if (sourcePath == null || fileName == null) {
                                result.error("ERROR", "sourcePath and fileName required", null)
                                return@setMethodCallHandler
                            }
                            try {
                                val sourceFile = File(sourcePath)
                                if (!sourceFile.exists()) {
                                    result.error("ERROR", "Source file not found", null)
                                    return@setMethodCallHandler
                                }
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    val values = ContentValues().apply {
                                        put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                                        put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                                        put(MediaStore.Downloads.IS_PENDING, 1)
                                    }
                                    val uri = contentResolver.insert(
                                        MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                                    )
                                    if (uri != null) {
                                        try {
                                            contentResolver.openOutputStream(uri)?.use { output ->
                                                sourceFile.inputStream().use { input ->
                                                    input.copyTo(output)
                                                }
                                            }
                                            values.clear()
                                            values.put(MediaStore.Downloads.IS_PENDING, 0)
                                            contentResolver.update(uri, values, null, null)
                                            result.success(true)
                                        } catch (e: Exception) {
                                            // 실패 시 IS_PENDING 고아 레코드 정리
                                            contentResolver.delete(uri, null, null)
                                            result.error("ERROR", e.message, e.stackTraceToString())
                                        }
                                    } else {
                                        result.error("ERROR", "Failed to create MediaStore entry", null)
                                    }
                                } else {
                                    @Suppress("DEPRECATION")
                                    val downloadsDir = Environment.getExternalStoragePublicDirectory(
                                        Environment.DIRECTORY_DOWNLOADS
                                    )
                                    val destFile = File(downloadsDir, fileName)
                                    sourceFile.copyTo(destFile, overwrite = true)
                                    result.success(true)
                                }
                            } catch (e: Exception) {
                                result.error("ERROR", e.message, e.stackTraceToString())
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "ImportExport MethodChannel error: ${call.method}", e)
                    result.error("ERROR", e.message, e.stackTraceToString())
                }
            }

        // Lock Screen MethodChannel
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleImportNavigationIntent(intent)
    }

    private fun handleImportNavigationIntent(intent: Intent) {
        if (intent.getBooleanExtra("navigate_to_import", false)) {
            intent.removeExtra("navigate_to_import")
            importExportChannel?.invokeMethod("navigateToImport", null)
        }
        if (intent.getBooleanExtra("navigate_to_export", false)) {
            intent.removeExtra("navigate_to_export")
            importExportChannel?.invokeMethod("navigateToExport", null)
        }
    }

    private fun isServiceRunning(): Boolean {
        // SharedPreferences 플래그는 OS kill 시 스테일해질 수 있으므로
        // 실제 알림 존재 여부로 서비스 실행 상태 확인
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm != null) {
                val hasNotification = nm.activeNotifications.any {
                    it.id == LockScreenService.NOTIFICATION_ID
                }
                if (hasNotification) return true
                // 알림 없으면 prefs도 동기화 (OS가 서비스 kill 시 onDestroy 미호출 대비)
                val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
                if (prefs.getBoolean("service_running", false)) {
                    prefs.edit().putBoolean("service_running", false).apply()
                }
                return false
            }
        }
        val prefs = getSharedPreferences("lock_screen_prefs", MODE_PRIVATE)
        return prefs.getBoolean("service_running", false)
    }
}
