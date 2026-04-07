import 'dart:convert';

import 'mcp_types.dart';

class McpRegistry {
  const McpRegistry({
    this.servers = const {},
  });

  final Map<String, McpServerConfig> servers;

  factory McpRegistry.fromJsonString(String content) {
    final decoded = jsonDecode(content);
    return McpRegistry.fromDecodedJson(decoded);
  }

  factory McpRegistry.fromDecodedJson(Object? decoded) {
    if (decoded is List) {
      return McpRegistry(
        servers: _parseLegacyCliRegistry(decoded),
      );
    }

    if (decoded is! Map) {
      throw const FormatException('MCP registry must be a JSON object or list');
    }

    final json = Map<String, Object?>.from(decoded.cast<String, Object?>());
    final rawServers = json['mcpServers'] ?? json['servers'];
    if (rawServers == null) {
      return const McpRegistry();
    }
    if (rawServers is! Map) {
      throw const FormatException(
          'MCP registry "mcpServers" must be an object');
    }

    final parsed = <String, McpServerConfig>{};
    for (final entry in rawServers.entries) {
      if (entry.value is! Map) {
        throw FormatException(
          'MCP server "${entry.key}" must be a JSON object',
        );
      }
      final config = _serverConfigFromJson(
        entry.key,
        Map<String, Object?>.from(
          (entry.value as Map).cast<String, Object?>(),
        ),
      );
      parsed[entry.key] = config;
    }

    return McpRegistry(servers: parsed);
  }

  String encodePretty() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  Map<String, Object?> toJson() {
    final entries = servers.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return {
      'mcpServers': <String, Object?>{
        for (final entry in entries) entry.key: _configValueJson(entry.value),
      },
    };
  }
}

Map<String, McpServerConfig> _parseLegacyCliRegistry(List<Object?> entries) {
  final parsed = <String, McpServerConfig>{};
  for (final entry in entries) {
    if (entry is! Map) {
      throw const FormatException(
        'Legacy CLI MCP registry entries must be JSON objects',
      );
    }
    final json = Map<String, Object?>.from(entry.cast<String, Object?>());
    final name = (json['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      throw const FormatException(
          'Legacy CLI MCP registry entry requires name');
    }
    final transport = (json['transport'] as String?)?.trim() ?? '';
    final target = (json['target'] as String?)?.trim() ?? '';
    if (target.isEmpty) {
      throw FormatException(
          'Legacy CLI MCP registry entry "$name" missing target');
    }
    parsed[name] = _legacyCliEntryToConfig(
      name: name,
      transport: transport,
      target: target,
    );
  }
  return parsed;
}

McpServerConfig _serverConfigFromJson(
  String name,
  Map<String, Object?> json,
) {
  final normalized = <String, Object?>{
    ...json,
    'name': name,
  };
  final type = (normalized['type'] as String?)?.trim() ?? 'stdio';
  switch (type) {
    case 'stdio':
      return McpStdioServerConfig.fromJson(normalized);
    case 'sse':
      return McpSseServerConfig(
        name: name,
        url: normalized['url'] as String? ?? '',
        headers: (normalized['headers'] as Map?)?.cast<String, String>(),
      );
    case 'http':
      return McpHttpServerConfig(
        name: name,
        url: normalized['url'] as String? ?? '',
        headers: (normalized['headers'] as Map?)?.cast<String, String>(),
      );
    case 'ws':
      return McpWsServerConfig(
        name: name,
        url: normalized['url'] as String? ?? '',
        headers: (normalized['headers'] as Map?)?.cast<String, String>(),
      );
    default:
      throw FormatException('Unsupported MCP transport type: $type');
  }
}

McpServerConfig _legacyCliEntryToConfig({
  required String name,
  required String transport,
  required String target,
}) {
  switch (transport) {
    case 'stdio':
      final tokens = splitCommandString(target);
      if (tokens.isEmpty) {
        throw FormatException('Legacy stdio target for "$name" is empty');
      }
      return McpStdioServerConfig(
        name: name,
        command: tokens.first,
        args: tokens.skip(1).toList(growable: false),
      );
    case 'sse':
      return McpSseServerConfig(name: name, url: target);
    case 'http':
      return McpHttpServerConfig(name: name, url: target);
    case 'ws':
      return McpWsServerConfig(name: name, url: target);
    default:
      throw FormatException('Unsupported legacy MCP transport: $transport');
  }
}

Map<String, Object?> _configValueJson(McpServerConfig config) {
  final json = Map<String, Object?>.from(config.toJson());
  json.remove('name');
  return json;
}

String describeWorkspaceMcpTarget(McpServerConfig config) {
  if (config is McpStdioServerConfig) {
    return joinCommandTokens([
      config.command,
      ...config.args,
    ]);
  }
  if (config is McpSseServerConfig) {
    return config.url;
  }
  if (config is McpHttpServerConfig) {
    return config.url;
  }
  if (config is McpWsServerConfig) {
    return config.url;
  }
  return '';
}

List<String> splitCommandString(String raw) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var inSingleQuote = false;
  var inDoubleQuote = false;
  var escapeNext = false;

  void flush() {
    if (buffer.isEmpty) {
      return;
    }
    tokens.add(buffer.toString());
    buffer.clear();
  }

  for (final rune in raw.runes) {
    final char = String.fromCharCode(rune);
    if (escapeNext) {
      buffer.write(char);
      escapeNext = false;
      continue;
    }
    if (!inSingleQuote && char == '\\') {
      escapeNext = true;
      continue;
    }
    if (!inDoubleQuote && char == "'") {
      inSingleQuote = !inSingleQuote;
      continue;
    }
    if (!inSingleQuote && char == '"') {
      inDoubleQuote = !inDoubleQuote;
      continue;
    }
    if (!inSingleQuote && !inDoubleQuote) {
      final isWhitespace = char.trim().isEmpty;
      if (isWhitespace) {
        flush();
        continue;
      }
    }
    buffer.write(char);
  }
  if (escapeNext) {
    buffer.write(r'\');
  }
  flush();
  return tokens;
}

String joinCommandTokens(List<String> tokens) {
  return tokens.map(_quoteTokenForShellDisplay).join(' ');
}

String _quoteTokenForShellDisplay(String token) {
  if (token.isEmpty) {
    return "''";
  }
  final safe = RegExp(r'^[A-Za-z0-9_./:=+-]+$');
  if (safe.hasMatch(token)) {
    return token;
  }
  return "'${token.replaceAll("'", "'\"'\"'")}'";
}
