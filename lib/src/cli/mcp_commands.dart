/// MCP 集成到 CLI 命令
/// 提供 MCP 服务器管理命令
import 'dart:io';

import '../mcp/mcp_manager.dart';
import '../mcp/mcp_types.dart';

/// MCP 命令处理器
class McpCommandHandler {
  McpCommandHandler({required this.manager});

  final McpManager manager;

  /// 列出所有 MCP 服务器
  Future<String> listServers() async {
    final connections = manager.getAllConnections();

    if (connections.isEmpty) {
      return 'No MCP servers configured.\n\n'
          'Add servers with: mcp add <name> <command> [args...]';
    }

    final buffer = StringBuffer();
    buffer.writeln('MCP Servers:');
    buffer.writeln();

    for (final conn in connections) {
      final statusIcon = _getStatusIcon(conn.status);
      buffer.writeln('$statusIcon ${conn.name}');

      if (conn.status == McpServerStatus.connected) {
        if (conn.serverInfo != null) {
          buffer.writeln(
            '  Server: ${conn.serverInfo!.name} v${conn.serverInfo!.version}',
          );
        }
        if (conn.capabilities != null) {
          final caps = <String>[];
          if (conn.capabilities!.tools) caps.add('tools');
          if (conn.capabilities!.resources) caps.add('resources');
          if (conn.capabilities!.prompts) caps.add('prompts');
          buffer.writeln('  Capabilities: ${caps.join(", ")}');
        }
      } else if (conn.status == McpServerStatus.failed) {
        buffer.writeln('  Error: ${conn.error ?? "unknown error"}');
      }

      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 添加 MCP 服务器
  Future<String> addServer({
    required String name,
    required String command,
    List<String> args = const [],
    Map<String, String>? env,
  }) async {
    final configs = await manager.loadRegistry();

    if (configs.containsKey(name)) {
      return 'Error: Server "$name" already exists.\n'
          'Use "mcp remove $name" first to replace it.';
    }

    configs[name] = McpStdioServerConfig(
      name: name,
      command: command,
      args: args,
      env: env,
    );

    await manager.saveRegistry(configs);

    return 'Added MCP server: $name\n'
        'Command: $command ${args.join(" ")}\n\n'
        'Connect with: mcp connect $name';
  }

  /// 移除 MCP 服务器
  Future<String> removeServer(String name) async {
    final configs = await manager.loadRegistry();

    if (!configs.containsKey(name)) {
      return 'Error: Server "$name" not found.';
    }

    // 断开连接（如果已连接）
    await manager.disconnect(name);

    configs.remove(name);
    await manager.saveRegistry(configs);

    return 'Removed MCP server: $name';
  }

  /// 连接到 MCP 服务器
  Future<String> connectServer(String name) async {
    final configs = await manager.loadRegistry();
    final config = configs[name];

    if (config == null) {
      return 'Error: Server "$name" not found.\n'
          'Available servers: ${configs.keys.join(", ")}';
    }

    stdout.write('Connecting to $name... ');
    final connection = await manager.connect(config);

    if (connection.status == McpServerStatus.connected) {
      stdout.writeln('✓');
      final buffer = StringBuffer();
      buffer.writeln('Connected to $name');

      if (connection.serverInfo != null) {
        buffer.writeln(
          'Server: ${connection.serverInfo!.name} v${connection.serverInfo!.version}',
        );
      }

      if (connection.capabilities != null) {
        final caps = <String>[];
        if (connection.capabilities!.tools) caps.add('tools');
        if (connection.capabilities!.resources) caps.add('resources');
        if (connection.capabilities!.prompts) caps.add('prompts');
        buffer.writeln('Capabilities: ${caps.join(", ")}');
      }

      return buffer.toString();
    } else {
      stdout.writeln('✗');
      return 'Failed to connect to $name\n'
          'Error: ${connection.error ?? "unknown error"}';
    }
  }

  /// 连接到所有服务器
  Future<String> connectAll() async {
    final connections = await manager.connectAll();

    if (connections.isEmpty) {
      return 'No MCP servers configured.';
    }

    final buffer = StringBuffer();
    buffer.writeln('Connected to ${connections.length} server(s):');
    buffer.writeln();

    for (final conn in connections) {
      final statusIcon = _getStatusIcon(conn.status);
      buffer.writeln('$statusIcon ${conn.name}');
    }

    return buffer.toString();
  }

  /// 断开服务器连接
  Future<String> disconnectServer(String name) async {
    await manager.disconnect(name);
    return 'Disconnected from $name';
  }

  /// 断开所有连接
  Future<String> disconnectAll() async {
    await manager.disconnectAll();
    return 'Disconnected from all servers';
  }

  /// 列出所有工具
  Future<String> listTools() async {
    final tools = await manager.listAllTools();

    if (tools.isEmpty) {
      return 'No tools available.\n'
          'Connect to MCP servers with: mcp connect <name>';
    }

    final buffer = StringBuffer();
    buffer.writeln('Available MCP Tools:');
    buffer.writeln();

    for (final tool in tools) {
      buffer.writeln('• ${tool.name}');
      if (tool.description.isNotEmpty) {
        buffer.writeln('  ${tool.description}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 列出所有资源
  Future<String> listResources() async {
    final resources = await manager.listAllResources();

    if (resources.isEmpty) {
      return 'No resources available.\n'
          'Connect to MCP servers with: mcp connect <name>';
    }

    final buffer = StringBuffer();
    buffer.writeln('Available MCP Resources:');
    buffer.writeln();

    for (final resource in resources) {
      buffer.writeln('• ${resource.uri}');
      buffer.writeln('  Name: ${resource.name}');
      if (resource.description != null) {
        buffer.writeln('  Description: ${resource.description}');
      }
      if (resource.mimeType != null) {
        buffer.writeln('  Type: ${resource.mimeType}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 显示服务器详情
  Future<String> showServer(String name) async {
    final connection = manager.getConnection(name);

    if (connection == null) {
      return 'Error: Server "$name" not found.';
    }

    final buffer = StringBuffer();
    buffer.writeln('Server: ${connection.name}');
    buffer.writeln('Status: ${connection.status.name}');
    buffer.writeln();

    final config = connection.config;
    if (config is McpStdioServerConfig) {
      buffer.writeln('Configuration:');
      buffer.writeln('  Command: ${config.command}');
      if (config.args.isNotEmpty) {
        buffer.writeln('  Args: ${config.args.join(" ")}');
      }
      if (config.env != null && config.env!.isNotEmpty) {
        buffer.writeln('  Environment:');
        for (final entry in config.env!.entries) {
          buffer.writeln('    ${entry.key}=${entry.value}');
        }
      }
      buffer.writeln();
    }

    if (connection.status == McpServerStatus.connected) {
      if (connection.serverInfo != null) {
        buffer.writeln('Server Info:');
        buffer.writeln('  Name: ${connection.serverInfo!.name}');
        buffer.writeln('  Version: ${connection.serverInfo!.version}');
        buffer.writeln();
      }

      if (connection.capabilities != null) {
        buffer.writeln('Capabilities:');
        buffer.writeln('  Tools: ${connection.capabilities!.tools}');
        buffer.writeln('  Resources: ${connection.capabilities!.resources}');
        buffer.writeln('  Prompts: ${connection.capabilities!.prompts}');
      }
    } else if (connection.status == McpServerStatus.failed) {
      buffer.writeln('Error: ${connection.error ?? "unknown error"}');
    }

    return buffer.toString();
  }

  String _getStatusIcon(McpServerStatus status) {
    switch (status) {
      case McpServerStatus.connected:
        return '✓';
      case McpServerStatus.failed:
        return '✗';
      case McpServerStatus.pending:
        return '⋯';
      case McpServerStatus.needsAuth:
        return '🔒';
      case McpServerStatus.disabled:
        return '○';
    }
  }
}
