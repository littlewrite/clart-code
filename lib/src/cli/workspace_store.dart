import 'dart:convert';
import 'dart:io';

import '../core/models.dart';
import '../core/transcript.dart';
import '../mcp/mcp_registry.dart';
import '../mcp/mcp_types.dart';
import '../tools/tool_permissions.dart';

String workspaceDataDir({String? cwd}) =>
    '${cwd ?? Directory.current.path}/.clart';

String workspaceMemoryPath({String? cwd}) =>
    '${workspaceDataDir(cwd: cwd)}/memory.md';

String workspaceTasksPath({String? cwd}) =>
    '${workspaceDataDir(cwd: cwd)}/tasks.json';

String workspacePermissionsPath({String? cwd}) =>
    '${workspaceDataDir(cwd: cwd)}/permissions.json';

String workspaceMcpServersPath({String? cwd}) =>
    '${workspaceDataDir(cwd: cwd)}/mcp_servers.json';

String workspaceSessionsDir({String? cwd}) =>
    '${workspaceDataDir(cwd: cwd)}/sessions';

String workspaceActiveSessionPath({String? cwd}) =>
    '${workspaceDataDir(cwd: cwd)}/active_session.json';

void ensureWorkspaceDataDir({String? cwd}) {
  Directory(workspaceDataDir(cwd: cwd)).createSync(recursive: true);
}

void ensureWorkspaceSessionsDir({String? cwd}) {
  Directory(workspaceSessionsDir(cwd: cwd)).createSync(recursive: true);
}

String readWorkspaceMemory({String? cwd}) {
  final file = File(workspaceMemoryPath(cwd: cwd));
  if (!file.existsSync()) {
    return '';
  }
  return file.readAsStringSync();
}

void writeWorkspaceMemory(String text, {String? cwd}) {
  ensureWorkspaceDataDir(cwd: cwd);
  File(workspaceMemoryPath(cwd: cwd)).writeAsStringSync(text);
}

class WorkspaceTask {
  const WorkspaceTask({
    required this.id,
    required this.text,
    required this.done,
    required this.createdAt,
    this.completedAt,
  });

  final int id;
  final String text;
  final bool done;
  final String createdAt;
  final String? completedAt;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'text': text,
      'done': done,
      'createdAt': createdAt,
      'completedAt': completedAt,
    };
  }

  factory WorkspaceTask.fromJson(Map<String, Object?> json) {
    return WorkspaceTask(
      id: (json['id'] as num?)?.toInt() ?? 0,
      text: json['text'] as String? ?? '',
      done: json['done'] as bool? ?? false,
      createdAt: json['createdAt'] as String? ?? '',
      completedAt: json['completedAt'] as String?,
    );
  }

  WorkspaceTask copyWith({
    int? id,
    String? text,
    bool? done,
    String? createdAt,
    String? completedAt,
  }) {
    return WorkspaceTask(
      id: id ?? this.id,
      text: text ?? this.text,
      done: done ?? this.done,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}

List<WorkspaceTask> readWorkspaceTasks({String? cwd}) {
  final file = File(workspaceTasksPath(cwd: cwd));
  if (!file.existsSync()) {
    return const [];
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((item) => WorkspaceTask.fromJson(
                Map<String, Object?>.from(item.cast<String, Object?>()),
              ))
          .toList();
    }
  } catch (_) {
    // Keep task commands resilient if the file is malformed.
  }
  return const [];
}

void writeWorkspaceTasks(List<WorkspaceTask> tasks, {String? cwd}) {
  ensureWorkspaceDataDir(cwd: cwd);
  File(workspaceTasksPath(cwd: cwd)).writeAsStringSync(
    const JsonEncoder.withIndent('  ')
        .convert(tasks.map((task) => task.toJson()).toList()),
  );
}

WorkspaceTask addWorkspaceTask(String text, {String? cwd}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(text, 'text', 'task text cannot be empty');
  }
  final tasks = readWorkspaceTasks(cwd: cwd);
  final nextId = tasks.isEmpty
      ? 1
      : tasks.map((task) => task.id).reduce((a, b) => a > b ? a : b) + 1;
  final nextTask = WorkspaceTask(
    id: nextId,
    text: trimmed,
    done: false,
    createdAt: DateTime.now().toUtc().toIso8601String(),
  );
  writeWorkspaceTasks([...tasks, nextTask], cwd: cwd);
  return nextTask;
}

WorkspaceTask? completeWorkspaceTask(int id, {String? cwd}) {
  final tasks = readWorkspaceTasks(cwd: cwd);
  WorkspaceTask? updated;
  final nextTasks = tasks.map((task) {
    if (task.id != id) {
      return task;
    }
    updated = task.copyWith(
      done: true,
      completedAt: DateTime.now().toUtc().toIso8601String(),
    );
    return updated!;
  }).toList();
  if (updated == null) {
    return null;
  }
  writeWorkspaceTasks(nextTasks, cwd: cwd);
  return updated;
}

void clearWorkspaceTasks({String? cwd}) {
  writeWorkspaceTasks(const [], cwd: cwd);
}

