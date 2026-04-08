import 'dart:io';

import '../core/models.dart';
import 'skill_models.dart';

Future<List<ClartCodeSkillDefinition>> loadSkillsDir(String dirPath) async {
  final directory = Directory(dirPath);
  if (!await directory.exists()) {
    return const [];
  }

  final skills = <ClartCodeSkillDefinition>[];
  await for (final entity
      in directory.list(recursive: true, followLinks: false)) {
    if (entity is! File || _basename(entity.path) != 'SKILL.md') {
      continue;
    }
    final definition = await _loadSkillFile(entity);
    if (definition != null) {
      skills.add(definition);
    }
  }
  return skills;
}

Future<ClartCodeSkillDefinition?> _loadSkillFile(File file) async {
  final raw = await file.readAsString();
  final parsed = _parseFrontmatter(raw);
  final body = parsed.body.trim();
  if (body.isEmpty) {
    return null;
  }

  final skillDir = file.parent.path;
  final fallbackName = _basename(skillDir);
  final frontmatter = parsed.frontmatter;
  final name = (frontmatter[_FrontmatterKeys.name] ??
          frontmatter[_FrontmatterKeys.displayName] ??
          fallbackName)
      .trim();
  if (name.isEmpty) {
    return null;
  }

  final description =
      (frontmatter[_FrontmatterKeys.description] ?? _extractDescription(body))
          .trim();
  if (description.isEmpty) {
    return null;
  }

  final aliases = _parseStringList(
    frontmatter[_FrontmatterKeys.aliases] ??
        frontmatter[_FrontmatterKeys.alias],
  );
  final allowedTools = _parseStringList(
    frontmatter[_FrontmatterKeys.allowedTools] ??
        frontmatter[_FrontmatterKeys.allowedToolsAlt],
  );
  final disallowedTools = _parseStringList(
    frontmatter[_FrontmatterKeys.disallowedTools] ??
        frontmatter[_FrontmatterKeys.disallowedToolsAlt],
  );
  final agent = _normalize(frontmatter[_FrontmatterKeys.agent]);
  final userInvocable = _parseBool(
    frontmatter[_FrontmatterKeys.userInvocable] ??
        frontmatter[_FrontmatterKeys.userInvocableAlt],
    defaultValue: true,
  );
  final context = _parseContext(frontmatter[_FrontmatterKeys.context]);
  final model = _normalize(frontmatter[_FrontmatterKeys.model]);
  final effort =
      parseClartCodeReasoningEffort(frontmatter[_FrontmatterKeys.effort]);
  final disableModelInvocation = _parseBool(
    frontmatter[_FrontmatterKeys.disableModelInvocation] ??
        frontmatter[_FrontmatterKeys.disableModelInvocationAlt],
    defaultValue: false,
  );
  final cascadeAssistantDeltas = _parseBool(
    frontmatter[_FrontmatterKeys.cascadeAssistantDeltas] ??
        frontmatter[_FrontmatterKeys.cascadeAssistantDeltasAlt],
    defaultValue: false,
  );
  final whenToUse = _normalize(
    frontmatter[_FrontmatterKeys.whenToUse] ??
        frontmatter[_FrontmatterKeys.whenToUseAlt],
  );
  final argumentHint = _normalize(
    frontmatter[_FrontmatterKeys.argumentHint] ??
        frontmatter[_FrontmatterKeys.argumentHintAlt],
  );

  return ClartCodeSkillDefinition(
    name: name,
    description: description,
    aliases: aliases,
    whenToUse: whenToUse,
    argumentHint: argumentHint,
    allowedTools: allowedTools,
    disallowedTools: disallowedTools,
    agent: agent,
    model: model,
    effort: effort,
    disableModelInvocation: disableModelInvocation,
    userInvocable: userInvocable,
    context: context,
    cascadeAssistantDeltas: cascadeAssistantDeltas,
    metadata: {
      'source': 'directory',
      'path': file.path,
      'baseDir': skillDir,
    },
    getPrompt: (args, context) async {
      final buffer = StringBuffer()
        ..writeln('Base directory for this skill: $skillDir');
      final normalizedArgs = args.trim();
      if (normalizedArgs.isNotEmpty) {
        buffer
          ..writeln()
          ..writeln('Arguments: $normalizedArgs');
      }
      buffer
        ..writeln()
        ..writeln(body);
      return [ClartCodeSkillContentBlock.text(buffer.toString().trimRight())];
    },
  );
}

_ParsedSkillFile _parseFrontmatter(String raw) {
  if (!raw.startsWith('---')) {
    return _ParsedSkillFile(frontmatter: const {}, body: raw);
  }

  final lines = raw.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') {
    return _ParsedSkillFile(frontmatter: const {}, body: raw);
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
    return _ParsedSkillFile(frontmatter: const {}, body: raw);
  }

  return _ParsedSkillFile(
    frontmatter: frontmatter,
    body: lines.sublist(closingIndex + 1).join('\n'),
  );
}

String _extractDescription(String body) {
  final normalized = body.replaceAll('\r\n', '\n');
  final paragraphs = normalized.split('\n\n');
  for (final paragraph in paragraphs) {
    final candidate = paragraph
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .join(' ')
        .trim();
    if (candidate.isNotEmpty) {
      return candidate;
    }
  }
  return '';
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

ClartCodeSkillExecutionContext _parseContext(String? raw) {
  final normalized = _normalize(raw)?.toLowerCase();
  if (normalized == 'fork') {
    return ClartCodeSkillExecutionContext.fork;
  }
  return ClartCodeSkillExecutionContext.inline;
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

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments =
      normalized.split('/').where((segment) => segment.isNotEmpty).toList();
  return segments.isEmpty ? path : segments.last;
}

class _ParsedSkillFile {
  const _ParsedSkillFile({
    required this.frontmatter,
    required this.body,
  });

  final Map<String, String> frontmatter;
  final String body;
}

abstract final class _FrontmatterKeys {
  static const name = 'name';
  static const displayName = 'display_name';
  static const description = 'description';
  static const alias = 'alias';
  static const aliases = 'aliases';
  static const whenToUse = 'when_to_use';
  static const whenToUseAlt = 'when-to-use';
  static const argumentHint = 'argument_hint';
  static const argumentHintAlt = 'argument-hint';
  static const allowedTools = 'allowed_tools';
  static const allowedToolsAlt = 'allowed-tools';
  static const disallowedTools = 'disallowed_tools';
  static const disallowedToolsAlt = 'disallowed-tools';
  static const agent = 'agent';
  static const model = 'model';
  static const effort = 'effort';
  static const disableModelInvocation = 'disable_model_invocation';
  static const disableModelInvocationAlt = 'disable-model-invocation';
  static const cascadeAssistantDeltas = 'cascade_assistant_deltas';
  static const cascadeAssistantDeltasAlt = 'cascade-assistant-deltas';
  static const userInvocable = 'user_invocable';
  static const userInvocableAlt = 'user-invocable';
  static const context = 'context';
}
