import 'dart:async';

import 'package:flutter/material.dart';
import 'history.dart';
import 'notification_manager.dart';
import 'NotificationInterceptionManager.dart';
import 'summary_engine.dart';
import 'snowflake_system.dart';

class SummaryTab extends StatefulWidget {
  const SummaryTab({super.key});

  @override
  State<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<SummaryTab> {
  // 🟢 1. Listener is active by default
  bool _isListenerActive = true;
  final List<NotificationData> _receivedNotifications = [];
  bool _hasNotificationAccess = false;
  int _storedDaysCount = 0;
  DateTime? _lastBackgroundSyncAt;
  late NotificationInterceptionManager _interceptionManager;

  // AI Daily Summary state
  bool _summaryLoading = false;
  String _summaryResult = '';
  String _summaryStep = '';
  DateTime? _summarySavedAt;
  final SummaryEngine _summaryEngine = SummaryEngine();
  StreamSubscription<NotificationData>? _notificationSub;
  final Map<String, Timer> _appSummaryDebounce = {};
  final Set<String> _appSummaryInFlight = <String>{};
  Map<String, String> _liveAppSummaries = <String, String>{};

  @override
  void initState() {
    super.initState();
    // Get the interception manager from NotificationManager singleton
    _interceptionManager = NotificationManager().interceptionManager;
    _refreshAccessState();
    _loadTodayNotifications();
    _loadCachedSummary();
    _loadCachedAppSummaries();

    // Listen to incoming notifications
    _notificationSub = _interceptionManager.notificationStream.listen((
      notification,
    ) {
      if (mounted) {
        setState(() {
          if (_receivedNotifications.any(
            (existing) =>
                _notificationKey(existing) == _notificationKey(notification),
          )) {
            return;
          }
          _receivedNotifications.insert(0, notification); // Add to top of list
          if (_receivedNotifications.length > 20) {
            _receivedNotifications.removeLast(); // Keep only last 20
          }
        });

        _scheduleAppSummaryUpdate(notification.packageName ?? 'unknown');
      }
    });
  }

  @override
  void dispose() {
    _notificationSub?.cancel();
    for (final timer in _appSummaryDebounce.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _loadTodayNotifications() async {
    final storedToday = await _interceptionManager
        .getTodayStoredNotifications();
    final days = await _interceptionManager.getAvailableStoredDays();
    if (!mounted) return;

    storedToday.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    setState(() {
      _storedDaysCount = days.length;
      _lastBackgroundSyncAt = storedToday.isNotEmpty
          ? storedToday.first.timestamp
          : null;
      _receivedNotifications
        ..clear()
        ..addAll(storedToday.take(50));
    });

    _scheduleAllEligibleAppSummaries();
  }

  String _notificationKey(NotificationData item) {
    final pkg = item.packageName ?? '';
    final title = item.title ?? '';
    final content = item.content ?? '';
    final stamp = item.timestamp.millisecondsSinceEpoch;
    return '$pkg|$title|$content|$stamp';
  }

  Future<void> _loadCachedSummary() async {
    final cached = await SnowflakeSystem.loadCached();
    if (cached != null && mounted) {
      setState(() {
        _summaryResult = cached.text;
        _summarySavedAt = cached.savedAt;
      });
    }
  }

  Future<void> _loadCachedAppSummaries() async {
    final cached = await _summaryEngine.loadCachedAppSummaries();
    if (!mounted || cached.isEmpty) return;
    setState(() {
      _liveAppSummaries = cached;
    });
  }

  void _scheduleAllEligibleAppSummaries() {
    final packages = _receivedNotifications
        .map((n) => n.packageName ?? 'unknown')
        .toSet();
    for (final pkg in packages) {
      _scheduleAppSummaryUpdate(pkg);
    }
  }

  void _scheduleAppSummaryUpdate(String packageName) {
    _appSummaryDebounce[packageName]?.cancel();
    _appSummaryDebounce[packageName] = Timer(
      const Duration(milliseconds: 900),
      () => _updateSingleAppSummary(packageName),
    );
  }

  List<NotificationData> _notificationsForPackage(String packageName) {
    return _receivedNotifications
        .where((n) => (n.packageName ?? 'unknown') == packageName)
        .toList();
  }

  bool _shouldGenerateSummary(
    String packageName,
    List<NotificationData> appNotifications,
  ) {
    if (appNotifications.isEmpty) return false;

    final lowerPkg = packageName.toLowerCase();
    if (lowerPkg.contains('whatsapp')) {
      final senders = appNotifications
          .map((n) => _extractSenderIdentity(n))
          .where((s) => s.isNotEmpty)
          .toSet();
      return senders.length >= 3;
    }

    return appNotifications.length >= 3;
  }

  String _extractSenderIdentity(NotificationData item) {
    final title = (item.title ?? '').trim();
    if (title.isNotEmpty) return title.toLowerCase();

    final content = (item.content ?? '').trim();
    if (content.contains(':')) {
      return content.split(':').first.trim().toLowerCase();
    }
    return content.toLowerCase();
  }

  Future<void> _updateSingleAppSummary(String packageName) async {
    if (_appSummaryInFlight.contains(packageName)) return;

    final appNotifications = _notificationsForPackage(packageName);
    if (!_shouldGenerateSummary(packageName, appNotifications)) return;

    _appSummaryInFlight.add(packageName);
    try {
      final appName = _summaryEngine.friendlyNameForPackage(packageName);
      final previous = _liveAppSummaries[packageName] ?? '';
      final updated = await _summaryEngine.buildIncrementalAppSummary(
        appName: appName,
        notifications: appNotifications,
        previousSummary: previous,
      );

      if (!mounted) return;
      setState(() {
        _liveAppSummaries[packageName] = updated;
      });
      await _summaryEngine.saveCachedAppSummaries(_liveAppSummaries);
    } catch (_) {
      // Keep the UI stable if one app summary fails.
    } finally {
      _appSummaryInFlight.remove(packageName);
    }
  }

  Future<void> _runSummaryPipeline() async {
    setState(() {
      _summaryLoading = true;
      _summaryResult = '';
      _summaryStep = 'Loading notifications…';
    });

    try {
      // Use today's stored notifications if the live list is thin
      List<NotificationData> source = _receivedNotifications;
      if (source.isEmpty) {
        source = await _interceptionManager.getTodayStoredNotifications();
      }

      final engine = SummaryEngine(
        onProgress: (step) {
          if (mounted) setState(() => _summaryStep = step);
        },
      );

      final result = await engine.generateDailySummary(source);
      if (mounted) {
        setState(() {
          _summaryResult = result;
          _summarySavedAt = DateTime.now();
          _summaryLoading = false;
          _summaryStep = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _summaryResult = 'Error: $e';
          _summaryLoading = false;
          _summaryStep = '';
        });
      }
    }
  }

  Future<void> _refreshAccessState() async {
    final granted = await _interceptionManager.isNotificationAccessGranted();
    if (!mounted) return;
    setState(() {
      _hasNotificationAccess = granted;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. The Dynamic Notification Service Status Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              // Changes from Blue to Grey when turned off
              gradient: LinearGradient(
                colors: _isListenerActive
                    ? [Colors.blue.shade700, Colors.blue.shade500]
                    : [Colors.blueGrey.shade600, Colors.blueGrey.shade400],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: _isListenerActive
                      ? Colors.blue.shade200
                      : Colors.blueGrey.shade200,
                  blurRadius: 15,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                // 🟢 2. The Green Signal / Bell Icon Logic
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: (_isListenerActive && _hasNotificationAccess)
                      ? Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.greenAccent.shade400,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.greenAccent.withOpacity(0.8),
                                blurRadius: 12,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                        )
                      : Icon(
                          _isListenerActive
                              ? Icons
                                    .error_outline // Active but no access
                              : Icons.notifications_off, // Paused
                          color: Colors.white,
                          size: 28,
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isListenerActive
                            ? 'Listener Active'
                            : 'Listener Paused',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isListenerActive
                            ? (_hasNotificationAccess
                                  ? 'Native bridge connected. Receiving real app notifications.'
                                  : 'Listener on, but Notification Access is still disabled.')
                            : 'Not collecting data right now.',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isListenerActive,
                  onChanged: (val) {
                    setState(() {
                      _isListenerActive = val;
                    });
                    if (val) {
                      _refreshAccessState();
                    }
                  },
                  activeColor: Colors.white,
                  activeTrackColor: Colors.green.shade400,
                  inactiveThumbColor: Colors.white,
                  inactiveTrackColor: Colors.blueGrey.shade800,
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),

          // 2. The Conditional Logic (If ON show data, else show offline message)
          if (_isListenerActive) ...[
            // --- HEADER ROW: Status Dot + Title + History Button ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    // Small Status Indicator Dot next to Title
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _hasNotificationAccess
                            ? Colors.green.shade500
                            : Colors.red.shade500,
                        boxShadow: [
                          BoxShadow(
                            color:
                                (_hasNotificationAccess
                                        ? Colors.green.shade500
                                        : Colors.red.shade500)
                                    .withOpacity(0.4),
                            blurRadius: 6,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      "Live Notifications",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey.shade900,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const HistoryScreen(),
                      ),
                    );
                  },
                  icon: Icon(
                    Icons.history_rounded,
                    size: 18,
                    color: Colors.blue.shade700,
                  ),
                  label: Text(
                    'History',
                    style: TextStyle(
                      color: Colors.blue.shade700,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.blue.shade50,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _lastBackgroundSyncAt == null
                  ? 'Last synced from background: no stored records yet'
                  : 'Last synced from background: ${_formatStamp(_lastBackgroundSyncAt!)}',
              style: TextStyle(
                color: Colors.blueGrey.shade500,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),

            // Show settings button if access is not granted
            if (!_hasNotificationAccess) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await _interceptionManager.openNotificationAccessSettings();
                    await Future.delayed(const Duration(milliseconds: 500));
                    await _refreshAccessState();
                  },
                  icon: const Icon(Icons.settings, color: Colors.redAccent),
                  label: const Text(
                    'Grant Notification Access',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 🤖 AI DAILY SUMMARY BOX
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.indigo.shade100),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        color: Colors.indigo.shade500,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "Daily Summary",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo.shade900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "Your AI-generated summary will appear here once we collect enough notifications .",
                    style: TextStyle(
                      color: Colors.indigo.shade700,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Stored day folders: $_storedDaysCount',
                    style: TextStyle(
                      color: Colors.indigo.shade400,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // ── Generate button ────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _summaryLoading ? null : _runSummaryPipeline,
                      icon: _summaryLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.auto_awesome, size: 18),
                      label: Text(
                        _summaryLoading
                            ? (_summaryStep.isEmpty
                                  ? 'Processing…'
                                  : _summaryStep)
                            : 'Generate AI Daily Summary',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  // ── Result ────────────────────────────────────────────
                  if (_summaryResult.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    Text(
                      '🧠 Snowflake Cortex Insight',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.indigo.shade400,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (_summarySavedAt != null)
                      Text(
                        'Last updated: ${_formatStamp(_summarySavedAt!)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.indigo.shade300,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      _summaryResult,
                      style: TextStyle(
                        color: Colors.indigo.shade900,
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 14),
                  if (_liveAppSummaries.isEmpty)
                    Text(
                      'Live app summaries will appear here. For WhatsApp, '
                      'at least 3 different senders are required.',
                      style: TextStyle(
                        color: Colors.indigo.shade400,
                        fontSize: 12,
                      ),
                    )
                  else
                    ..._liveAppSummaries.entries.map((entry) {
                      final pkg = entry.key;
                      final appName = _summaryEngine.friendlyNameForPackage(
                        pkg,
                      );
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _buildAppSummaryTile(
                          color: _getColorForPackage(pkg),
                          icon: _getIconForPackage(pkg),
                          appName: appName,
                          summary: entry.value,
                        ),
                      );
                    }),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // --- NOTIFICATION FEED ---
            if (_receivedNotifications.isEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.notifications_none_rounded,
                        size: 48,
                        color: Colors.blueGrey.shade200,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "Waiting for notifications...",
                        style: TextStyle(
                          color: Colors.blueGrey.shade500,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              ..._receivedNotifications.map((notif) {
                final icon = _getIconForPackage(notif.packageName ?? "");
                final color = _getColorForPackage(notif.packageName ?? "");
                return _buildNotificationCard(
                  notif.packageName ?? "Unknown",
                  notif.title ?? "Notification",
                  notif.content ?? "",
                  icon,
                  color,
                  notif.timestamp,
                );
              }),
            ],
          ] else ...[
            // --- SHOW OFFLINE MESSAGE WHEN OFF ---
            Padding(
              padding: const EdgeInsets.only(top: 40.0),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 60,
                      color: Colors.blueGrey.shade200,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      "Data is Hidden",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey.shade700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Toggle the listener above to resume monitoring and view today's insights.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.blueGrey.shade500),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAppSummaryTile({
    required Color color,
    required IconData icon,
    required String appName,
    required String summary,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appName,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                summary,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.indigo.shade800,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNotificationCard(
    String packageName,
    String title,
    String content,
    IconData icon,
    Color color,
    DateTime timestamp,
  ) {
    final timeAgo = _getTimeAgo(timestamp);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withOpacity(0.1),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.blueGrey.shade900,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timeAgo,
                      style: TextStyle(
                        color: Colors.blueGrey.shade400,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  packageName,
                  style: TextStyle(
                    color: Colors.blueGrey.shade400,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  content,
                  style: TextStyle(
                    color: Colors.blueGrey.shade600,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getIconForPackage(String packageName) {
    if (packageName.contains('discord')) return Icons.chat_bubble_outline;
    if (packageName.contains('gmail')) return Icons.mail_outline;
    if (packageName.contains('zomato')) return Icons.restaurant_menu;
    if (packageName.contains('instagram')) return Icons.photo_camera;
    if (packageName.contains('whatsapp')) return Icons.message;
    if (packageName.contains('telegram')) return Icons.send;
    return Icons.notifications_active;
  }

  Color _getColorForPackage(String packageName) {
    if (packageName.contains('discord')) return Colors.purple.shade500;
    if (packageName.contains('gmail')) return Colors.red.shade500;
    if (packageName.contains('zomato')) return Colors.orange.shade500;
    if (packageName.contains('instagram')) return Colors.pink.shade500;
    if (packageName.contains('whatsapp')) return Colors.green.shade500;
    if (packageName.contains('telegram')) return Colors.blue.shade500;
    return Colors.blueGrey.shade500;
  }

  String _getTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _formatStamp(DateTime dt) {
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$month-$day $hour:$minute';
  }
}
