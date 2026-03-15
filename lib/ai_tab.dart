import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'local_gemma_brain.dart';

enum _VoiceState { idle, listening, thinking, speaking }

class AITab extends StatefulWidget {
  const AITab({super.key});

  @override
  State<AITab> createState() => _AITabState();
}

class _AITabState extends State<AITab> {
  static const String _geminiModel = 'gemini-2.5-flash';
  static const String _geminiApiKey = String.fromEnvironment(
    'GEMINI_API_KEY',
    defaultValue: '',
  );

  final SpeechToText _speech = SpeechToText();
  bool _speechAvailable = false;

  _VoiceState _state = _VoiceState.idle;
  String _recognizedWords = '';
  String _overlayText = '';

  // Throttle: track last successful Gemini call time
  DateTime? _lastGeminiCall;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize(
      onError: (e) => debugPrint('STT error: $e'),
      onStatus: (s) => debugPrint('STT status: $s'),
    );
  }

  // ─── Main button handler ─────────────────────────────────────────────────

  Future<void> _onTalkPressed() async {
    // Tap while active → cancel everything and go idle
    if (_state != _VoiceState.idle) {
      await _speech.cancel();
      await LocalGemmaBrain().stopSpeaking();
      if (mounted) {
        setState(() {
          _state = _VoiceState.idle;
          _overlayText = '';
          _recognizedWords = '';
        });
      }
      return;
    }

    // Request mic permission
    if (!await Permission.microphone.request().isGranted) {
      _showOverlay('Microphone permission denied.');
      return;
    }

    // Ensure STT is initialised
    if (!_speechAvailable) {
      _speechAvailable = await _speech.initialize();
      if (!_speechAvailable) {
        _showOverlay('Speech recognition not available on this device.');
        return;
      }
    }

    setState(() {
      _state = _VoiceState.listening;
      _recognizedWords = '';
      _overlayText = 'Listening...';
    });

    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() => _recognizedWords = result.recognizedWords);
        if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
          _onSpeechFinal(result.recognizedWords.trim());
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
    );
  }

  // ─── After STT finalises ─────────────────────────────────────────────────

  Future<void> _onSpeechFinal(String text) async {
    if (!mounted) return;

    // Enforce minimum 5-second gap between Gemini calls
    if (_lastGeminiCall != null) {
      final elapsed = DateTime.now().difference(_lastGeminiCall!);
      if (elapsed.inSeconds < 5) {
        final wait = 5 - elapsed.inSeconds;
        for (int i = wait; i > 0; i--) {
          if (!mounted) return;
          setState(() {
            _state = _VoiceState.thinking;
            _overlayText = 'Please wait $i s...';
          });
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }

    setState(() {
      _state = _VoiceState.thinking;
      _overlayText = 'Thinking...';
    });

    String reply;
    try {
      reply = await _callGemini(text);
      _lastGeminiCall = DateTime.now();
    } catch (e) {
      // Show error visually — do NOT speak it
      if (mounted) {
        setState(() {
          _state = _VoiceState.idle;
          _overlayText = 'Could not reach Gemini. Try again in a moment.';
        });
        await Future<void>.delayed(const Duration(seconds: 3));
        if (mounted) setState(() => _overlayText = '');
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _state = _VoiceState.speaking;
      _overlayText = reply;
    });

    await LocalGemmaBrain().speakText(reply);

    if (!mounted) return;
    setState(() {
      _state = _VoiceState.idle;
      _overlayText = '';
      _recognizedWords = '';
    });
  }

  // ─── Gemini REST call ────────────────────────────────────────────────────

  Future<String> _callGemini(String userText, {int attempt = 1}) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        '$_geminiModel:generateContent?key=$_geminiApiKey',
      );
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': userText},
              ],
            },
          ],
        }),
      );

      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      debugPrint('🌐 Gemini status: ${response.statusCode}');

      if (response.statusCode == 429) {
        debugPrint('⏳ 429 body: $body');
        if (attempt > 4)
          throw Exception('Rate limited after $attempt attempts.');
        // Exponential back-off: 10s, 20s, 30s, 40s
        final wait = attempt * 10;
        client.close(force: true);
        for (int i = wait; i > 0; i--) {
          if (!mounted) throw Exception('Widget disposed during retry.');
          setState(() => _overlayText = 'Rate limited, retrying in ${i}s...');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        return _callGemini(userText, attempt: attempt + 1);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('❌ Gemini error body: $body');
        throw Exception('HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final parts =
          (decoded['candidates'] as List?)?.first['content']['parts'] as List?;
      return parts?.first['text']?.toString().trim() ??
          'No response from Gemini.';
    } finally {
      client.close(force: true);
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  void _showOverlay(String msg) {
    if (!mounted) return;
    setState(() => _overlayText = msg);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _state == _VoiceState.idle) {
        setState(() => _overlayText = '');
      }
    });
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isActive = _state != _VoiceState.idle;

    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          // Background
          if (isActive)
            Image.asset('lib/public/download.gif', fit: BoxFit.cover)
          else
            Container(color: Colors.white),

          // TALK button (idle)
          if (!isActive)
            Center(
              child: ElevatedButton.icon(
                onPressed: _onTalkPressed,
                icon: const Icon(Icons.mic_none_rounded, size: 32),
                label: Text(
                  'TALK',
                  style: GoogleFonts.poppins(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 3.0,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade600,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: 20,
                  ),
                  elevation: 8,
                  shadowColor: Colors.blue.shade200,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(40),
                  ),
                ),
              ),
            ),

          // Text overlay (active)
          if (isActive)
            Positioned(
              top: 24,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Live partial STT words
                    if (_state == _VoiceState.listening &&
                        _recognizedWords.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          _recognizedWords,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.plusJakartaSans(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    Text(
                      _overlayText,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // State badge (active)
          if (isActive)
            Positioned(
              top: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _StateBadge(state: _state),
              ),
            ),

          // Stop button (active)
          if (isActive)
            Positioned(
              bottom: 100,
              child: IconButton(
                onPressed: _onTalkPressed,
                icon: const Icon(
                  Icons.stop_circle_outlined,
                  size: 50,
                  color: Colors.white70,
                ),
                tooltip: 'Stop',
              ),
            ),
        ],
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});
  final _VoiceState state;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      _VoiceState.listening => (Colors.red, 'REC'),
      _VoiceState.thinking => (Colors.amber, 'AI'),
      _VoiceState.speaking => (Colors.green, 'TTS'),
      _VoiceState.idle => (Colors.grey, ''),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
