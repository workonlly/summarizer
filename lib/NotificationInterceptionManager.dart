import 'dart:async';
import 'package:flutter/services.dart';

class NotificationData {
  final String? packageName;
  final String? title;
  final String? content;
  final bool isDemo;
  final DateTime timestamp;

  NotificationData({
    required this.packageName,
    required this.title,
    required this.content,
    this.isDemo = false,
  }) : timestamp = DateTime.now();

  NotificationData.withTimestamp({
    required this.packageName,
    required this.title,
    required this.content,
    required this.timestamp,
    this.isDemo = false,
  });

  @override
  String toString() => '[$packageName] $title: $content';
}

class NotificationInterceptionManager {
  static final NotificationInterceptionManager _instance =
      NotificationInterceptionManager._internal();

  factory NotificationInterceptionManager() => _instance;
  NotificationInterceptionManager._internal();

  bool _isListening = false;
  final StreamController<NotificationData> _notificationStream =
      StreamController.broadcast();
  static const EventChannel _eventChannel = EventChannel(
    'summarizer/notification_events',
  );
  static const MethodChannel _methodChannel = MethodChannel(
    'summarizer/notification_bridge',
  );
  StreamSubscription<dynamic>? _nativeEventSubscription;

  Stream<NotificationData> get notificationStream => _notificationStream.stream;

  Future<void> startListening() async {
    if (_isListening) {
      print("⚠️ Notification listener already active");
      return;
    }
    _isListening = true;

    print("🎧 Notification Listener started");
    print("👀 Waiting for real notification payloads from platform bridge.");

    await _bindNativeBridge();
    _simulateNotificationStream();
  }

  void _simulateNotificationStream() {
    print("📡 Interception pipeline initialized (bridge pending).");
  }

  Future<void> _bindNativeBridge() async {
    await _nativeEventSubscription?.cancel();
    _nativeEventSubscription = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final packageName = event['packageName']?.toString();
        final title = event['title']?.toString();
        final content = event['content']?.toString();
        final isDemo = event['isDemo'] == true;
        final postedAt = _toMillis(event['postedAt']);
        receiveNotification(
          packageName,
          title,
          content,
          isDemo: isDemo,
          timestamp: postedAt != null
              ? DateTime.fromMillisecondsSinceEpoch(postedAt)
              : null,
        );
      },
      onError: (Object error) {
        print('❌ Native notification stream error: $error');
      },
    );
  }

  Future<bool> isNotificationAccessGranted() async {
    try {
      final granted = await _methodChannel.invokeMethod<bool>(
        'isNotificationAccessGranted',
      );
      return granted ?? false;
    } catch (e) {
      print('❌ Failed to check notification access: $e');
      return false;
    }
  }

  Future<void> openNotificationAccessSettings() async {
    try {
      await _methodChannel.invokeMethod('openNotificationAccessSettings');
    } catch (e) {
      print('❌ Failed to open notification access settings: $e');
    }
  }

  Future<List<NotificationData>> getTodayStoredNotifications() async {
    try {
      final raw = await _methodChannel.invokeMethod<List<dynamic>>(
        'getTodayStoredNotifications',
      );
      if (raw == null) return <NotificationData>[];

      return raw.whereType<Object?>().map((entry) {
        if (entry is! Map) {
          return NotificationData(
            packageName: 'unknown',
            title: 'Notification',
            content: '',
            isDemo: false,
          );
        }
        final postedAt = _toMillis(entry['postedAt']);
        return NotificationData.withTimestamp(
          packageName: entry['packageName']?.toString(),
          title: entry['title']?.toString(),
          content: entry['content']?.toString(),
          isDemo: entry['isDemo'] == true,
          timestamp: postedAt != null
              ? DateTime.fromMillisecondsSinceEpoch(postedAt)
              : DateTime.now(),
        );
      }).toList();
    } catch (e) {
      print('❌ Failed to load today stored notifications: $e');
      return <NotificationData>[];
    }
  }

  Future<List<String>> getAvailableStoredDays() async {
    try {
      final raw = await _methodChannel.invokeMethod<List<dynamic>>(
        'getAvailableNotificationDays',
      );
      if (raw == null) return <String>[];
      return raw.map((e) => e.toString()).toList();
    } catch (e) {
      print('❌ Failed to load available notification days: $e');
      return <String>[];
    }
  }

  Future<List<NotificationData>> getStoredNotificationsForDay(
    String dayKey,
  ) async {
    try {
      final raw = await _methodChannel.invokeMethod<List<dynamic>>(
        'getStoredNotificationsForDay',
        {'dayKey': dayKey},
      );
      if (raw == null) return <NotificationData>[];

      return raw.whereType<Object?>().map((entry) {
        if (entry is! Map) {
          return NotificationData(
            packageName: 'unknown',
            title: 'Notification',
            content: '',
          );
        }
        final postedAt = _toMillis(entry['postedAt']);
        return NotificationData.withTimestamp(
          packageName: entry['packageName']?.toString(),
          title: entry['title']?.toString(),
          content: entry['content']?.toString(),
          isDemo: entry['isDemo'] == true,
          timestamp: postedAt != null
              ? DateTime.fromMillisecondsSinceEpoch(postedAt)
              : DateTime.now(),
        );
      }).toList();
    } catch (e) {
      print('❌ Failed to load notifications for $dayKey: $e');
      return <NotificationData>[];
    }
  }

  /// Add a notification to the stream (for testing or actual reception)
  void receiveNotification(
    String? packageName,
    String? title,
    String? content, {
    bool isDemo = false,
    DateTime? timestamp,
  }) {
    if (!_isListening) return;

    final notification = timestamp == null
        ? NotificationData(
            packageName: packageName,
            title: title,
            content: content,
            isDemo: isDemo,
          )
        : NotificationData.withTimestamp(
            packageName: packageName,
            title: title,
            content: content,
            timestamp: timestamp,
            isDemo: isDemo,
          );

    final demoTag = isDemo ? " [DEMO]" : "";
    print("\n🔔$demoTag [$packageName] Notification Received");
    print("📝 Title: $title");
    print("📝 Content: $content");
    print("---");

    if (_isImportantApp(packageName ?? "")) {
      print("⭐ IMPORTANT APP DETECTED!");
      _sendToGeminiForSummary(title ?? "", content ?? "");
    }

    _notificationStream.add(notification);
  }

  void pushDemoNotification(String packageName, String title, String content) {
    receiveNotification(packageName, title, content, isDemo: true);
  }

  int? _toMillis(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  bool _isImportantApp(String pkg) {
    // Filter for the apps you actually care about
    List<String> importantApps = [
      "com.discord",
      "com.google.android.gm", // Gmail
      "in.zomato.android", // Zomato
      "com.whatsapp",
      "com.telegram",
      "com.instagram.android",
    ];
    return importantApps.any((element) => pkg.contains(element));
  }

  Future<void> _sendToGeminiForSummary(String title, String body) async {
    print("🚀 [Gemini Integration] Processing notification");
    print("📝 Title: $title");
    print("📝 Body: $body");
    print("⏳ Waiting for AI summary...");

    // TODO: Integrate with actual Gemini/LocalGemmaBrain
    await Future.delayed(Duration(milliseconds: 500));
    print("✅ Summary processed and logged");
  }

  void stopListening() {
    _isListening = false;
    _nativeEventSubscription?.cancel();
    _nativeEventSubscription = null;
    print("🔌 Notification Listener stopped");
  }

  void dispose() {
    stopListening();
    _notificationStream.close();
  }
}
