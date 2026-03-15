import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'NotificationInterceptionManager.dart';

class NotificationManager {
  static final NotificationManager _instance = NotificationManager._internal();
  factory NotificationManager() => _instance;
  NotificationManager._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  late NotificationInterceptionManager _interceptionManager;

  Future<void> init() async {
    // Android Settings
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // Combine Settings
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        print("🔔 Notification Clicked: ${details.payload}");
      },
    );

    // 🟢 Initialize the Notification Interception System
    _interceptionManager = NotificationInterceptionManager();
    await _interceptionManager.startListening();
    print("✅ Notification Interception Manager initialized");
  }

  /// Explicit demo feed for UI testing only.
  void runDemoFeed() {
    Future.delayed(const Duration(seconds: 1), () {
      _interceptionManager.pushDemoNotification(
        "com.google.android.gm",
        "Gmail",
        "[Demo] Meeting reminder: Project sync at 3 PM",
      );
    });
    Future.delayed(const Duration(seconds: 2), () {
      _interceptionManager.pushDemoNotification(
        "in.zomato.android",
        "Zomato",
        "[Demo] Your order is 15 minutes away",
      );
    });
  }

  /// Access the interception manager to process notification streams
  NotificationInterceptionManager get interceptionManager =>
      _interceptionManager;

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    // 🟢 Console Log
    print("DEBUG_NOTIFICATION: id=$id, title='$title', body='$body'");

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'summarizer_channel',
          'AI Note Updates',
          channelDescription:
              'Notifications for Gemini and Snowflake sync tasks',
          importance: Importance.max,
          priority: Priority.high,
        );

    const NotificationDetails platformDetails = NotificationDetails(
      android: androidDetails,
    );
    await _notificationsPlugin.show(
      id,
      title,
      body,
      platformDetails,
      payload: payload,
    );
  }
}
