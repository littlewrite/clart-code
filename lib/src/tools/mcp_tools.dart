/// MCP 工具桥接
/// 将 MCP 工具桥接到 Clart 的 Tool 系统
import '../mcp/mcp_manager.dart';
import '../mcp/mcp_types.dart';
import 'tool_models.dart';

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
  String get description => mcpTool.description;

  @override
  Map<String, Object?>? get inputSchema => mcpTool.inputSchema;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final result = await manager.callTool(
        name: invocation.name,
        arguments: invocation.arguments,
      );

      // MCP 工具返回格式：{ content: [...], isError?: bool }
      final content = result['content'] as List?;
      final isError = result['isError'] as bool? ?? false;

      if (isError) {
        final errorText = _extractTextFromContent(content);
        return ToolExecutionResult.failure(
          tool: invocation.name,
          errorCode: 'mcp_tool_error',
          errorMessage: errorText,
        );
      }

      final outputText = _extractTextFromContent(content);
      return ToolExecutionResult.success(
        tool: invocation.name,
        output: outputText,
      );
    } catch (e) {
      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'mcp_call_failed',
        errorMessage: e.toString(),
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

/// MCP 资源读取工具
class McpReadResourceTool implements Tool {
  McpReadResourceTool({required this.manager});

  final McpManager manager;

  @override
  String get name => 'mcp_read_resource';

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
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    try {
      final uri = invocation.arguments?['uri'] as String?;
      if (uri == null) {
        return ToolExecutionResult.failure(
          tool: name,
          errorCode: 'missing_uri',
          errorMessage: 'uri parameter is required',
        );
      }

      final content = await manager.readResource(uri);

      final output = content.text ?? content.blob ?? '';
      return ToolExecutionResult.success(
        tool: name,
        output: output,
      );
    } catch (e) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'read_failed',
        errorMessage: e.toString(),
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
  String get description =>
      'List all available MCP resources from connected servers';

  @override
  Map<String, Object?>? get inputSchema => {
        'type': 'object',
        'properties': {},
      };

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
    } catch (e) {
      return ToolExecutionResult.failure(
        tool: name,
        errorCode: 'list_failed',
        errorMessage: e.toString(),
      );
    }
  }
}
