// MCP 客户端实现
// 实现 Model Context Protocol 的核心方法
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
      final error = response.error!;
      throw McpOperationException.listToolsFailed(
        serverName: config.name,
        rpcCode: error.code,
        rpcMessage: error.message,
        rpcData: error.data,
      );
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
      final error = response.error!;
      if (_looksLikeNotFound(error.message, kind: 'tool')) {
        throw McpOperationException.toolNotFound(
          serverName: config.name,
          toolName: name,
          rpcCode: error.code,
          rpcMessage: error.message,
          rpcData: error.data,
        );
      }
      throw McpOperationException.toolCallFailed(
        serverName: config.name,
        toolName: name,
        rpcCode: error.code,
        rpcMessage: error.message,
        rpcData: error.data,
      );
    }

    return response.result as Map<String, Object?>;
  }

  /// 列出可用资源
  Future<List<McpResource>> listResources() async {
    _ensureConnected();

    final request = JsonRpcRequest(method: 'resources/list');
    final response = await _transport!.sendRequest(request);

    if (response.isError) {
      final error = response.error!;
      throw McpOperationException.listResourcesFailed(
        serverName: config.name,
        rpcCode: error.code,
        rpcMessage: error.message,
        rpcData: error.data,
      );
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
      final error = response.error!;
      if (_looksLikeNotFound(error.message, kind: 'resource')) {
        throw McpOperationException.resourceNotFound(
          serverName: config.name,
          resourceUri: uri,
          rpcCode: error.code,
          rpcMessage: error.message,
          rpcData: error.data,
        );
      }
      throw McpOperationException.readFailed(
        serverName: config.name,
        resourceUri: uri,
        rpcCode: error.code,
        rpcMessage: error.message,
        rpcData: error.data,
      );
    }

    final result = response.result as Map<String, Object?>;
    final contentsJson = result['contents'] as List? ?? [];

    if (contentsJson.isEmpty) {
      throw McpOperationException.resourceNotFound(
        serverName: config.name,
        resourceUri: uri,
        reason: 'empty_content',
      );
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

  bool _looksLikeNotFound(String message, {required String kind}) {
    final normalized = message.toLowerCase();
    if (normalized.contains('not found')) {
      return kind == 'tool'
          ? normalized.contains('tool') || normalized.contains('name')
          : normalized.contains('resource') ||
              normalized.contains('uri') ||
              normalized.contains('file');
    }
    if (kind == 'tool') {
      return normalized.contains('unknown tool');
    }
    return normalized.contains('unknown resource') ||
        normalized.contains('no resource');
  }
}
