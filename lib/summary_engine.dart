import 'dart:convert';
import 'dart:io';

import 'NotificationInterceptionManager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'snowflake_system.dart';

/// Full pipeline:
///   Stored notifications
///     → group by app
///     → Gemini per-app summary
///     → build combined context prompt
///     → Snowflake Cortex for final daily insight
class SummaryEngine {
  // ── Gemini ──────────────────────────────────────────────────────────────
  static const String _geminiModel = 'gemini-2.0-flash-lite';
  static const String _geminiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: '',
  );

  // Progress callback so the UI can show step-by-step updates
  final void Function(String step)? onProgress;
  static const String _appSummaryCacheKey = 'live_app_summaries_v1';

  SummaryEngine({this.onProgress});

  // ── Entry point ──────────────────────────────────────────────────────────

  Future<String> generateDailySummary(
    List<NotificationData> notifications,
  ) async {
    if (notifications.isEmpty) return 'No notifications found for today.';

    // 1. Group by package name
    final grouped = <String, List<NotificationData>>{};
    for (final n in notifications) {
      final pkg = _friendlyName(n.packageName ?? 'unknown');
      grouped.putIfAbsent(pkg, () => []).add(n);
    }

    // 2. Per-app Gemini summaries
    final appSummaries = <String>[];
    for (final entry in grouped.entries) {
      onProgress?.call('Summarising ${entry.key}…');
      final summary = await _summariseApp(entry.key, entry.value);
      appSummaries.add('📱 ${entry.key}:\n$summary');
    }

    // 3. Build context prompt for Snowflake
    onProgress?.call('Building context for Snowflake…');
    final contextPrompt = _buildContextPrompt(appSummaries);

    // 4. Delegate to SnowflakeSystem — it calls Cortex and saves to SharedPrefs
    onProgress?.call('Sending to Snowflake Cortex…');
    final insight = await SnowflakeSystem().runAndSave(contextPrompt);

    return insight;
  }

  Future<String> buildIncrementalAppSummary({
    required String appName,
    required List<NotificationData> notifications,
    String previousSummary = '',
  }) async {
    final messages = notifications
        .take(30)
        .map((n) {
          final title = (n.title ?? '').trim();
          final content = (n.content ?? '').trim();
          return title.isNotEmpty ? '• $title: $content' : '• $content';
        })
        .join('\n');

    final historyBlock = previousSummary.trim().isEmpty
        ? 'No previous summary.'
        : previousSummary.trim();

    final prompt =
        'You are updating an app activity summary for "$appName".\n\n'
        'Previous summary:\n$historyBlock\n\n'
        'New notifications:\n$messages\n\n'
        'Return an updated summary in 2-3 lines. Merge old context with new '
        'events. Mention people names if present and highlight important '
        'follow-ups.';

    return _callGemini(prompt);
  }

  Future<Map<String, String>> loadCachedAppSummaries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_appSummaryCacheKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> saveCachedAppSummaries(Map<String, String> summaries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appSummaryCacheKey, jsonEncode(summaries));
  }

  // ── Step 1 – Gemini per-app summary ─────────────────────────────────────

  Future<String> _summariseApp(
    String appName,
    List<NotificationData> notifications,
  ) async {
    final messages = notifications
        .take(30)
        .map((n) {
          final title = (n.title ?? '').trim();
          final content = (n.content ?? '').trim();
          return title.isNotEmpty ? '• $title: $content' : '• $content';
        })
        .join('\n');

    final prompt =
        'Summarise the following notifications from "$appName" in 1–2 clear '
        'sentences. Focus on who messaged and any important actions needed.\n\n'
        'Notifications:\n$messages';

    return _callGemini(prompt);
  }

  // ── Step 2 – build context prompt ───────────────────────────────────────

  String _buildContextPrompt(List<String> appSummaries) {
    return '''You are a personal AI assistant analyzing a user's daily notification activity.

Here are summaries of each app's activity today:

${appSummaries.join('\n\n')}

Based on this, provide a concise daily insight (3–5 sentences) covering:
- Key messages the user should respond to
- Important social or professional activity
- Any tasks or follow-ups that seem urgent''';
  }

  // ── Gemini HTTP helper ───────────────────────────────────────────────────

  Future<String> _callGemini(String prompt, {int attempt = 1}) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$_geminiModel:generateContent?key=$_geminiKey',
      );
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': prompt},
              ],
            },
          ],
        }),
      );

      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();

      if (res.statusCode == 429) {
        if (attempt > 3) return '[Gemini rate limited]';
        await Future<void>.delayed(Duration(seconds: attempt * 8));
        return _callGemini(prompt, attempt: attempt + 1);
      }
      if (res.statusCode != 200) {
        return '[Gemini error ${res.statusCode}]';
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final parts =
          (decoded['candidates'] as List?)?.first['content']['parts'] as List?;
      return parts?.first['text']?.toString().trim() ?? '[No response]';
    } finally {
      client.close(force: true);
    }
  }

  // ── Utility ──────────────────────────────────────────────────────────────

  String _friendlyName(String packageName) {
    const map = {
      'com.whatsapp': 'WhatsApp',
      'com.whatsapp.w4b': 'WhatsApp Business',
      'com.linkedin.android': 'LinkedIn',
      'com.google.android.gm': 'Gmail',
      'com.microsoft.teams': 'Teams',
      'com.slack': 'Slack',
      'com.instagram.android': 'Instagram',
      'com.twitter.android': 'Twitter/X',
      'com.facebook.katana': 'Facebook',
      'com.google.android.apps.messaging': 'Messages',
      'com.telegrammessenger': 'Telegram',
      'org.telegram.messenger': 'Telegram',
    };
    return map[packageName] ?? packageName.split('.').last.replaceAll('_', ' ');
  }

  String friendlyNameForPackage(String packageName) {
    return _friendlyName(packageName);
  }
}
