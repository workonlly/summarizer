import 'package:elevenlabs_agents/elevenlabs_agents.dart';
import 'package:collection/collection.dart';
import 'local_gemma_brain.dart';

class NoteAgentTools {
  final Function(String, String) saveNote;
  final Function(String) deleteNote;
  final List<Map<String, dynamic>> Function() notesProvider;

  NoteAgentTools({
    required this.saveNote,
    required this.deleteNote,
    required this.notesProvider,
  }) {
    LocalGemmaBrain().configureIntentExecutor(_executeQueuedIntent);
  }

  /// 🟢 Map mapping Dashboard names to Local Classes
  Map<String, ClientTool> get tools => {
    "queue_note_task": _QueueNoteTaskTool(),
    "create_new_note": _CreateNoteTool(saveNote),
    "update_note_content": _UpdateNoteTool(saveNote),
    "list_all_notes": _ListNotesTool(notesProvider),
    "read_note_content": _ReadNoteTool(notesProvider),
    "remove_note": _RemoveNoteTool(deleteNote, notesProvider),
  };

  Future<bool> _executeQueuedIntent(Map<String, dynamic> intent) async {
    final action = (intent['action']?.toString() ?? '').toLowerCase();
    final title = intent['title']?.toString().trim() ?? '';
    final content = intent['content']?.toString() ?? '';
    final notes = notesProvider();
    print('🧵 Queue executor running: action=$action, title=$title');

    if (action == 'create') {
      if (title.isEmpty || content.trim().isEmpty) return true;
      await saveNote(title, content);
      return true;
    }

    if (action == 'update') {
      if (title.isEmpty || content.trim().isEmpty) return true;
      final target = _findNoteByTitle(notes, title);
      if (target != null) {
        await deleteNote(target['fileName'] as String);
      }
      await saveNote(title, content);
      return true;
    }

    if (action == 'delete') {
      final target = _findNoteByTitle(notes, title);
      if (target == null) return true;
      await deleteNote(target['fileName'] as String);
      return true;
    }

    if (action == 'read') {
      final target = _findNoteByTitle(notes, title);
      if (target == null) {
        print('📖 Queue read target not found for title=$title');
        await LocalGemmaBrain().speakText(
          "I could not find a note named $title.",
        );
        return true;
      }
      print("📖 Queue read target found: ${target['title']}");
      await LocalGemmaBrain().speakText(
        "${target['title']}. ${target['content']}",
      );
      return true;
    }

    if (action == 'list') {
      if (notes.isEmpty) {
        await LocalGemmaBrain().speakText("You do not have any saved notes.");
      } else {
        final titles = notes.map((n) => n['title']).join(', ');
        await LocalGemmaBrain().speakText("Your notes are: $titles");
      }
      return true;
    }

    return true;
  }

