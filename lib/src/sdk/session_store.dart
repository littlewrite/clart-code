import '../cli/workspace_store.dart';
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

  factory ClartCodeSessionSnapshot.fromWorkspace(
    WorkspaceSessionSnapshot snapshot,
  ) {
    return ClartCodeSessionSnapshot(
      id: snapshot.id,
      title: snapshot.title,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt,
      provider: snapshot.provider,
      model: snapshot.model,
      history: List<ChatMessage>.from(snapshot.history),
      transcript: List<TranscriptMessage>.from(snapshot.transcript),
      tags: List<String>.from(snapshot.tags),
    );
  }

  WorkspaceSessionSnapshot toWorkspaceSnapshot() {
    return WorkspaceSessionSnapshot(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      provider: provider,
      model: model,
      history: List<ChatMessage>.from(history),
      transcript: List<TranscriptMessage>.from(transcript),
      tags: List<String>.from(tags),
    );
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

  String createSessionId() => createWorkspaceSessionId();

  void save(ClartCodeSessionSnapshot snapshot) {
    writeWorkspaceSession(snapshot.toWorkspaceSnapshot(), cwd: cwd);
  }

  ClartCodeSessionSnapshot? load(String sessionId) {
    final snapshot = readWorkspaceSession(sessionId, cwd: cwd);
    if (snapshot == null) {
      return null;
    }
    return ClartCodeSessionSnapshot.fromWorkspace(snapshot);
  }

  List<ClartCodeSessionSnapshot> list() {
    return listWorkspaceSessions(cwd: cwd)
        .map(ClartCodeSessionSnapshot.fromWorkspace)
        .toList();
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

  String? readActiveSessionId() {
    return readActiveWorkspaceSessionId(cwd: cwd);
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
