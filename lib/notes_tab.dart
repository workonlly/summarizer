import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:elevenlabs_agents/elevenlabs_agents.dart';
import 'logic_listening.dart';
import 'local_gemma_brain.dart';

class NotesTab extends StatefulWidget {
  const NotesTab({super.key});

  @override
  State<NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends State<NotesTab> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  bool _isLoadingNotes = true;
  List<Map<String, dynamic>> _savedNotes = [];
  String? _editingFileName;

  // Made nullable to prevent crashes when the client isn't yet initialized
  ConversationClient? _conversationClient;
  bool _isAgentTalking = false;

  @override
  void initState() {
    super.initState();
    _loadSavedNotes();
    LocalGemmaBrain().refreshQueueDebug();
  }

  @override
  void dispose() {
    // 🟢 Use null-aware operator for safe disposal
    _conversationClient?.endSession();
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  // --- TOOL HANDLERS (CRUD) ---

  Future<void> _handleToolSave(String title, String content) async {
    print("🛠️ Tool Executing: Save -> $title");
    if (mounted) {
      setState(() {
        _titleController.text = title;
        _contentController.text = content;
        _editingFileName = null;
      });
      // This saves the file and refreshes the list automatically
      await _saveNoteAsJson(closeSheet: false);
    }
  }

  Future<void> _handleToolDelete(String fileName) async {
    print("🛠️ Tool Executing: Delete -> $fileName");
    await _deleteNote(fileName);
  }

  // --- LOCAL PERSISTENCE ---

  Future<void> _loadSavedNotes() async {
    if (mounted) setState(() => _isLoadingNotes = true);
    try {
      final dir = Directory('/storage/emulated/0/Documents/SummariZer_Notes');
      if (!await dir.exists()) await dir.create(recursive: true);

      final files = dir.listSync();
      final List<Map<String, dynamic>> loaded = [];
      for (var f in files) {
        if (f is File && f.path.endsWith('.json')) {
          final data = jsonDecode(await f.readAsString());
          data['fileName'] = f.path.split('/').last;
          loaded.add(data);
        }
      }
      loaded.sort((a, b) => b['id'].compareTo(a['id']));
      if (mounted) setState(() => _savedNotes = loaded);
    } catch (e) {
      print("❌ Load Error: $e");
    } finally {
      if (mounted) setState(() => _isLoadingNotes = false);
    }
  }

  Future<void> _saveNoteAsJson({bool closeSheet = true}) async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    if (title.isEmpty) return;

    try {
      final dir = Directory('/storage/emulated/0/Documents/SummariZer_Notes');
      final now = DateTime.now();

      final data = {
        "id":
            _editingFileName?.replaceAll(RegExp(r'[^0-9]'), '') ??
            now.millisecondsSinceEpoch.toString(),
        "title": title,
        "content": content,
        "date":
            "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}",
        "time":
            "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}",
      };

      final fileName =
          _editingFileName ?? "Note_${now.millisecondsSinceEpoch}.json";
      await File('${dir.path}/$fileName').writeAsString(jsonEncode(data));

      print("💾 File Saved: $fileName");
      await _loadSavedNotes(); // REFRESH UI
      await LocalGemmaBrain().refreshQueueDebug();

      if (closeSheet && mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    } catch (e) {
      print("❌ Save Error: $e");
    }
  }

  Future<void> _deleteNote(String fileName) async {
    try {
      final file = File(
        '/storage/emulated/0/Documents/SummariZer_Notes/$fileName',
      );
      if (await file.exists()) {
        await file.delete();
        print("🗑️ File deleted: $fileName");
      }
      await _loadSavedNotes(); // REFRESH UI
      await LocalGemmaBrain().refreshQueueDebug();
    } catch (e) {
      print("❌ Delete Error: $e");
    }
  }

  // --- VOICE AGENT ORCHESTRATION ---

  Future<void> _toggleVoiceAssistant() async {
    // 🟢 Use null-aware operator for checking the client
    if (_isAgentTalking && _conversationClient != null) {
      await _conversationClient?.endSession();
      return;
    }

    if (await Permission.microphone.request().isGranted) {
      final noteTools = NoteAgentTools(
        saveNote: _handleToolSave,
        deleteNote: _handleToolDelete,
        notesProvider: () => _savedNotes,
      );

      _conversationClient = ConversationClient(
        clientTools: noteTools.tools,
        callbacks: ConversationCallbacks(
          onConnect: ({required conversationId}) {
            if (mounted) setState(() => _isAgentTalking = true);
            print("🟢 ElevenLabs: Link Established.");
          },
          onDisconnect: (details) {
            if (mounted) setState(() => _isAgentTalking = false);
            print("🔌 ElevenLabs: Session Ended. Reason: ${details.reason}");
          },
          onMessage: ({required message, required source}) {
            print("📡 Agent [$source]: $message");
            unawaited(_tryQueueIntentFromAgentMessage(message));
          },
          onError: (error, [stackTrace]) {
            print("⚠️ ElevenLabs Error: $error");
          },
        ),
      );

      print("🎤 Starting voice session...");
      // 🟢 Use bang operator (!) because we just initialized it
      await _conversationClient!.startSession(
        agentId: 'agent_2201kkqv1xndf3zt41qx2c72c7px',
      );
    }
  }

  // --- UI BUILDING ---

  Future<void> _tryQueueIntentFromAgentMessage(String message) async {
    final payload = _extractQueuePayload(message);
    if (payload == null) {
      if (message.contains('queue_note_task')) {
        print('⚠️ queue_note_task detected but payload parse failed: $message');
      }
      return;
    }

    final action = payload['action']?.toLowerCase().trim() ?? '';
    final title = payload['title']?.trim() ?? '';
    final content = payload['content']?.trim() ?? '';

    if (!{'create', 'read', 'update', 'delete'}.contains(action)) return;
    if (title.isEmpty) return;

    await LocalGemmaBrain().enqueueIntent(
      action: action,
      title: title,
      content: (action == 'read' || action == 'delete') ? '' : content,
    );
    await LocalGemmaBrain().refreshQueueDebug();
    print('✅ Fallback queued from agent message: $action -> $title');
  }

  Map<String, String>? _extractQueuePayload(String text) {
    final callPattern = RegExp(
      r'<call:queue_note_task\s+([^>]*)/?>',
      caseSensitive: false,
    );
    final callMatch = callPattern.firstMatch(text);
    if (callMatch != null) {
      final attrs = callMatch.group(1) ?? '';
      final attrPattern = RegExp(
        r'(action|title|content)=(["\"])\s*(.*?)\s*\2',
        caseSensitive: false,
      );
      final result = <String, String>{};
      for (final match in attrPattern.allMatches(attrs)) {
        final key = match.group(1);
        final value = match.group(3);
        if (key != null && value != null) {
          result[key] = value;
        }
      }
      if (result.isNotEmpty) {
        return result;
      }
    }

    final jsonStr = _extractJsonObject(text);
    if (jsonStr == null) return null;

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return null;
      return {
        'action': decoded['action']?.toString() ?? '',
        'title': decoded['title']?.toString() ?? '',
        'content': decoded['content']?.toString() ?? '',
      };
    } catch (_) {
      return null;
    }
  }

