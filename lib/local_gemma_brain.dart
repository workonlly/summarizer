import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QueueDebugState {
  final int pendingCount;
  final bool isProcessing;
  final String lastAction;
  final int failedCount;

  const QueueDebugState({
    required this.pendingCount,
    required this.isProcessing,
    required this.lastAction,
    required this.failedCount,
  });

  QueueDebugState copyWith({
    int? pendingCount,
    bool? isProcessing,
    String? lastAction,
    int? failedCount,
  }) {
    return QueueDebugState(
      pendingCount: pendingCount ?? this.pendingCount,
      isProcessing: isProcessing ?? this.isProcessing,
      lastAction: lastAction ?? this.lastAction,
      failedCount: failedCount ?? this.failedCount,
    );
  }
}

class LocalGemmaBrain {
  static final LocalGemmaBrain _instance = LocalGemmaBrain._internal();
  factory LocalGemmaBrain() => _instance;
  LocalGemmaBrain._internal();

  InferenceChat? _chat;

  final ValueNotifier<bool> isModelReady = ValueNotifier(false);
  final ValueNotifier<int> downloadProgress = ValueNotifier(0);
  final ValueNotifier<bool> isDownloading = ValueNotifier(false);
  static const String _intentQueueKey = 'voice_intent_queue_v1';
  static const String _failedCountKey = 'voice_intent_failed_count_v1';
  final ValueNotifier<QueueDebugState> queueDebug = ValueNotifier(
    const QueueDebugState(
      pendingCount: 0,
      isProcessing: false,
      lastAction: 'none',
      failedCount: 0,
    ),
  );

  // 🔒 NATIVE LOCK: Ensures serial access to the MediaPipe engine
  bool _isNativeBusy = false;
  bool _isQueueWorkerRunning = false;
  final FlutterTts _tts = FlutterTts();
  Future<bool> Function(Map<String, dynamic> intent)? _intentExecutor;

  /// 1. Initialize & Download Model
  Future<void> initialize() async {
    if (isDownloading.value || isModelReady.value) return;
    isDownloading.value = true;
    print("🚀 Gemma: Initializing startup sequence...");

    try {
      await FileDownloader().configureNotificationForGroup(
        'smart_downloads',
        running: const TaskNotification(
          'SummariZer AI',
          'Downloading Brain... {progress}%',
        ),
        complete: const TaskNotification(
          'AI Ready',
          'Gemma model is now local.',
        ),
        error: const TaskNotification(
          'Download Failed',
          'Please check your connection.',
        ),
        progressBar: true,
      );

      await FlutterGemma.initialize(
        huggingFaceToken: const String.fromEnvironment(
          'HUGGINGFACE_TOKEN',
          defaultValue: '',
        ),
      );

      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromNetwork(
            'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task',
          )
          .withProgress((progress) {
            int currentProgress = progress is double
                ? (progress * 100).toInt()
                : progress.toInt();
            downloadProgress.value = currentProgress;
            print("📥 Download Progress: $currentProgress%");
          })
          .install();

      await _recreateChat();

      isModelReady.value = true;
      isDownloading.value = false;
      print("✅ Gemma: Awake and ready!");
    } catch (e) {
      print("❌ Gemma Initialization Error: $e");
      isDownloading.value = false;
      downloadProgress.value = -1;
    }
  }

  /// 2. Warm-Up Logic
  void warmUp() {
    if (!isModelReady.value || _isNativeBusy) return;
    _recreateChat();
    print("🔥 Gemma: Warmed up and standing by.");
  }

  void configureIntentExecutor(
    Future<bool> Function(Map<String, dynamic> intent) executor,
  ) {
    _intentExecutor = executor;
    _kickQueueWorker();
  }

  Future<void> enqueueIntent({
    required String action,
    required String title,
    String content = '',
  }) async {
    final queue = await _readQueue();
    queue.add({
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'action': action.toLowerCase().trim(),
      'title': title.trim(),
      'content': content.trim(),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'retryCount': 0,
    });
    await _writeQueue(queue);
    await _syncQueueDebug();
    print('📥 Intent queued: $action -> $title');
    _kickQueueWorker();
  }

  void _kickQueueWorker() {
    if (_isQueueWorkerRunning) return;
    unawaited(_drainIntentQueue());
  }

