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
      final configs = {
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
      expect(loaded['test-server']?.name, 'test-server');
      expect(loaded['test-server']?.command, 'node');
      expect(loaded['test-server']?.args, ['server.js']);
      expect(loaded['test-server']?.env, {'KEY': 'value'});
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

    test('callTool() throws for invalid tool name format', () async {
      expect(
        () => manager.callTool(name: 'invalid-format'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('callTool() throws for non-connected server', () async {
      expect(
        () => manager.callTool(name: 'server/tool'),
        throwsA(isA<Exception>()),
      );
    });

    test('readResource() throws for non-connected server', () async {
      expect(
        () => manager.readResource('server://resource'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