  String? _extractJsonObject(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) return null;
    return text.substring(start, end + 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _isLoadingNotes
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(),
      floatingActionButton: _buildFABs(),
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: _buildQueueDebugCard(),
        ),
        Expanded(child: _buildListView()),
      ],
    );
  }

  Widget _buildQueueDebugCard() {
    return ValueListenableBuilder<QueueDebugState>(
      valueListenable: LocalGemmaBrain().queueDebug,
      builder: (context, debug, _) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.indigo.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.indigo.shade100),
          ),
          child: Row(
            children: [
              Icon(
                debug.isProcessing ? Icons.sync_rounded : Icons.queue_rounded,
                color: Colors.indigo.shade500,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Queue: ${debug.pendingCount} pending | Last: ${debug.lastAction} | Failed: ${debug.failedCount}',
                  style: TextStyle(
                    color: Colors.indigo.shade900,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildListView() {
    if (_savedNotes.isEmpty) {
      return Center(
        child: Text(
          "No notes. Tap mic to begin.",
          style: GoogleFonts.plusJakartaSans(color: Colors.grey, fontSize: 16),
        ),
      );
    }
    return ListView.builder(
      // 🟢 Restored Padding: 20px all sides, 100px bottom to avoid FAB overlap
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      itemCount: _savedNotes.length,
      itemBuilder: (context, index) {
        final note = _savedNotes[index];
        return Card(
          elevation: 2,
          margin: const EdgeInsets.only(bottom: 12),
          child: ListTile(
            title: Text(
              note['title'],
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              note['content'],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _openComposeSheet(existingNote: note),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              onPressed: () => _deleteNote(note['fileName']),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFABs() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 80.0, right: 10.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 🟢 RESTORED: ADD BUTTON
          FloatingActionButton(
            heroTag: "add",
            backgroundColor: Colors.indigo,
            child: const Icon(Icons.add, color: Colors.white),
            onPressed: () => _openComposeSheet(),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            heroTag: "mic",
            backgroundColor: _isAgentTalking ? Colors.red : Colors.indigo,
            child: Icon(
              _isAgentTalking ? Icons.stop_circle : Icons.mic_none,
              color: Colors.white,
            ),
            onPressed: _toggleVoiceAssistant,
          ),
        ],
      ),
    );
  }

  void _openComposeSheet({Map<String, dynamic>? existingNote}) {
    if (existingNote != null) {
      _titleController.text = existingNote['title'];
      _contentController.text = existingNote['content'];
      _editingFileName = existingNote['fileName'];
    } else {
      _titleController.clear();
      _contentController.clear();
      _editingFileName = null;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _buildSheet(context, existingNote != null),
    );
  }

  Widget _buildSheet(BuildContext context, bool isEdit) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEdit ? '✏️ Edit Note' : '✨ New Note',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              hintText: "Title",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _contentController,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: "Content",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _saveNoteAsJson(),
              child: Text(isEdit ? 'Update changes' : 'Save Note'),
            ),
          ),
        ],
      ),
    );
  }
}