ToolPermissionMode readDefaultToolPermissionMode({String? cwd}) {
  final file = File(workspacePermissionsPath(cwd: cwd));
  if (!file.existsSync()) {
    return ToolPermissionMode.allow;
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      switch (decoded['mode']) {
        case 'deny':
          return ToolPermissionMode.deny;
        case 'allow':
        default:
          return ToolPermissionMode.allow;
      }
    }
  } catch (_) {
    // Fall back to allow on malformed files.
  }
  return ToolPermissionMode.allow;
}

void writeDefaultToolPermissionMode(
  ToolPermissionMode mode, {
  String? cwd,
}) {
  ensureWorkspaceDataDir(cwd: cwd);
  File(workspacePermissionsPath(cwd: cwd)).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({'mode': mode.name}),
  );
}

class WorkspaceMcpServer {
  const WorkspaceMcpServer({
    required this.name,
    required this.transport,
    required this.target,
  });

  final String name;
  final String transport;
  final String target;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'transport': transport,
      'target': target,
    };
  }

  factory WorkspaceMcpServer.fromJson(Map<String, Object?> json) {
    return WorkspaceMcpServer(
      name: json['name'] as String? ?? '',
      transport: json['transport'] as String? ?? '',
      target: json['target'] as String? ?? '',
    );
  }

  factory WorkspaceMcpServer.fromConfig(McpServerConfig config) {
    return WorkspaceMcpServer(
      name: config.name,
      transport: config.transportType.name,
      target: describeWorkspaceMcpTarget(config),
    );
  }

  McpServerConfig toConfig() {
    switch (transport) {
      case 'stdio':
        final parts = splitCommandString(target);
        if (parts.isEmpty) {
          throw FormatException('stdio MCP target cannot be empty');
        }
        return McpStdioServerConfig(
          name: name,
          command: parts.first,
          args: parts.skip(1).toList(growable: false),
        );
      case 'sse':
        return McpSseServerConfig(name: name, url: target);
      case 'http':
        return McpHttpServerConfig(name: name, url: target);
      case 'ws':
        return McpWsServerConfig(name: name, url: target);
      default:
        throw FormatException('unsupported MCP transport: $transport');
    }
  }
}

List<WorkspaceMcpServer> readWorkspaceMcpServers({String? cwd}) {
  final file = File(workspaceMcpServersPath(cwd: cwd));
  if (!file.existsSync()) {
    return const [];
  }
  try {
    final registry = McpRegistry.fromJsonString(file.readAsStringSync());
    final servers = registry.servers.values
        .map(WorkspaceMcpServer.fromConfig)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return servers;
  } catch (_) {
    // Keep MCP list resilient if the file is malformed.
  }
  return const [];
}

void writeWorkspaceMcpServers(
  List<WorkspaceMcpServer> servers, {
  String? cwd,
}) {
  ensureWorkspaceDataDir(cwd: cwd);
  final sortedServers = [...servers]..sort((a, b) => a.name.compareTo(b.name));
  final configs = <String, McpServerConfig>{};
  for (final server in sortedServers) {
    configs[server.name] = server.toConfig();
  }
  File(workspaceMcpServersPath(cwd: cwd)).writeAsStringSync(
    McpRegistry(servers: configs).encodePretty(),
  );
}

void upsertWorkspaceMcpServer(
  WorkspaceMcpServer server, {
  String? cwd,
}) {
  final servers = readWorkspaceMcpServers(cwd: cwd);
  final nextServers = [
    ...servers.where((item) => item.name != server.name),
    server,
  ]..sort((a, b) => a.name.compareTo(b.name));
  writeWorkspaceMcpServers(nextServers, cwd: cwd);
}

bool removeWorkspaceMcpServer(String name, {String? cwd}) {
  final servers = readWorkspaceMcpServers(cwd: cwd);
  final nextServers = servers.where((item) => item.name != name).toList();
  if (nextServers.length == servers.length) {
    return false;
  }
  writeWorkspaceMcpServers(nextServers, cwd: cwd);
  return true;
}

class WorkspaceSessionSnapshot {
  const WorkspaceSessionSnapshot({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.provider,
    required this.model,
    required this.history,
    required this.transcript,
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
          .map((message) => {
                'role': message.role.name,
                'text': message.text,
              })
          .toList(),
      'transcript': transcript
          .map((message) => {
                'kind': message.kind.name,
                'text': message.text,
              })
          .toList(),
    };
  }