  Future<void> _drainIntentQueue() async {
    if (_isQueueWorkerRunning) return;
    _isQueueWorkerRunning = true;
    queueDebug.value = queueDebug.value.copyWith(isProcessing: true);

    try {
      while (true) {
        final queue = await _readQueue();
        if (queue.isEmpty) break;
        if (_intentExecutor == null) break;

        final first = Map<String, dynamic>.from(queue.first);
        final action = (first['action']?.toString() ?? 'none').toLowerCase();
        queueDebug.value = queueDebug.value.copyWith(
          lastAction: action,
          pendingCount: queue.length,
        );

        if (!{'create', 'read', 'update', 'delete', 'list'}.contains(action)) {
          await _removeFirstQueueItem();
          await _syncQueueDebug();
          continue;
        }

        bool success = false;
        try {
          success = await _intentExecutor!(first);
        } catch (e) {
          print('❌ Queue executor error: $e');
        }

        if (success) {
          await _removeFirstQueueItem();
          await _syncQueueDebug();
        } else {
          final retries = ((first['retryCount'] as num?)?.toInt() ?? 0) + 1;
          first['retryCount'] = retries;
          await _updateFirstQueueItem(first);

          if (retries >= 3) {
            await _removeFirstQueueItem();
            await _incrementFailedCount();
            await _syncQueueDebug();
          } else {
            await _syncQueueDebug();
            await Future.delayed(const Duration(milliseconds: 600));
          }
        }
      }
    } finally {
      _isQueueWorkerRunning = false;
      await _syncQueueDebug();
      queueDebug.value = queueDebug.value.copyWith(isProcessing: false);
    }
  }

  Future<void> refreshQueueDebug() async {
    await _syncQueueDebug();
  }

  Future<void> speakText(String text) async {
    final safeText = text.trim();
    if (safeText.isEmpty) return;

    try {
      print('🔊 TTS start: $safeText');
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.45);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _tts.stop();
      await _tts.speak(safeText);
      print('✅ TTS queued successfully');
    } catch (e) {
      print('❌ TTS error: $e');
    }
  }

  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _readQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_intentQueueKey);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Object?>()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> queue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_intentQueueKey, jsonEncode(queue));
  }

  Future<void> _removeFirstQueueItem() async {
    final queue = await _readQueue();
    if (queue.isEmpty) return;
    queue.removeAt(0);
    await _writeQueue(queue);
  }

  Future<void> _updateFirstQueueItem(Map<String, dynamic> updated) async {
    final queue = await _readQueue();
    if (queue.isEmpty) return;
    queue[0] = updated;
    await _writeQueue(queue);
  }

  Future<void> _syncQueueDebug() async {
    final queue = await _readQueue();
    final prefs = await SharedPreferences.getInstance();
    final failed = prefs.getInt(_failedCountKey) ?? 0;
    queueDebug.value = queueDebug.value.copyWith(
      pendingCount: queue.length,
      failedCount: failed,
    );
  }

  Future<void> _incrementFailedCount() async {
    final prefs = await SharedPreferences.getInstance();
    final failed = prefs.getInt(_failedCountKey) ?? 0;
    await prefs.setInt(_failedCountKey, failed + 1);
  }

  /// 3. Force-Close Reset
  Future<void> _recreateChat() async {
    try {
      _chat = null;
      await Future.delayed(const Duration(milliseconds: 500));
      final model = await FlutterGemma.getActiveModel(
        maxTokens: 256,
      ); // 🟢 Low tokens for 1-word response
      _chat = await model.createChat();
    } catch (e) {
      print("⚠️ Recreate Chat skipped: $e");
    }
  }

  /// 🧠 Process Logic: Surgical Classifier
  /// Returns a single String (create, read, delete, or none)
  Future<String> processCommand(
    String incomingText, {
    int retryCount = 0,
  }) async {
    if (!isModelReady.value) return "none";

    // 🛡️ Intent Gating
    if (!incomingText.toLowerCase().contains("action:")) {
      return "none";
    }

    // 🔒 NATIVE CONCURRENCY CHECK
    if (_isNativeBusy) {
      if (retryCount < 4) {
        print("⏳ Native Busy. Retrying classification in 1.2s...");
        await Future.delayed(const Duration(milliseconds: 1200));
        return processCommand(incomingText, retryCount: retryCount + 1);
      }
      return "none";
    }

    _isNativeBusy = true;

    try {
      await _recreateChat();
      await Future.delayed(const Duration(milliseconds: 800));

      // 🎯 THE SURGICAL PROMPT
      // We force Gemma to act as a simple switch.
      final prompt =
          '''
      CLASSIFY THE USER INTENT INTO ONE WORD.
      INPUT: "$incomingText"

      RULES:
      - If input contains "Action: create" -> output "create"
      - If input contains "Action: update" -> output "update"
      - If input contains "Action: read" -> output "read"
      - If input contains "Action: delete" -> output "delete"
      - Otherwise -> output "none"

      ONE WORD ONLY.
      ''';

      await _chat!.addQueryChunk(Message.text(text: prompt, isUser: true));
      String response = "";

      await for (final chunk in _chat!.generateChatResponseAsync()) {
        try {
          response += (chunk as dynamic).token ?? chunk.toString();
        } catch (_) {
          response += chunk.toString();
        }
      }

      final result = response.trim().toLowerCase();
      print("🧠 Gemma Decision: $result");

      // Strict validation
      if (result.contains("create")) return "create";
      if (result.contains("update")) return "update";
      if (result.contains("read")) return "read";
      if (result.contains("delete")) return "delete";
      return "none";
    } catch (e) {
      print("❌ Native MediaPipe Error: $e");
      return "none";
    } finally {
      await Future.delayed(const Duration(milliseconds: 400));
      _isNativeBusy = false;
      print("🔓 Gemma: Native Lock Released.");
    }
  }
}
