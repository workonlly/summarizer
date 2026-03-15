package com.example.list

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Date

class AppNotificationListenerService : NotificationListenerService() {
    companion object {
        @Volatile
        private var eventSink: EventChannel.EventSink? = null
        private const val STORAGE_DIR = "notifications_by_day"

        fun setEventSink(sink: EventChannel.EventSink?) {
            eventSink = sink
        }

        fun isNotificationAccessGranted(context: Context): Boolean {
            val enabledListeners = Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ) ?: return false

            val componentName = ComponentName(context, AppNotificationListenerService::class.java)
            return enabledListeners.contains(componentName.flattenToString()) ||
                enabledListeners.contains(componentName.flattenToShortString())
        }

        fun getTodayNotifications(context: Context): List<Map<String, Any?>> {
            val dayKey = getDayKey(System.currentTimeMillis())
            return readNotificationsForDay(context, dayKey)
        }

        fun getNotificationsForDay(
            context: Context,
            dayKey: String,
        ): List<Map<String, Any?>> {
            return readNotificationsForDay(context, dayKey)
        }

        fun getAvailableDays(context: Context): List<String> {
            val dir = File(context.filesDir, STORAGE_DIR)
            if (!dir.exists() || !dir.isDirectory) return emptyList()

            return dir.listFiles()
                ?.filter { it.isFile && it.name.endsWith(".json") }
                ?.map { it.nameWithoutExtension }
                ?.sortedDescending()
                ?: emptyList()
        }

        private fun getDayKey(timestampMillis: Long): String {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val zone = ZoneId.systemDefault()
                val date = Instant.ofEpochMilli(timestampMillis).atZone(zone).toLocalDate()
                date.format(DateTimeFormatter.ISO_LOCAL_DATE)
            } else {
                @Suppress("DEPRECATION")
                val date = Date(timestampMillis)
                val year = date.year + 1900
                val month = (date.month + 1).toString().padStart(2, '0')
                val day = date.date.toString().padStart(2, '0')
                "$year-$month-$day"
            }
        }

        private fun getDayFile(context: Context, dayKey: String): File {
            val dir = File(context.filesDir, STORAGE_DIR)
            if (!dir.exists()) {
                dir.mkdirs()
            }
            return File(dir, "$dayKey.json")
        }

        private fun readNotificationsForDay(context: Context, dayKey: String): List<Map<String, Any?>> {
            return try {
                val file = getDayFile(context, dayKey)
                if (!file.exists()) return emptyList()

                val content = file.readText()
                if (content.isBlank()) return emptyList()

                val array = JSONArray(content)
                val result = mutableListOf<Map<String, Any?>>()
                for (i in 0 until array.length()) {
                    val obj = array.optJSONObject(i) ?: continue
                    result.add(
                        hashMapOf(
                            "packageName" to obj.optString("packageName", ""),
                            "title" to obj.optString("title", ""),
                            "content" to obj.optString("content", ""),
                            "postedAt" to if (obj.has("postedAt")) obj.optLong("postedAt") else 0L,
                            "isDemo" to obj.optBoolean("isDemo", false),
                        )
                    )
                }
                result
            } catch (_: Exception) {
                emptyList()
            }
        }

        private fun persistNotification(context: Context, payload: Map<String, Any?>) {
            try {
                val postedAt = (payload["postedAt"] as? Long) ?: System.currentTimeMillis()
                val dayKey = getDayKey(postedAt)
                val file = getDayFile(context, dayKey)

                val array = if (file.exists() && file.readText().isNotBlank()) {
                    JSONArray(file.readText())
                } else {
                    JSONArray()
                }

                val obj = JSONObject()
                obj.put("packageName", payload["packageName"] ?: "")
                obj.put("title", payload["title"] ?: "")
                obj.put("content", payload["content"] ?: "")
                obj.put("postedAt", postedAt)
                obj.put("isDemo", payload["isDemo"] ?: false)
                array.put(obj)

                file.writeText(array.toString())
            } catch (_: Exception) {
                // Swallow exceptions to avoid crashing notification listener service.
            }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return

        val extras = sbn.notification?.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        var content = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()

        if (content.isNullOrBlank()) {
            content = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
        }

        val payload = hashMapOf<String, Any?>(
            "packageName" to sbn.packageName,
            "title" to title,
            "content" to content,
            "postedAt" to sbn.postTime,
            "isDemo" to false,
        )

        persistNotification(applicationContext, payload)

        Handler(Looper.getMainLooper()).post {
            eventSink?.success(payload)
        }
    }
}
