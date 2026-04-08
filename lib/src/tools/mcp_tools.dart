// MCP 工具桥接
// 将 MCP 工具桥接到 Clart 的 Tool 系统
import '../mcp/mcp_manager.dart';
import '../mcp/mcp_types.dart';
import 'tool_models.dart';

Future<List<Tool>> buildMcpTools({
  required McpManager manager,
  bool includeResourceTools = true,
}) async {
  final tools = <Tool>[];
  final connections = manager.getAllConnections();
  final hasResourceSupport = connections.any(
    (connection) =>
        connection.status == McpServerStatus.connected &&
        connection.capabilities?.resources == true,
  );

  if (includeResourceTools && hasResourceSupport) {
    tools.add(McpListResourcesTool(manager: manager));
    tools.add(McpReadResourceTool(manager: manager));
  }

  final mcpTools = await manager.listAllTools();
  tools.addAll(
    mcpTools.map(
      (mcpTool) => McpToolWrapper(
        mcpTool: mcpTool,
        manager: manager,
      ),
    ),
  );

  return List<Tool>.unmodifiable(tools);
}

/// MCP 工具包装器
class McpToolWrapper implements Tool {
  McpToolWrapper({
    required this.mcpTool,
    required this.manager,
  });

  final McpTool mcpTool;
  final McpManager manager;

  @override
  String get name => mcpTool.name;

  @override
  String? get title => null;

  @override
  String get description => mcpTool.description;

  @override
  Map<String, Object?>? get inputSchema => mcpTool.inputSchema;

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final qualifiedName = _QualifiedToolName.parse(invocation.name);
    try {
      final result = await manager.callTool(
        name: invocation.name,
        arguments: invocation.input,
      );

      // MCP 工具返回格式：{ content: [...], isError?: bool }
      final content = result['content'] as List?;
      final isError = result['isError'] as bool? ?? false;
      final resultMetadata = _coerceMetadataMap(result['metadata']);

      if (isError) {
        final errorText = _extractTextFromContent(content);
        return ToolExecutionResult.failure(
          tool: invocation.name,
          errorCode: 'mcp_tool_error',
          errorMessage:
              errorText.isEmpty ? 'MCP tool returned isError=true' : errorText,
          metadata: {
            'source': 'mcp',
            'serverName': qualifiedName.serverName,
            'toolName': qualifiedName.toolName,
            if (resultMetadata != null) ...resultMetadata,
            'content': List<Object?>.from(content ?? const []),
          },
        );
      }

      final outputText = _extractTextFromContent(content);
      return ToolExecutionResult.success(
              tool: invocation.name, output: outputText)
          .copyWith(
        metadata: resultMetadata == null
            ? null
            : {
                'source': 'mcp',
                'serverName': qualifiedName.serverName,
                'toolName': qualifiedName.toolName,
                ...resultMetadata,
              },
      );
    } on McpOperationException catch (error) {
      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: _mapMcpErrorCode(error.code),
        errorMessage: error.message,
        metadata: error.metadata,
      );
    } on FormatException catch (error) {
      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'invalid_input',
        errorMessage: error.message,
        metadata: {
          'source': 'mcp',
          'tool': invocation.name,
        },
      );
    } catch (e) {
      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'mcp_call_failed',
        errorMessage: e.toString(),
        metadata: {
          'source': 'mcp',
          'serverName': qualifiedName.serverName,
          'toolName': qualifiedName.toolName,
        },
      );
    }
  }

  String _extractTextFromContent(List? content) {
    if (content == null || content.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    for (final item in content) {
      if (item is Map<String, Object?>) {
        final type = item['type'] as String?;
        if (type == 'text') {
          buffer.write(item['text'] ?? '');
        } else if (type == 'resource') {
          final text = item['text'] as String?;
          if (text != null) {
            buffer.write(text);
          }
        }
      }
    }

    return buffer.toString();
  }
}

Map<String, Object?>? _coerceMetadataMap(Object? raw) {
  if (raw is Map) {
    return Map<String, Object?>.from(raw.cast<String, Object?>());
  }
  return null;
}

/// MCP 资源读取工具
class McpReadResourceTool implements Tool {
  McpReadResourceTool({required this.manager});

  final McpManager manager;

  @override
  String get name => 'mcp_read_resource';

  @override
  String? get title => null;

  @override
  String get description =>
      'Read content from an MCP resource. Use format: server://resource_uri';

  @override
  Map<String, Object?>? get inputSchema => {
        'type': 'object',
        'properties': {
          'uri': {
            'type': 'string',
            'description': 'Resource URI in format: server://resource_uri',
          },
        },
        'required': ['uri'],
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final rawUri = invocation.input['uri'];
      if (rawUri is! String || rawUri.trim().isEmpty) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'invalid_input',
          errorMessage: 'uri parameter is required',
        );
      }
      final uri = rawUri.trim();

      final content = await manager.readResource(uri);

      final output = content.text ?? content.blob ?? '';
      return ToolExecutionResult.success(
        tool: name,
        output: output,
      );
    } on McpOperationException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: _mapMcpErrorCode(error.code),
        errorMessage: error.message,
        metadata: error.metadata,
      );
    } catch (e) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'mcp_read_failed',
        errorMessage: e.toString(),
        metadata: const {
          'source': 'mcp',
        },
      );
    }
  }
}

/// MCP 资源列表工具
class McpListResourcesTool implements Tool {
  McpListResourcesTool({required this.manager});

  final McpManager manager;

  @override
  String get name => 'mcp_list_resources';

  @override
  String? get title => null;

  @override
  String get description =>
      'List all available MCP resources from connected servers';

  @override
  Map<String, Object?>? get inputSchema => {
        'type': 'object',
        'properties': {},
      };

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final resources = await manager.listAllResources();

      final buffer = StringBuffer();
      buffer.writeln('Available MCP Resources:');
      for (final resource in resources) {
        buffer.writeln('- ${resource.uri}');
        buffer.writeln('  Name: ${resource.name}');
        if (resource.description != null) {
          buffer.writeln('  Description: ${resource.description}');
        }
        if (resource.mimeType != null) {
          buffer.writeln('  Type: ${resource.mimeType}');
        }
      }

      return ToolExecutionResult.success(
        tool: name,
        output: buffer.toString(),
      );
    } on McpOperationException catch (error) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: _mapMcpErrorCode(error.code),
        errorMessage: error.message,
        metadata: error.metadata,
      );
    } catch (e) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'mcp_list_resources_failed',
        errorMessage: e.toString(),
        metadata: const {
          'source': 'mcp',
        },
      );
    }
  }
}

String _mapMcpErrorCode(String code) {
  switch (code) {
    case 'invalid_tool_name':
    case 'invalid_resource_uri':
      return 'invalid_input';
    default:
      return code;
  }
}

class _QualifiedToolName {
  const _QualifiedToolName({
    required this.serverName,
    required this.toolName,
  });

  factory _QualifiedToolName.parse(String name) {
    final separatorIndex = name.indexOf('/');
    if (separatorIndex <= 0 || separatorIndex == name.length - 1) {
      throw FormatException('MCP tool name must be in format: server/tool');
    }
    return _QualifiedToolName(
      serverName: name.substring(0, separatorIndex),
      toolName: name.substring(separatorIndex + 1),
    );
  }

  final String serverName;
  final String toolName;
}
