/// MCP 客户端实现
/// 实现 Model Context Protocol 的核心方法
import 'dart:async';

import 'json_rpc.dart';
import 'mcp_stdio_transport.dart';
import 'mcp_types.dart';

/// MCP 客户端
class McpClient {
  McpClient({
    required this.config,
  });

  final McpStdioServerConfig config;
  McpStdioTransport? _transport;
  McpServerCapabilities? _capabilities;
  McpServerInfo? _serverInfo;

  McpServerCapabilities? get capabilities => _capabilities;
  McpServerInfo? get serverInfo => _serverInfo;
  bool get isConnected => _transport != null;

  /// 连接到 MCP 服务器
  Future<void> connect() async {
    if (_transport != null) {
      throw StateError('Already connected');
    }

    _transport = McpStdioTransport(config: config);
    await _transport!.connect();

    // 发送 initialize 请求
    final request = JsonRpcRequest(
      method: 'initialize',
      params: {
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'roots': {'listChanged': true},
          'sampling': {},
        },
        'clientInfo': {
          'name': 'clart-code',
          'version': '0.3.0',
        },
      },
    );

    final response = await _transport!.sendRequest(request);

    if (response.isError) {
      await disconnect();
      throw Exception('Initialize failed: ${response.error}');
    }

    final result = response.result as Map<String, Object?>;
    _capabilities = McpServerCapabilities.fromJson(
      result['capabilities'] as Map<String, Object?>? ?? {},
    );
    _serverInfo = result['serverInfo'] != null
        ? McpServerInfo.fromJson(result['serverInfo'] as Map<String, Object?>)
        : null;

    // 发送 initialized 通知
    await _transport!.sendNotification(
      const JsonRpcNotification(method: 'notifications/initialized'),
    );
  }

  /// 列出可用工具
  Future<List<McpTool>> listTools() async {
    _ensureConnected();

    final request = JsonRpcRequest(method: 'tools/list');
    final response = await _transport!.sendRequest(request);

    if (response.isError) {
      throw Exception('List tools failed: ${response.error}');
    }

    final result = response.result as Map<String, Object?>;
    final toolsJson = result['tools'] as List? ?? [];

    return toolsJson
        .cast<Map<String, Object?>>()
        .map((json) => McpTool.fromJson(json))
        .toList();
  }

  /// 调用工具
  Future<Map<String, Object?>> callTool({
    required String name,
    Map<String, Object?>? arguments,
  }) async {
    _ensureConnected();

    final request = JsonRpcRequest(
      method: 'tools/call',
      params: {
        'name': name,
        if (arguments != null) 'arguments': arguments,
      },
    );

    final response = await _transport!.sendRequest(request);

    if (response.isError) {
      throw Exception('Tool call failed: ${response.error}');
    }

    return response.result as Map<String, Object?>;
  }

  /// 列出可用资源
  Future<List<McpResource>> listResources() async {
    _ensureConnected();

    final request = JsonRpcRequest(method: 'resources/list');
    final response = await _transport!.sendRequest(request);

    if (response.isError) {
      throw Exception('List resources failed: ${response.error}');
    }

    final result = response.result as Map<String, Object?>;
    final resourcesJson = result['resources'] as List? ?? [];

    return resourcesJson
        .cast<Map<String, Object?>>()
        .map((json) => McpResource.fromJson(json))
        .toList();
  }

  /// 读取资源内容
  Future<McpResourceContent> readResource(String uri) async {
    _ensureConnected();

    final request = JsonRpcRequest(
      method: 'resources/read',
      params: {'uri': uri},
    );

    final response = await _transport!.sendRequest(request);

    if (response.isError) {
      throw Exception('Read resource failed: ${response.error}');
    }

    final result = response.result as Map<String, Object?>;
    final contentsJson = result['contents'] as List? ?? [];

    if (contentsJson.isEmpty) {
      throw Exception('No content returned for resource: $uri');
    }

    return McpResourceContent.fromJson(
      contentsJson.first as Map<String, Object?>,
    );
  }

  /// 断开连接
  Future<void> disconnect() async {
    await _transport?.close();
    _transport = null;
    _capabilities = null;
    _serverInfo = null;
  }

  void _ensureConnected() {
    if (_transport == null) {
      throw StateError('Not connected');
    }
  }
}