  factory WorkspaceSessionSnapshot.fromJson(Map<String, Object?> json) {
    return WorkspaceSessionSnapshot(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      provider: json['provider'] as String? ?? 'local',
      model: json['model'] as String?,
      tags: (json['tags'] as List? ?? const [])
          .whereType<String>()
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList(),
      history: (json['history'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => _chatMessageFromJson(
                Map<String, Object?>.from(item.cast<String, Object?>()),
              ))
          .toList(),
      transcript: (json['transcript'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => _transcriptMessageFromJson(
                Map<String, Object?>.from(item.cast<String, Object?>()),
              ))
          .toList(),
    );
  }

  WorkspaceSessionSnapshot copyWith({
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
    return WorkspaceSessionSnapshot(
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

String createWorkspaceSessionId() =>
    DateTime.now().toUtc().microsecondsSinceEpoch.toString();

String workspaceSessionPath(
  String id, {
  String? cwd,
}) =>
    '${workspaceSessionsDir(cwd: cwd)}/$id.json';

WorkspaceSessionSnapshot buildWorkspaceSessionSnapshot({
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
  return WorkspaceSessionSnapshot(
    id: id,
    title: title ?? _buildWorkspaceSessionTitle(transcript, history),
    createdAt: createdAt ?? now,
    updatedAt: updatedAt ?? now,
    provider: provider,
    model: model,
    history: List<ChatMessage>.from(history),
    transcript: List<TranscriptMessage>.from(transcript),
    tags: List<String>.unmodifiable(tags),
  );
}

void writeWorkspaceSession(
  WorkspaceSessionSnapshot snapshot, {
  String? cwd,
}) {
  ensureWorkspaceSessionsDir(cwd: cwd);
  File(workspaceSessionPath(snapshot.id, cwd: cwd)).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
  );
  writeActiveWorkspaceSessionId(snapshot.id, cwd: cwd);
}

WorkspaceSessionSnapshot? readWorkspaceSession(
  String id, {
  String? cwd,
}) {
  final file = File(workspaceSessionPath(id, cwd: cwd));
  if (!file.existsSync()) {
    return null;
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return WorkspaceSessionSnapshot.fromJson(
        Map<String, Object?>.from(decoded),
      );
    }
  } catch (_) {
    // Keep session restore resilient if a file is malformed.
  }
  return null;
}

List<WorkspaceSessionSnapshot> listWorkspaceSessions({String? cwd}) {
  final dir = Directory(workspaceSessionsDir(cwd: cwd));
  if (!dir.existsSync()) {
    return const [];
  }
  final snapshots = <WorkspaceSessionSnapshot>[];
  for (final entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.json')) {
      continue;
    }
    final id = entity.uri.pathSegments.last.replaceAll('.json', '');
    final snapshot = readWorkspaceSession(id, cwd: cwd);
    if (snapshot != null) {
      snapshots.add(snapshot);
    }
  }
  snapshots.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return snapshots;
}

void writeActiveWorkspaceSessionId(
  String id, {
  String? cwd,
}) {
  ensureWorkspaceDataDir(cwd: cwd);
  File(workspaceActiveSessionPath(cwd: cwd)).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({'id': id}),
  );
}

String? readActiveWorkspaceSessionId({String? cwd}) {
  final file = File(workspaceActiveSessionPath(cwd: cwd));
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

String renderWorkspaceSessionMarkdown(WorkspaceSessionSnapshot snapshot) {
  final buffer = StringBuffer();
  buffer.writeln('# ${snapshot.title}');
  buffer.writeln();
  buffer.writeln('- id: ${snapshot.id}');
  buffer.writeln('- provider: ${snapshot.provider}');
  buffer.writeln('- model: ${snapshot.model ?? 'default'}');
  if (snapshot.tags.isNotEmpty) {
    buffer.writeln('- tags: ${snapshot.tags.join(', ')}');
  }
  buffer.writeln('- createdAt: ${snapshot.createdAt}');
  buffer.writeln('- updatedAt: ${snapshot.updatedAt}');
  buffer.writeln();
  buffer.writeln('## Transcript');
  buffer.writeln();
  for (final message in snapshot.transcript) {
    buffer.writeln('### ${message.kind.name}');
    buffer.writeln();
    buffer.writeln(message.text.isEmpty ? '[empty]' : message.text);
    buffer.writeln();
  }
  return buffer.toString().trimRight();
}

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
  final text = json['text'] as String? ?? '';
  switch (json['kind'] as String?) {
    case 'userPrompt':
      return TranscriptMessage.userPrompt(text);
    case 'localCommand':
      return TranscriptMessage.localCommand(text);
    case 'localCommandStdout':
      return TranscriptMessage.localCommandStdout(text);
    case 'localCommandStderr':
      return TranscriptMessage.localCommandStderr(text);
    case 'assistant':
      return TranscriptMessage.assistant(text);
    case 'toolResult':
      return TranscriptMessage.toolResult(text);
    case 'system':
    default:
      return TranscriptMessage.system(text);
  }
}

String _buildWorkspaceSessionTitle(
  List<TranscriptMessage> transcript,
  List<ChatMessage> history,
) {
  for (final message in transcript) {
    if (message.kind == TranscriptMessageKind.userPrompt &&
        message.text.trim().isNotEmpty) {
      return _truncateWorkspaceSessionTitle(message.text.trim());
    }
  }
  for (final message in history) {
    if (message.role == MessageRole.user && message.text.trim().isNotEmpty) {
      return _truncateWorkspaceSessionTitle(message.text.trim());
    }
  }
  return 'Session ${DateTime.now().toUtc().toIso8601String()}';
}

String _truncateWorkspaceSessionTitle(String raw) {
  final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= 60) {
    return collapsed;
  }
  return '${collapsed.substring(0, 57)}...';
}
