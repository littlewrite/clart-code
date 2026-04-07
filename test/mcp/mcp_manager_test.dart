import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:clart_code/src/mcp/mcp_manager.dart';
import 'package:clart_code/src/mcp/mcp_types.dart';

void main() {
  group('McpManager', () {
    late Directory tempDir;
    late String registryPath;
    late McpManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mcp_test_');
      registryPath = '${tempDir.path}/mcp_servers.json';
      manager = McpManager(registryPath: registryPath);
    });

    tearDown(() async {
      await manager.disconnectAll();
      await tempDir.delete(recursive: true);
    });

    test('loadRegistry() returns empty map when file does not exist', () async {
      final configs = await manager.loadRegistry();
      expect(configs, isEmpty);
    });

    test('saveRegistry() and loadRegistry() persist configurations', () async {
      final configs = <String, McpServerConfig>{
        'test-server': McpStdioServerConfig(
          name: 'test-server',
          command: 'node',
          args: ['server.js'],
          env: {'KEY': 'value'},
        ),
      };

      await manager.saveRegistry(configs);

      final loaded = await manager.loadRegistry();
      expect(loaded, hasLength(1));
      final config = loaded['test-server'];
      expect(config, isA<McpStdioServerConfig>());
      expect(config?.name, 'test-server');
      expect((config as McpStdioServerConfig).command, 'node');
      expect(config.args, ['server.js']);
      expect(config.env, {'KEY': 'value'});
    });

    test('loadRegistry() parses legacy CLI list format', () async {
      final file = File(registryPath);
      await file.writeAsString(jsonEncode([
        {
          'name': 'legacy',
          'transport': 'stdio',
          'target': 'node server.js',
        },
      ]));

      final loaded = await manager.loadRegistry();
      final config = loaded['legacy'];
      expect(config, isA<McpStdioServerConfig>());
      expect((config as McpStdioServerConfig).command, 'node');
      expect(config.args, ['server.js']);
    });

    test('loadRegistry() keeps recognized but unsupported transports',
        () async {
      final file = File(registryPath);
      await file.writeAsString(jsonEncode({
        'mcpServers': {
          'remote': {
            'type': 'http',
            'url': 'https://example.com/mcp',
          },
        },
      }));

      final loaded = await manager.loadRegistry();
      final config = loaded['remote'];
      expect(config, isA<McpHttpServerConfig>());
      expect(config?.transportType, McpTransportType.http);
      expect(config?.isRuntimeSupported, isFalse);
      expect(
        config?.runtimeUnsupportedReason,
        contains('current Dart runtime supports: stdio'),
      );
    });

    test('loadRegistry() wraps malformed registry errors', () async {
      final file = File(registryPath);
      await file.writeAsString('{"mcpServers": []}');

      await expectLater(
        manager.loadRegistry(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('Failed to load MCP registry'),
          ),
        ),
      );
    });

    test('connect() marks unsupported transports as failed', () async {
      final connection = await manager.connect(
        const McpHttpServerConfig(
          name: 'remote',
          url: 'https://example.com/mcp',
        ),
      );

      expect(connection.status, McpServerStatus.failed);
      expect(connection.error, contains('unsupported MCP transport'));
      expect(
          connection.error, contains('current Dart runtime supports: stdio'));
    });

    test('manager exposes recognized vs runtime supported transports', () {
      expect(
        manager.recognizedTransportTypes,
        containsAll(McpTransportType.values),
      );
      expect(manager.supportedTransportTypes, [McpTransportType.stdio]);
    });

    test('getConnection() returns null for non-existent server', () {
      final connection = manager.getConnection('non-existent');
      expect(connection, isNull);
    });

    test('getAllConnections() returns empty list initially', () {
      final connections = manager.getAllConnections();
      expect(connections, isEmpty);
    });

    test('getClient() returns null for non-existent server', () {
      final client = manager.getClient('non-existent');
      expect(client, isNull);
    });

    test('callTool() returns stable error for invalid tool name format',
        () async {
      expect(
        () => manager.callTool(name: 'invalid-format'),
        throwsA(
          isA<McpOperationException>().having(
            (error) => error.code,
            'code',
            'invalid_tool_name',
          ),
        ),
      );
    });

    test('callTool() returns stable error for non-connected server', () async {
      expect(
        () => manager.callTool(name: 'server/tool'),
        throwsA(
          isA<McpOperationException>()
              .having((error) => error.code, 'code', 'server_not_connected')
              .having(
                (error) => error.metadata['serverName'],
                'serverName',
                'server',
              ),
        ),
      );
    });

    test('readResource() returns stable error for non-connected server',
        () async {
      expect(
        () => manager.readResource('server://resource'),
        throwsA(
          isA<McpOperationException>()
              .having((error) => error.code, 'code', 'server_not_connected')
              .having(
                (error) => error.metadata['serverName'],
                'serverName',
                'server',
              ),
        ),
      );
    });

    test('callTool() distinguishes unsupported transport from not connected',
        () async {
      await manager.connect(
        const McpHttpServerConfig(
          name: 'remote',
          url: 'https://example.com/mcp',
        ),
      );

      expect(
        () => manager.callTool(name: 'remote/tool'),
        throwsA(
          isA<McpOperationException>()
              .having((error) => error.code, 'code', 'unsupported_transport')
              .having(
                (error) => error.metadata['transportType'],
                'transportType',
                'http',
              ),
        ),
      );
    });

    test('readResource() validates uri format', () async {
      expect(
        () => manager.readResource('invalid-resource'),
        throwsA(
          isA<McpOperationException>().having(
            (error) => error.code,
            'code',
            'invalid_resource_uri',
          ),
        ),
      );
    });
  });
}
