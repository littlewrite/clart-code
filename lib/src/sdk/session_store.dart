import 'dart:convert';
import 'dart:io';

import '../core/models.dart';
import '../core/transcript.dart';

class ClartCodeSessionSnapshot {
  const ClartCodeSessionSnapshot({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.provider,
    required this.history,
    required this.transcript,
    this.model,
    this.tags = const [],
  });

  final String id;
  final String title;
  final String createdAt;
  final String updatedAt;
  final String provider;
  final String? model;
  final List<ChatMessage> history;
  final List<TranscriptMessage> transcript;
  final List<String> tags;

  factory ClartCodeSessionSnapshot.build({
    required String id,
    required String provider,
    String? model,
    required List<ChatMessage> history,
    required List<TranscriptMessage> transcript,
    String? createdAt,
    String? updatedAt,
    String? title,
    List<String> tags = const [],
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    return ClartCodeSessionSnapshot(
      id: id,
      title: title ?? _buildSessionTitle(transcript, history),
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? now,
      provider: provider,
      model: model,
      history: List<ChatMessage>.from(history),
      transcript: List<TranscriptMessage>.from(transcript),
      tags: List<String>.unmodifiable(tags),
    );
  }

  factory ClartCodeSessionSnapshot.fromJson(Map<String, Object?> json) {
    return ClartCodeSessionSnapshot(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      provider: json['provider'] as String? ?? 'local',
      model: json['model'] as String?,
      history: (json['history'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => _chatMessageFromJson(
              Map<String, Object?>.from(item.cast<String, Object?>()),
            ),
          )
          .toList(growable: false),
      transcript: (json['transcript'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => _transcriptMessageFromJson(
              Map<String, Object?>.from(item.cast<String, Object?>()),
            ),
          )
          .toList(growable: false),
      tags: (json['tags'] as List? ?? const [])
          .whereType<String>()
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'title': title,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'provider': provider,
      'model': model,
      'tags': tags,
      'history': history
          .map(
            (message) => {
              'role': message.role.name,
              'text': message.text,
            },
          )
          .toList(growable: false),
      'transcript':
          transcript.map((message) => message.toJson()).toList(growable: false),
    };
  }

  ClartCodeSessionSnapshot copyWith({
    String? id,
    String? title,
    String? createdAt,
    String? updatedAt,
    String? provider,
    String? model,
    List<ChatMessage>? history,
    List<TranscriptMessage>? transcript,
    List<String>? tags,
  }) {
    return ClartCodeSessionSnapshot(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      history: history ?? this.history,
      transcript: transcript ?? this.transcript,
      tags: tags ?? this.tags,
    );
  }
}

class ClartCodeSessionStore {
  const ClartCodeSessionStore({
    this.cwd,
  });

  final String? cwd;

  String createSessionId() =>
      DateTime.now().toUtc().microsecondsSinceEpoch.toString();

  void save(ClartCodeSessionSnapshot snapshot) {
    _ensureSessionsDir();
    File(_sessionPath(snapshot.id)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
    );
    _writeActiveSessionId(snapshot.id);
  }

  ClartCodeSessionSnapshot? load(String sessionId) {
    final file = File(_sessionPath(sessionId));
    if (!file.existsSync()) {
      return null;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return ClartCodeSessionSnapshot.fromJson(
          Map<String, Object?>.from(decoded),
        );
      }
    } catch (_) {
      // Keep session restore resilient if a file is malformed.
    }
    return null;
  }

  List<ClartCodeSessionSnapshot> list() {
    final dir = Directory(_sessionsDirPath);
    if (!dir.existsSync()) {
      return const [];
    }
    final snapshots = <ClartCodeSessionSnapshot>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      final id = entity.uri.pathSegments.last.replaceAll('.json', '');
      final snapshot = load(id);
      if (snapshot != null) {
        snapshots.add(snapshot);
      }
    }
    snapshots.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return snapshots;
  }

  ClartCodeSessionSnapshot? latest() {
    final sessions = list();
    if (sessions.isEmpty) {
      return null;
    }
    return sessions.first;
  }

  ClartCodeSessionSnapshot? active() {
    final activeId = readActiveSessionId();
    if (activeId == null) {
      return null;
    }
    return load(activeId);
  }

  ClartCodeSessionSnapshot? info(String sessionId) {
    return load(sessionId);
  }

  List<ChatMessage>? messages(String sessionId) {
    final snapshot = load(sessionId);
    if (snapshot == null) {
      return null;
    }
    return List<ChatMessage>.unmodifiable(snapshot.history);
  }

  List<TranscriptMessage>? transcriptMessages(String sessionId) {
    final snapshot = load(sessionId);
    if (snapshot == null) {
      return null;
    }
    return List<TranscriptMessage>.unmodifiable(snapshot.transcript);
  }

  ClartCodeSessionSnapshot? fork(
    String sessionId, {
    String? title,
    List<String>? tags,
  }) {
    final existing = load(sessionId);
    if (existing == null) {
      return null;
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final forked = existing.copyWith(
      id: createSessionId(),
      title: title ?? existing.title,
      createdAt: now,
      updatedAt: now,
      tags: _normalizeTags(tags ?? existing.tags),
    );
    save(forked);
    return forked;
  }

  ClartCodeSessionSnapshot? rename(String sessionId, String title) {
    final existing = load(sessionId);
    final normalizedTitle = title.trim();
    if (existing == null || normalizedTitle.isEmpty) {
      return null;
    }

    final renamed = existing.copyWith(
      title: normalizedTitle,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    save(renamed);
    return renamed;
  }

  ClartCodeSessionSnapshot? setTags(String sessionId, List<String> tags) {
    final existing = load(sessionId);
    if (existing == null) {
      return null;
    }

    final updated = existing.copyWith(
      tags: _normalizeTags(tags),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    save(updated);
    return updated;
  }

  ClartCodeSessionSnapshot? addTag(String sessionId, String tag) {
    final normalizedTag = tag.trim();
    if (normalizedTag.isEmpty) {
      return null;
    }

    final existing = load(sessionId);
    if (existing == null) {
      return null;
    }

    return setTags(sessionId, [...existing.tags, normalizedTag]);
  }

  ClartCodeSessionSnapshot? removeTag(String sessionId, String tag) {
    final existing = load(sessionId);
    if (existing == null) {
      return null;
    }

    final normalizedTag = tag.trim();
    return setTags(
      sessionId,
      existing.tags.where((item) => item != normalizedTag).toList(),
    );
  }

  ClartCodeSessionSnapshot? append(
    String sessionId, {
    List<ChatMessage> history = const [],
    List<TranscriptMessage> transcript = const [],
  }) {
    final existing = load(sessionId);
    if (existing == null) {
      return null;
    }
    if (history.isEmpty && transcript.isEmpty) {
      return existing;
    }

    final updated = existing.copyWith(
      history: [...existing.history, ...history],
      transcript: [...existing.transcript, ...transcript],
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    save(updated);
    return updated;
  }

  bool delete(String sessionId) {
    final file = File(_sessionPath(sessionId));
    if (!file.existsSync()) {
      return false;
    }
    file.deleteSync();

    if (readActiveSessionId() == sessionId) {
      final latestSession = latest();
      if (latestSession == null) {
        final activeFile = File(_activeSessionPath);
        if (activeFile.existsSync()) {
          activeFile.deleteSync();
        }
      } else {
        _writeActiveSessionId(latestSession.id);
      }
    }
    return true;
  }

  String? readActiveSessionId() {
    final file = File(_activeSessionPath);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        final id = decoded['id'] as String?;
        if (id != null && id.trim().isNotEmpty) {
          return id.trim();
        }
      }
    } catch (_) {
      // Fall back to null on malformed files.
    }
    return null;
  }

  String get _workspaceDataDir => '${cwd ?? Directory.current.path}/.clart';

  String get _sessionsDirPath => '$_workspaceDataDir/sessions';

  String get _activeSessionPath => '$_workspaceDataDir/active_session.json';

  String _sessionPath(String id) => '$_sessionsDirPath/$id.json';

  void _ensureWorkspaceDataDir() {
    Directory(_workspaceDataDir).createSync(recursive: true);
  }

  void _ensureSessionsDir() {
    Directory(_sessionsDirPath).createSync(recursive: true);
  }

  void _writeActiveSessionId(String id) {
    _ensureWorkspaceDataDir();
    File(_activeSessionPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({'id': id}),
    );
  }

  List<String> _normalizeTags(List<String> tags) {
    final normalized = <String>{};
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isNotEmpty) {
        normalized.add(trimmed);
      }
    }
    final ordered = normalized.toList()..sort();
    return List<String>.unmodifiable(ordered);
  }
}

@Deprecated('Use ClartCodeSessionSnapshot instead.')
typedef ClatCodeSessionSnapshot = ClartCodeSessionSnapshot;

@Deprecated('Use ClartCodeSessionStore instead.')
typedef ClatCodeSessionStore = ClartCodeSessionStore;

ChatMessage _chatMessageFromJson(Map<String, Object?> json) {
  return ChatMessage(
    role: _parseMessageRole(json['role'] as String?) ?? MessageRole.user,
    text: json['text'] as String? ?? '',
  );
}

MessageRole? _parseMessageRole(String? raw) {
  switch (raw) {
    case 'system':
      return MessageRole.system;
    case 'user':
      return MessageRole.user;
    case 'assistant':
      return MessageRole.assistant;
    case 'tool':
      return MessageRole.tool;
    default:
      return null;
  }
}

TranscriptMessage _transcriptMessageFromJson(Map<String, Object?> json) {
  return TranscriptMessage.fromJson(json);
}

String _buildSessionTitle(
  List<TranscriptMessage> transcript,
  List<ChatMessage> history,
) {
  for (final message in transcript) {
    if (message.kind == TranscriptMessageKind.userPrompt &&
        message.text.trim().isNotEmpty) {
      return _truncateSessionTitle(message.text.trim());
    }
  }
  for (final message in history) {
    if (message.role == MessageRole.user && message.text.trim().isNotEmpty) {
      return _truncateSessionTitle(message.text.trim());
    }
  }
  return 'Session ${DateTime.now().toUtc().toIso8601String()}';
}

String _truncateSessionTitle(String raw) {
  final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= 60) {
    return collapsed;
  }
  return '${collapsed.substring(0, 57)}...';
}
