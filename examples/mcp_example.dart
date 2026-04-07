/// MCP 集成示例
/// 展示如何在应用中使用 MCP
import 'dart:io';

import 'package:clart_code/src/mcp/mcp_manager.dart';
import 'package:clart_code/src/mcp/mcp_types.dart';
import 'package:clart_code/src/tools/mcp_tools.dart';
import 'package:clart_code/src/tools/tool_registry.dart';

/// 初始化 MCP 并集成到工具系统
Future<void> initializeMcp({
  required ToolRegistry toolRegistry,
  required String workspaceRoot,
}) async {
  final registryPath = '$workspaceRoot/.clart/mcp_servers.json';
  final manager = McpManager(registryPath: registryPath);

  // 连接到所有配置的 MCP 服务器
  final connections = await manager.connectAll();

  // 注册 MCP 资源工具
  toolRegistry.register(McpListResourcesTool(manager: manager));
  toolRegistry.register(McpReadResourceTool(manager: manager));

  // 为每个连接的服务器注册工具
  for (final conn in connections) {
    if (conn.status == McpServerStatus.connected) {
      final client = manager.getClient(conn.name);
      if (client != null && client.capabilities?.tools == true) {
        final tools = await client.listTools();
        for (final mcpTool in tools) {
          final wrapper = McpToolWrapper(
            mcpTool: mcpTool,
            manager: manager,
          );
          toolRegistry.register(wrapper);
        }
      }
    }
  }
}

/// 示例：添加 MCP 服务器
Future<void> exampleAddServer() async {
  final manager = McpManager(
    registryPath: '.clart/mcp_servers.json',
  );

  // 添加一个示例服务器配置
  final configs = await manager.loadRegistry();
  configs['example'] = McpStdioServerConfig(
    name: 'example',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
  );
  await manager.saveRegistry(configs);

  print('Added example MCP server');
}

/// 示例：连接并使用 MCP 工具
Future<void> exampleUseMcp() async {
  final manager = McpManager(
    registryPath: '.clart/mcp_servers.json',
  );

  // 连接到服务器
  final configs = await manager.loadRegistry();
  if (configs.isEmpty) {
    print('No MCP servers configured');
    return;
  }

  final config = configs.values.first;
  final connection = await manager.connect(config);

  if (connection.status == McpServerStatus.connected) {
    print('Connected to ${connection.name}');

    // 列出工具
    final tools = await manager.listAllTools();
    print('Available tools: ${tools.map((t) => t.name).join(", ")}');

    // 列出资源
    final resources = await manager.listAllResources();
    print('Available resources: ${resources.map((r) => r.uri).join(", ")}');
  } else {
    print('Failed to connect: ${connection.error}');
  }

  await manager.disconnectAll();
}

void main() async {
  // 运行示例
  await exampleAddServer();
  await exampleUseMcp();
}
