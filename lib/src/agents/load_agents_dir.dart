import 'dart:io';

import '../core/models.dart';
import '../sdk/sdk_models.dart';

Future<List<ClartCodeAgentDefinition>> loadAgentsDir(String dirPath) async {
  final directory = Directory(dirPath);
  if (!await directory.exists()) {
    return const [];
  }

  final agents = <ClartCodeAgentDefinition>[];
  await for (final entity
      in directory.list(recursive: true, followLinks: false)) {
    if (entity is! File || !_isMarkdownFile(entity.path)) {
      continue;
    }
    final definition = await _loadAgentFile(entity);
    if (definition != null) {
      agents.add(definition);
    }
  }
  return agents;
}

Future<ClartCodeAgentDefinition?> _loadAgentFile(File file) async {
  final raw = await file.readAsString();
  final parsed = _parseFrontmatter(raw);
  final body = parsed.body.trim();
  if (body.isEmpty) {
    return null;
  }

  final frontmatter = parsed.frontmatter;
  final name = _normalize(frontmatter[_FrontmatterKeys.name]);
  final description = _normalize(frontmatter[_FrontmatterKeys.description]);
  if (name == null || description == null) {
    return null;
  }

  final agentDir = file.parent.path;
  final allowedTools = _parseStringList(
    frontmatter[_FrontmatterKeys.tools] ??
        frontmatter[_FrontmatterKeys.allowedTools] ??
        frontmatter[_FrontmatterKeys.allowedToolsAlt] ??
        frontmatter[_FrontmatterKeys.allowedToolsCamel],
  );
  final disallowedTools = _parseStringList(
    frontmatter[_FrontmatterKeys.disallowedTools] ??
        frontmatter[_FrontmatterKeys.disallowedToolsAlt] ??
        frontmatter[_FrontmatterKeys.disallowedToolsCamel],
  );
  final model = _normalize(frontmatter[_FrontmatterKeys.model]);
  final effort =
      parseClartCodeReasoningEffort(frontmatter[_FrontmatterKeys.effort]);
  final inheritMcp = _parseBool(
    frontmatter[_FrontmatterKeys.inheritMcp] ??
        frontmatter[_FrontmatterKeys.inheritMcpAlt] ??
        frontmatter[_FrontmatterKeys.inheritMcpSnake],
    defaultValue: true,
  );
  final cascadeAssistantDeltas = _parseBool(
    frontmatter[_FrontmatterKeys.cascadeAssistantDeltas] ??
        frontmatter[_FrontmatterKeys.cascadeAssistantDeltasAlt] ??
        frontmatter[_FrontmatterKeys.cascadeAssistantDeltasCamel],
    defaultValue: false,
  );

  final buffer = StringBuffer()
    ..writeln('Base directory for this agent: $agentDir')
    ..writeln()
    ..writeln(body);

  return ClartCodeAgentDefinition(
    name: name,
    description: description,
    prompt: buffer.toString().trimRight(),
    allowedTools: allowedTools.isEmpty ? null : allowedTools,
    disallowedTools: disallowedTools,
    model: model,
    effort: effort,
    inheritMcp: inheritMcp,
    cascadeAssistantDeltas: cascadeAssistantDeltas,
  );
}

bool _isMarkdownFile(String path) {
  final normalized = path.toLowerCase();
  return normalized.endsWith('.md') || normalized.endsWith('.markdown');
}

_ParsedAgentFile _parseFrontmatter(String raw) {
  if (!raw.startsWith('---')) {
    return _ParsedAgentFile(frontmatter: const {}, body: raw);
  }

  final lines = raw.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') {
    return _ParsedAgentFile(frontmatter: const {}, body: raw);
  }

  final frontmatter = <String, String>{};
  var closingIndex = -1;
  for (var index = 1; index < lines.length; index++) {
    final line = lines[index];
    if (line.trim() == '---') {
      closingIndex = index;
      break;
    }
    final separator = line.indexOf(':');
    if (separator <= 0) {
      continue;
    }
    final key = line.substring(0, separator).trim();
    final value = line.substring(separator + 1).trim();
    if (key.isNotEmpty) {
      frontmatter[key] = value;
    }
  }

  if (closingIndex < 0) {
    return _ParsedAgentFile(frontmatter: const {}, body: raw);
  }

  return _ParsedAgentFile(
    frontmatter: frontmatter,
    body: lines.sublist(closingIndex + 1).join('\n'),
  );
}

List<String> _parseStringList(String? raw) {
  final normalized = _normalize(raw);
  if (normalized == null) {
    return const [];
  }

  final value = normalized.startsWith('[') && normalized.endsWith(']')
      ? normalized.substring(1, normalized.length - 1)
      : normalized;
  final items = value
      .split(',')
      .map((item) => item.trim())
      .map(_stripQuotes)
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
  return List<String>.unmodifiable(items);
}

bool _parseBool(String? raw, {required bool defaultValue}) {
  final normalized = _normalize(raw);
  if (normalized == null) {
    return defaultValue;
  }
  switch (normalized.toLowerCase()) {
    case 'true':
    case 'yes':
    case 'on':
      return true;
    case 'false':
    case 'no':
    case 'off':
      return false;
    default:
      return defaultValue;
  }
}

String? _normalize(String? raw) {
  if (raw == null) {
    return null;
  }
  final value = _stripQuotes(raw.trim());
  return value.isEmpty ? null : value;
}

String _stripQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1).trim();
  }
  return value;
}

class _ParsedAgentFile {
  const _ParsedAgentFile({
    required this.frontmatter,
    required this.body,
  });

  final Map<String, String> frontmatter;
  final String body;
}

abstract final class _FrontmatterKeys {
  static const name = 'name';
  static const description = 'description';
  static const tools = 'tools';
  static const allowedTools = 'allowed_tools';
  static const allowedToolsAlt = 'allowed-tools';
  static const allowedToolsCamel = 'allowedTools';
  static const disallowedTools = 'disallowed_tools';
  static const disallowedToolsAlt = 'disallowed-tools';
  static const disallowedToolsCamel = 'disallowedTools';
  static const model = 'model';
  static const effort = 'effort';
  static const inheritMcp = 'inherit_mcp';
  static const inheritMcpAlt = 'inherit-mcp';
  static const inheritMcpSnake = 'inheritMcp';
  static const cascadeAssistantDeltas = 'cascade_assistant_deltas';
  static const cascadeAssistantDeltasAlt = 'cascade-assistant-deltas';
  static const cascadeAssistantDeltasCamel = 'cascadeAssistantDeltas';
}
