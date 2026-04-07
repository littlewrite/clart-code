import 'dart:convert';

import 'package:clart_code/src/mcp/mcp_registry.dart';
import 'package:clart_code/src/mcp/mcp_types.dart';
import 'package:test/test.dart';

void main() {
  group('McpRegistry', () {
    test('parses canonical mcpServers registry', () {
      final registry = McpRegistry.fromJsonString(jsonEncode({
        'mcpServers': {
          'filesystem': {
            'type': 'stdio',
            'command': 'npx',
            'args': ['-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
          },
        },
      }));

      final config = registry.servers['filesystem'];
      expect(config, isA<McpStdioServerConfig>());
      expect((config as McpStdioServerConfig).command, 'npx');
      expect(
        config.args,
        ['-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
      );
    });

    test('parses legacy SDK servers registry', () {
      final registry = McpRegistry.fromJsonString(jsonEncode({
        'servers': {
          'demo': {
            'command': 'node',
            'args': ['server.js'],
          },
        },
      }));

      final config = registry.servers['demo'];
      expect(config, isA<McpStdioServerConfig>());
      expect((config as McpStdioServerConfig).command, 'node');
      expect(config.args, ['server.js']);
    });

    test('parses legacy CLI list registry into canonical configs', () {
      final registry = McpRegistry.fromJsonString(jsonEncode([
        {
          'name': 'demo',
          'transport': 'stdio',
          'target': "node server.js '--flag=value with space'",
        },
        {
          'name': 'remote',
          'transport': 'http',
          'target': 'https://example.com/mcp',
        },
      ]));

      final stdioConfig = registry.servers['demo'];
      expect(stdioConfig, isA<McpStdioServerConfig>());
      expect((stdioConfig as McpStdioServerConfig).command, 'node');
      expect(stdioConfig.args, ['server.js', '--flag=value with space']);

      final httpConfig = registry.servers['remote'];
      expect(httpConfig, isA<McpHttpServerConfig>());
      expect(
          (httpConfig as McpHttpServerConfig).url, 'https://example.com/mcp');
    });

    test('writes canonical mcpServers registry', () {
      final registry = McpRegistry(
        servers: {
          'demo': McpStdioServerConfig(
            name: 'demo',
            command: 'node',
            args: const ['server.js'],
          ),
        },
      );

      final decoded =
          jsonDecode(registry.encodePretty()) as Map<String, dynamic>;
      expect(decoded.keys, ['mcpServers']);
      expect(decoded['mcpServers'], {
        'demo': {
          'type': 'stdio',
          'command': 'node',
          'args': ['server.js'],
        },
      });
    });
  });

  group('command string helpers', () {
    test('splitCommandString respects quotes', () {
      expect(
        splitCommandString("node server.js '--name=hello world' \"two words\""),
        ['node', 'server.js', '--name=hello world', 'two words'],
      );
    });

    test('joinCommandTokens quotes tokens when needed', () {
      expect(
        joinCommandTokens(['node', 'server.js', '--name=hello world']),
        "node server.js '--name=hello world'",
      );
    });
  });
}
