// MCP 连接管理器
// 管理多个 MCP 服务器连接
import 'dart:async';
import 'dart:io';

import '../tools/tool_models.dart';
import 'mcp_client.dart';
import 'mcp_registry.dart';
import 'sdk_mcp_server.dart';
import 'mcp_types.dart';

/// MCP 管理器
class McpManager {
  McpManager({required this.registryPath});

  final String registryPath;
  final _connections = <String, McpClient>{};
  final _connectionStatus = <String, McpConnection>{};
  final _sdkServers = <String, McpSdkServerConfig>{};

  List<McpTransportType> get recognizedTransportTypes =>
      List<McpTransportType>.unmodifiable(mcpRegistryTransportTypes);

  List<McpTransportType> get supportedTransportTypes =>
      List<McpTransportType>.unmodifiable(mcpRuntimeSupportedTransportTypes);

  /// 加载服务器注册表
  Future<Map<String, McpServerConfig>> loadRegistry() async {
    final file = File(registryPath);
    if (!await file.exists()) {
      return {};
    }

    try {
      final content = await file.readAsString();
      return McpRegistry.fromJsonString(content).servers;
    } catch (e) {
      throw Exception('Failed to load MCP registry: $e');
    }
  }

  /// 保存服务器注册表
  Future<void> saveRegistry(
    Map<String, McpServerConfig> configs,
  ) async {
    final file = File(registryPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(McpRegistry(servers: configs).encodePretty());
  }

  /// 连接到指定服务器
  Future<McpConnection> connect(McpServerConfig config) async {
    final name = config.name;

    // 如果已连接，返回现有连接
    if (_connections.containsKey(name)) {
      return _connectionStatus[name]!;
    }

    // 更新状态为 pending
    _connectionStatus[name] = McpConnection(
      name: name,
      status: McpServerStatus.pending,
      config: config,
    );

    if (config is McpSdkServerConfig) {
      _sdkServers[name] = config;
      final connection = config.toConnection();
      _connectionStatus[name] = connection;
      return connection;
    }

    if (config is! McpStdioServerConfig) {
      final connection = McpConnection(
        name: name,
        status: McpServerStatus.failed,
        config: config,
        error: config.runtimeUnsupportedReason,
      );
      _connectionStatus[name] = connection;
      return connection;
    }

    try {
      final client = McpClient(config: config);
      await client.connect();

      _connections[name] = client;
      final connection = McpConnection(
        name: name,
        status: McpServerStatus.connected,
        config: config,
        capabilities: client.capabilities,
        serverInfo: client.serverInfo,
      );
      _connectionStatus[name] = connection;

      return connection;
    } catch (e) {
      final connection = McpConnection(
        name: name,
        status: McpServerStatus.failed,
        config: config,
        error: e.toString(),
      );
      _connectionStatus[name] = connection;
      return connection;
    }
  }

  /// 连接到所有注册的服务器
  Future<List<McpConnection>> connectAll() async {
    final configs = await loadRegistry();
    final connections = <McpConnection>[];

    for (final config in configs.values) {
      final connection = await connect(config);
      connections.add(connection);
    }

    return connections;
  }

  /// 断开指定服务器
  Future<void> disconnect(String name) async {
    final client = _connections.remove(name);
    await client?.disconnect();
    _sdkServers.remove(name);
    _connectionStatus.remove(name);
  }

  /// 断开所有服务器
  Future<void> disconnectAll() async {
    for (final client in _connections.values) {
      await client.disconnect();
    }
    _connections.clear();
    _sdkServers.clear();
    _connectionStatus.clear();
  }

  /// 获取连接状态
  McpConnection? getConnection(String name) => _connectionStatus[name];

  /// 获取所有连接状态
  List<McpConnection> getAllConnections() => _connectionStatus.values.toList();

  /// 获取客户端
  McpClient? getClient(String name) => _connections[name];

  /// 列出所有工具
  Future<List<McpTool>> listAllTools() async {
    final allTools = <McpTool>[];

    for (final entry in _connections.entries) {
      final client = entry.value;
      if (client.capabilities?.tools == true) {
        try {
          final tools = await client.listTools();
          // 为工具名添加服务器前缀
          final prefixedTools = tools.map((tool) {
            return McpTool(
              name: '${entry.key}/${tool.name}',
              description: tool.description,
              inputSchema: tool.inputSchema,
            );
          }).toList();
          allTools.addAll(prefixedTools);
        } catch (e) {
          // 忽略单个服务器的错误
        }
      }
    }

    for (final entry in _sdkServers.entries) {
      final server = entry.value;
      for (final tool in server.tools) {
        allTools.add(
          McpTool(
            name: '${entry.key}/${tool.name}',
            description: tool.description,
            inputSchema: tool.inputSchema,
          ),
        );
      }
    }

    return allTools;
  }

  /// 列出所有资源
  Future<List<McpResource>> listAllResources() async {
    final allResources = <McpResource>[];

    for (final entry in _connections.entries) {
      final client = entry.value;
      if (client.capabilities?.resources == true) {
        try {
          final resources = await client.listResources();
          // 为资源 URI 添加服务器前缀
          final prefixedResources = resources.map((resource) {
            return McpResource(
              uri: '${entry.key}://${resource.uri}',
              name: resource.name,
              description: resource.description,
              mimeType: resource.mimeType,
            );
          }).toList();
          allResources.addAll(prefixedResources);
        } catch (e) {
          // 忽略单个服务器的错误
        }
      }
    }

    return allResources;
  }

  /// 调用工具（支持 server/tool 格式）
  Future<Map<String, Object?>> callTool({
    required String name,
    Map<String, Object?>? arguments,
  }) async {
    final separatorIndex = name.indexOf('/');
    if (separatorIndex <= 0 || separatorIndex == name.length - 1) {
      throw McpOperationException.invalidToolName(name);
    }

    final serverName = name.substring(0, separatorIndex);
    final toolName = name.substring(separatorIndex + 1);

    final client = _connections[serverName];
    if (client == null) {
      final sdkServer = _sdkServers[serverName];
      if (sdkServer != null) {
        return _callSdkTool(
          server: sdkServer,
          toolName: toolName,
          arguments: arguments,
        );
      }
    }
    if (client == null) {
      throw _buildUnavailableServerError(serverName);
    }

    try {
      return await client.callTool(name: toolName, arguments: arguments);
    } on McpOperationException {
      rethrow;
    } catch (error) {
      throw McpOperationException.toolCallFailed(
        serverName: serverName,
        toolName: toolName,
        message: error.toString(),
      );
    }
  }

  /// 读取资源（支持 server://uri 格式）
  Future<McpResourceContent> readResource(String uri) async {
    final separatorIndex = uri.indexOf('://');
    if (separatorIndex <= 0 || separatorIndex == uri.length - 3) {
      throw McpOperationException.invalidResourceUri(uri);
    }

    final serverName = uri.substring(0, separatorIndex);
    final resourceUri = uri.substring(separatorIndex + 3);

    final client = _connections[serverName];
    if (client == null) {
      throw _buildUnavailableServerError(serverName);
    }

    try {
      return await client.readResource(resourceUri);
    } on McpOperationException {
      rethrow;
    } catch (error) {
      throw McpOperationException.readFailed(
        serverName: serverName,
        resourceUri: resourceUri,
        message: error.toString(),
      );
    }
  }

  McpOperationException _buildUnavailableServerError(String serverName) {
    final connection = _connectionStatus[serverName];
    if (connection != null && !connection.config.isRuntimeSupported) {
      return McpOperationException.unsupportedTransport(
        serverName: serverName,
        transportType: connection.config.transportType,
        message: connection.error ?? connection.config.runtimeUnsupportedReason,
      );
    }
    return McpOperationException.serverNotConnected(
      serverName: serverName,
      connection: connection,
    );
  }

  Future<Map<String, Object?>> _callSdkTool({
    required McpSdkServerConfig server,
    required String toolName,
    Map<String, Object?>? arguments,
  }) async {
    Tool? matchedTool;
    for (final tool in server.tools) {
      if (tool.name == toolName) {
        matchedTool = tool;
        break;
      }
    }
    if (matchedTool == null) {
      throw McpOperationException.toolNotFound(
        serverName: server.name,
        toolName: toolName,
      );
    }

    try {
      final result = await matchedTool.run(
        ToolInvocation(
          name: toolName,
          input: arguments ?? const {},
        ),
      );

      final message = result.ok
          ? result.output
          : (result.errorMessage?.trim().isNotEmpty ?? false)
              ? result.errorMessage!
              : 'SDK MCP tool failed: ${server.name}/$toolName';
      final content = message.isEmpty
          ? const <Map<String, Object?>>[]
          : <Map<String, Object?>>[
              {
                'type': 'text',
                'text': message,
              },
            ];

      return {
        'content': content,
        if (!result.ok) 'isError': true,
        if (result.metadata != null) 'metadata': result.metadata,
      };
    } on McpOperationException {
      rethrow;
    } catch (error) {
      throw McpOperationException.toolCallFailed(
        serverName: server.name,
        toolName: toolName,
        message: error.toString(),
      );
    }
  }
}
