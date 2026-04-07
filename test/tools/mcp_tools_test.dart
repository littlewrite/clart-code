import 'dart:async';

import 'package:clart_code/src/mcp/mcp_manager.dart';
import 'package:clart_code/src/mcp/mcp_types.dart';
import 'package:clart_code/src/tools/mcp_tools.dart';
import 'package:clart_code/src/tools/tool_models.dart';
import 'package:test/test.dart';

void main() {
  group('MCP tools', () {
    test('McpToolWrapper returns success output from text content', () async {
      final manager = _StubMcpManager(
        onCallTool: (name, arguments) async => {
          'content': [
            {'type': 'text', 'text': 'remote body'},
          ],
        },
      );
      final tool = McpToolWrapper(
        mcpTool: const McpTool(
          name: 'demo/read_remote',
          description: 'Read a remote file.',
        ),
        manager: manager,
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'demo/read_remote',
          input: const {'path': '/remote/demo.txt'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, 'remote body');
    });

    test('McpToolWrapper returns stable failure for MCP isError payload',
        () async {
      final manager = _StubMcpManager(
        onCallTool: (name, arguments) async => {
          'isError': true,
          'content': [
            {'type': 'text', 'text': 'remote denied'},
          ],
        },
      );
      final tool = McpToolWrapper(
        mcpTool: const McpTool(
          name: 'demo/read_remote',
          description: 'Read a remote file.',
        ),
        manager: manager,
      );

      final result = await tool.run(
        ToolInvocation(
          name: 'demo/read_remote',
          input: const {'path': '/remote/demo.txt'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'mcp_tool_error');
      expect(result.errorMessage, 'remote denied');
      expect(result.metadata?['serverName'], 'demo');
      expect(result.metadata?['toolName'], 'read_remote');
      expect(
        (result.metadata?['content'] as List).first,
        {'type': 'text', 'text': 'remote denied'},
      );
    });

    test('McpToolWrapper passes through structured manager errors', () async {
      final manager = _StubMcpManager(
        onCallTool: (name, arguments) async {
          throw McpOperationException.toolNotFound(
            serverName: 'demo',
            toolName: 'read_remote',
            rpcCode: -32004,
            rpcMessage: 'Tool not found',
          );
        },
      );
      final tool = McpToolWrapper(
        mcpTool: const McpTool(
          name: 'demo/read_remote',
          description: 'Read a remote file.',
        ),
        manager: manager,
      );

      final result = await tool.run(
        ToolInvocation(name: 'demo/read_remote'),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'tool_not_found');
      expect(result.errorMessage, 'MCP tool not found: demo/read_remote');
      expect(result.metadata?['rpcCode'], -32004);
      expect(result.metadata?['rpcMessage'], 'Tool not found');
    });

    test('McpReadResourceTool returns resource body', () async {
      final manager = _StubMcpManager(
        onReadResource: (uri) async => const McpResourceContent(
          uri: 'docs://guide.md',
          mimeType: 'text/plain',
          text: 'guide body',
        ),
      );
      final tool = McpReadResourceTool(manager: manager);

      final result = await tool.run(
        ToolInvocation(
          name: 'mcp_read_resource',
          input: const {'uri': 'docs://guide.md'},
        ),
      );

      expect(result.ok, isTrue);
      expect(result.output, 'guide body');
    });

    test('McpReadResourceTool validates uri input', () async {
      final tool = McpReadResourceTool(manager: _StubMcpManager());

      final result = await tool.run(
        ToolInvocation(
          name: 'mcp_read_resource',
          input: const {},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'invalid_input');
    });

    test('McpReadResourceTool passes through resource not found metadata',
        () async {
      final manager = _StubMcpManager(
        onReadResource: (uri) async {
          throw McpOperationException.resourceNotFound(
            serverName: 'docs',
            resourceUri: 'guide.md',
            rpcCode: -32010,
            rpcMessage: 'Resource not found',
          );
        },
      );
      final tool = McpReadResourceTool(manager: manager);

      final result = await tool.run(
        ToolInvocation(
          name: 'mcp_read_resource',
          input: const {'uri': 'docs://guide.md'},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'resource_not_found');
      expect(result.metadata?['serverName'], 'docs');
      expect(result.metadata?['resourceUri'], 'guide.md');
      expect(result.metadata?['rpcCode'], -32010);
    });

    test('McpListResourcesTool returns structured failure codes', () async {
      final manager = _StubMcpManager(
        onListResources: () async {
          throw McpOperationException.listResourcesFailed(
            serverName: 'docs',
            rpcCode: -32020,
            rpcMessage: 'resources/list unavailable',
          );
        },
      );
      final tool = McpListResourcesTool(manager: manager);

      final result = await tool.run(
        ToolInvocation(name: 'mcp_list_resources'),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'mcp_list_resources_failed');
      expect(result.metadata?['serverName'], 'docs');
      expect(result.metadata?['rpcCode'], -32020);
    });
  });
}

class _StubMcpManager extends McpManager {
  _StubMcpManager({
    this.onCallTool,
    this.onReadResource,
    this.onListResources,
  }) : super(registryPath: '/tmp/mcp_tools_test_registry.json');

  final FutureOr<Map<String, Object?>> Function(
    String name,
    Map<String, Object?>? arguments,
  )? onCallTool;
  final FutureOr<McpResourceContent> Function(String uri)? onReadResource;
  final FutureOr<List<McpResource>> Function()? onListResources;

  @override
  Future<Map<String, Object?>> callTool({
    required String name,
    Map<String, Object?>? arguments,
  }) async {
    if (onCallTool != null) {
      return await onCallTool!(name, arguments);
    }
    return {'content': const []};
  }

  @override
  Future<McpResourceContent> readResource(String uri) async {
    if (onReadResource != null) {
      return await onReadResource!(uri);
    }
    return McpResourceContent(
      uri: uri,
      mimeType: 'text/plain',
      text: '',
    );
  }

  @override
  Future<List<McpResource>> listAllResources() async {
    if (onListResources != null) {
      return await onListResources!();
    }
    return const [];
  }
}
