import '../tools/tool_models.dart';
import 'mcp_types.dart';

McpSdkServerConfig createSdkMcpServer({
  required String name,
  String version = '1.0.0',
  List<Tool> tools = const [],
}) {
  return McpSdkServerConfig(
    name: name,
    version: version,
    tools: tools,
  );
}

class McpSdkServerConfig extends McpServerConfig {
  factory McpSdkServerConfig({
    required String name,
    String version = '1.0.0',
    List<Tool> tools = const [],
  }) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(
          name, 'name', 'MCP server name cannot be empty');
    }
    final normalizedVersion = version.trim();
    if (normalizedVersion.isEmpty) {
      throw ArgumentError.value(
        version,
        'version',
        'MCP server version cannot be empty',
      );
    }
    _validateUniqueToolNames(normalizedName, tools);
    return McpSdkServerConfig._(
      name: normalizedName,
      version: normalizedVersion,
      tools: List<Tool>.unmodifiable(List<Tool>.from(tools)),
    );
  }

  McpSdkServerConfig._({
    required super.name,
    required this.version,
    required this.tools,
  });

  final String version;
  final List<Tool> tools;

  @override
  McpTransportType get transportType => McpTransportType.sdk;

  @override
  Map<String, Object?> toJson() {
    throw UnsupportedError(
      'In-process SDK MCP servers cannot be persisted to the JSON registry.',
    );
  }

  McpConnection toConnection() {
    return McpConnection(
      name: name,
      status: McpServerStatus.connected,
      config: this,
      capabilities: McpServerCapabilities(
        tools: tools.isNotEmpty,
      ),
      serverInfo: McpServerInfo(
        name: name,
        version: version,
      ),
    );
  }
}

void _validateUniqueToolNames(String serverName, List<Tool> tools) {
  final seen = <String>{};
  for (final tool in tools) {
    final name = tool.name.trim();
    if (name.isEmpty) {
      throw ArgumentError(
        'SDK MCP server "$serverName" contains a tool with an empty name',
      );
    }
    if (!seen.add(name)) {
      throw ArgumentError(
        'duplicate tool name in SDK MCP server "$serverName": $name',
      );
    }
  }
}
