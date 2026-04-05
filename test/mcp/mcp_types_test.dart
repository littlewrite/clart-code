import 'package:test/test.dart';
import 'package:clart_code/src/mcp/mcp_types.dart';

void main() {
  group('McpStdioServerConfig', () {
    test('toJson() serializes correctly', () {
      final config = McpStdioServerConfig(
        name: 'test-server',
        command: 'node',
        args: ['server.js'],
        env: {'KEY': 'value'},
      );

      final json = config.toJson();

      expect(json['name'], 'test-server');
      expect(json['type'], 'stdio');
      expect(json['command'], 'node');
      expect(json['args'], ['server.js']);
      expect(json['env'], {'KEY': 'value'});
    });

    test('fromJson() deserializes correctly', () {
      final json = {
        'name': 'test-server',
        'type': 'stdio',
        'command': 'python',
        'args': ['server.py'],
        'env': {'PATH': '/usr/bin'},
      };

      final config = McpStdioServerConfig.fromJson(json);

      expect(config.name, 'test-server');
      expect(config.command, 'python');
      expect(config.args, ['server.py']);
      expect(config.env, {'PATH': '/usr/bin'});
    });
  });

  group('McpServerCapabilities', () {
    test('fromJson() parses capabilities', () {
      final json = {
        'tools': {},
        'resources': {},
      };

      final capabilities = McpServerCapabilities.fromJson(json);

      expect(capabilities.tools, true);
      expect(capabilities.resources, true);
      expect(capabilities.prompts, false);
    });

    test('toJson() serializes capabilities', () {
      final capabilities = McpServerCapabilities(
        tools: true,
        resources: false,
        prompts: true,
      );

      final json = capabilities.toJson();

      expect(json['tools'], {});
      expect(json.containsKey('resources'), false);
      expect(json['prompts'], {});
    });
  });

  group('McpTool', () {
    test('fromJson() parses tool definition', () {
      final json = {
        'name': 'test_tool',
        'description': 'A test tool',
        'inputSchema': {
          'type': 'object',
          'properties': {'arg': {'type': 'string'}},
        },
      };

      final tool = McpTool.fromJson(json);

      expect(tool.name, 'test_tool');
      expect(tool.description, 'A test tool');
      expect(tool.inputSchema, isNotNull);
      expect(tool.inputSchema!['type'], 'object');
    });
  });

  group('McpResource', () {
    test('fromJson() parses resource definition', () {
      final json = {
        'uri': 'file:///test.txt',
        'name': 'Test File',
        'description': 'A test file',
        'mimeType': 'text/plain',
      };

      final resource = McpResource.fromJson(json);

      expect(resource.uri, 'file:///test.txt');
      expect(resource.name, 'Test File');
      expect(resource.description, 'A test file');
      expect(resource.mimeType, 'text/plain');
    });
  });

  group('McpConnection', () {
    test('copyWith() updates fields', () {
      final connection = McpConnection(
        name: 'test',
        status: McpServerStatus.pending,
        config: McpStdioServerConfig(
          name: 'test',
          command: 'node',
        ),
      );

      final updated = connection.copyWith(
        status: McpServerStatus.connected,
        capabilities: McpServerCapabilities(tools: true),
      );

      expect(updated.name, 'test');
      expect(updated.status, McpServerStatus.connected);
      expect(updated.capabilities?.tools, true);
    });
  });
}