  Map<String, dynamic>? _findNoteByTitle(
    List<Map<String, dynamic>> notes,
    String query,
  ) {
    final q = _normalize(query);
    if (q.isEmpty) return null;

    final exact = notes.firstWhereOrNull(
      (n) => _normalize(n['title']?.toString() ?? '') == q,
    );
    if (exact != null) return exact;

    return notes.firstWhereOrNull(
      (n) => _normalize(n['title']?.toString() ?? '').contains(q),
    );
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _QueueNoteTaskTool extends ClientTool {
  @override
  String get name => 'queue_note_task';

  @override
  String get description =>
      "Queues a note task asynchronously. Parameters: action (create/read/update/delete), title, content.";

  @override
  Future<ClientToolResult> execute(Map<String, dynamic> parameters) async {
    final action = (parameters['action']?.toString() ?? '')
        .toLowerCase()
        .trim();
    final title = parameters['title']?.toString().trim() ?? '';
    final content = parameters['content']?.toString().trim() ?? '';

    if (!{'create', 'read', 'update', 'delete'}.contains(action)) {
      return ClientToolResult.success(
        "Error: action must be one of create/read/update/delete.",
      );
    }

    if (title.isEmpty) {
      return ClientToolResult.success("Error: title is required.");
    }

    if ((action == 'create' || action == 'update') && content.isEmpty) {
      return ClientToolResult.success(
        "Error: content is required for create/update.",
      );
    }

    await LocalGemmaBrain().enqueueIntent(
      action: action,
      title: title,
      content: action == 'read' || action == 'delete' ? '' : content,
    );

    if (action == 'create') {
      return ClientToolResult.success(
        "Got it, I'm queueing that note to be saved.",
      );
    }
    if (action == 'read') {
      return ClientToolResult.success(
        "I'll have the system pull that up and read it to you in just a second.",
      );
    }
    if (action == 'delete') {
      return ClientToolResult.success(
        "I've sent the request to delete that note.",
      );
    }
    return ClientToolResult.success("Got it, I'm queueing that note update.");
  }
}

// --- TOOL 1: CREATE ---
class _CreateNoteTool extends ClientTool {
  final Function(String, String) onSave;

  _CreateNoteTool(this.onSave);

  @override
  String get name => "create_new_note";

  @override
  String get description =>
      "Use this to save a new note. Requires a 'title' (short name) and 'content' (the actual note text).";

  @override
  Future<ClientToolResult> execute(Map<String, dynamic> parameters) async {
    print("🚀 Tool Triggered: create_new_note");
    print("📦 Raw Parameters from ElevenLabs: $parameters");

    // Extracting with safety checks
    final String title =
        parameters['title']?.toString().trim() ?? "Untitled Note";
    final String content = parameters['content']?.toString().trim() ?? "";

    if (content.isEmpty) {
      return ClientToolResult.success(
        "Error: The note content was empty. Please provide some text.",
      );
    }

    await LocalGemmaBrain().enqueueIntent(
      action: 'create',
      title: title,
      content: content,
    );

    return ClientToolResult.success("Queued create request for '$title'.");
  }
}

class _UpdateNoteTool extends ClientTool {
  final Function(String, String) onSave;

  _UpdateNoteTool(this.onSave);

  @override
  String get name => "update_note_content";

  @override
  String get description =>
      "Use this to update a note by title. Requires 'title' and 'content'.";

  @override
  Future<ClientToolResult> execute(Map<String, dynamic> parameters) async {
    final String title =
        parameters['title']?.toString().trim() ?? "Untitled Note";
    final String content = parameters['content']?.toString().trim() ?? "";

    await LocalGemmaBrain().enqueueIntent(
      action: 'update',
      title: title,
      content: content,
    );

    return ClientToolResult.success("Queued update request for '$title'.");
  }
}

// --- TOOL 2: LIST ---
class _ListNotesTool extends ClientTool {
  final List<Map<String, dynamic>> Function() notesProvider;

  _ListNotesTool(this.notesProvider);

  @override
  String get name => "list_all_notes";

  @override
  String get description => "Lists all saved note titles to the user.";

  @override
  Future<ClientToolResult> execute(Map<String, dynamic> parameters) async {
    print("🚀 Tool Triggered: list_all_notes");

    await LocalGemmaBrain().enqueueIntent(action: 'list', title: 'all_notes');

    final notes = notesProvider();

    if (notes.isEmpty) {
      return ClientToolResult.success("The user has no notes saved yet.");
    }

    final String titles = notes.map((n) => n['title']).join(", ");
    return ClientToolResult.success("The current notes are: $titles");
  }
}

// --- TOOL 3: READ ---
class _ReadNoteTool extends ClientTool {
  final List<Map<String, dynamic>> Function() notesProvider;

  _ReadNoteTool(this.notesProvider);

  @override
  String get name => "read_note_content";

  @override
  String get description =>
      "Reads the full content of a specific note when the user asks what a note says.";

  @override
  Future<ClientToolResult> execute(Map<String, dynamic> parameters) async {
    print("🚀 Tool Triggered: read_note_content");
    final String searchTitle =
        parameters['title']?.toString().toLowerCase().trim() ?? "";

    await LocalGemmaBrain().enqueueIntent(action: 'read', title: searchTitle);

    final notes = notesProvider();

    final target = notes.firstWhereOrNull(
      (n) => n['title'].toString().toLowerCase().contains(searchTitle),
    );

    if (target == null) {
      return ClientToolResult.success(
        "I couldn't find a note with the title '$searchTitle'.",
      );
    }

    return ClientToolResult.success(
      "The content of the note '${target['title']}' is: ${target['content']}",
    );
  }
}

// --- TOOL 4: DELETE ---
class _RemoveNoteTool extends ClientTool {
  final Function(String) onDelete;
  final List<Map<String, dynamic>> Function() notesProvider;

  _RemoveNoteTool(this.onDelete, this.notesProvider);

  @override
  String get name => "remove_note";

  @override
  String get description => "Deletes a specific note by title.";

  @override
  Future<ClientToolResult> execute(Map<String, dynamic> parameters) async {
    print("🚀 Tool Triggered: remove_note");
    final String searchTitle =
        parameters['title']?.toString().toLowerCase().trim() ?? "";

    await LocalGemmaBrain().enqueueIntent(action: 'delete', title: searchTitle);

    final notes = notesProvider();

    final target = notes.firstWhereOrNull(
      (n) => n['title'].toString().toLowerCase().contains(searchTitle),
    );

    if (target == null) {
      return ClientToolResult.success(
        "Error: Could not find a note named '$searchTitle' to delete.",
      );
    }

    return ClientToolResult.success(
      "Queued delete request for '${target['title']}'.",
    );
  }
}
