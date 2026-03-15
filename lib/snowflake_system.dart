import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Handles all Snowflake Cortex communication and caches the last result
/// in local storage so it survives app restarts.
class SnowflakeSystem {
  static const String _account = 'ccrxktj-mi46305';
  static const String _jwt = String.fromEnvironment(
    'SNOWFLAKE_JWT',
    defaultValue: '',
  );

  static const String _prefKey = 'snowflake_daily_summary_v1';
  static const String _prefTimestampKey = 'snowflake_daily_summary_ts_v1';

  /// Send [contextPrompt] to Snowflake Cortex, save the result locally
  /// and return it.
  Future<String> runAndSave(String contextPrompt) async {
    final result = await _callCortex(contextPrompt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, result);
    await prefs.setString(_prefTimestampKey, DateTime.now().toIso8601String());
    return result;
  }

  /// Load the last saved Snowflake result from SharedPrefs.
  /// Returns null if nothing has been saved yet.
  static Future<({String text, DateTime savedAt})?> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(_prefKey);
    final tsRaw = prefs.getString(_prefTimestampKey);
    if (text == null || text.isEmpty) return null;
    final savedAt = tsRaw != null
        ? DateTime.tryParse(tsRaw) ?? DateTime.now()
        : DateTime.now();
    return (text: text, savedAt: savedAt);
  }

  /// Clear the cached result (useful when user wants a fresh run).
  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    await prefs.remove(_prefTimestampKey);
  }

  // ── Snowflake Cortex REST call ──────────────────────────────────────────

  Future<String> _callCortex(String prompt) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'https://$_account.snowflakecomputing.com'
        '/api/v2/cortex/inference:complete',
      );
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_jwt');
      req.headers.set('X-Snowflake-Authorization-Token-Type', 'KEYPAIR_JWT');
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.write(
        jsonEncode({
          'model': 'llama3.1-70b',
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'max_tokens': 512,
        }),
      );

      final res = await req.close();
      final body = await utf8.decoder.bind(res).join();

      if (res.statusCode != 200) {
        throw Exception('Snowflake HTTP ${res.statusCode}: $body');
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        return '[Snowflake returned no choices]';
      }

      final first = choices.first as Map<String, dynamic>;
      // Cortex REST v2 returns choices[].messages (string) or
      // choices[].message.content depending on endpoint version.
      final text =
          first['messages']?.toString() ??
          (first['message'] as Map?)?['content']?.toString() ??
          '[Empty Snowflake response]';

      return text.trim();
    } finally {
      client.close(force: true);
    }
  }
}
