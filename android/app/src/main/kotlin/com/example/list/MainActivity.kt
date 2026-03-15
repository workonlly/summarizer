package com.example.list

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val eventChannelName = "summarizer/notification_events"
	private val methodChannelName = "summarizer/notification_bridge"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					AppNotificationListenerService.setEventSink(events)
				}

				override fun onCancel(arguments: Any?) {
					AppNotificationListenerService.setEventSink(null)
				}
			})

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"openNotificationAccessSettings" -> {
						startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
						result.success(true)
					}
					"isNotificationAccessGranted" -> {
						result.success(AppNotificationListenerService.isNotificationAccessGranted(this))
					}
					"getTodayStoredNotifications" -> {
						result.success(AppNotificationListenerService.getTodayNotifications(this))
					}
					"getAvailableNotificationDays" -> {
						result.success(AppNotificationListenerService.getAvailableDays(this))
					}
					"getStoredNotificationsForDay" -> {
						val dayKey = call.argument<String>("dayKey")
						if (dayKey.isNullOrBlank()) {
							result.success(emptyList<Map<String, Any?>>())
						} else {
							result.success(
								AppNotificationListenerService.getNotificationsForDay(this, dayKey)
							)
						}
					}
					else -> result.notImplemented()
				}
			}
	}
}
