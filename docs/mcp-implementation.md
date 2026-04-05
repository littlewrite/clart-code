# MCP 实现文档

## 概述

已完成 Model Context Protocol (MCP) 基础连接系统的实现，支持通过 stdio 传输与 MCP 服务器通信。

## 架构

### 核心模块

1. **JSON-RPC 层** (`lib/src/mcp/json_rpc.dart`)
   - 实现 JSON-RPC 2.0 协议
   - 支持请求/响应和通知消息
   - 异步请求管理

2. **MCP 类型** (`lib/src/mcp/mcp_types.dart`)
   - MCP 服务器配置（stdio, sse, http, ws）
   - 服务器能力（tools, resources, prompts）
   - 工具和资源定义

3. **MCP 客户端** (`lib/src/mcp/mcp_client.dart`)
   - 连接到 MCP 服务器
   - 实现核心 MCP 方法：
     - `initialize` / `initialized`
     - `tools/list` / `tools/call`
     - `resources/list` / `resources/read`

4. **Stdio 传输** (`lib/src/mcp/mcp_stdio_transport.dart`)
   - 通过子进程 stdin/stdout 通信
   - 自动处理进程生命周期

5. **MCP 管理器** (`lib/src/mcp/mcp_manager.dart`)
   - 管理多个 MCP 服务器连接
   - 服务器注册表持久化（JSON）
   - 统一的工具和资源访问接口

6. **工具桥接** (`lib/src/tools/mcp_tools.dart`)
   - `McpToolWrapper` - 包装 MCP 工具为 Clart Tool
   - `McpReadResourceTool` - 读取 MCP 资源
   - `McpListResourcesTool` - 列出所有资源

7. **CLI 命令** (`lib/src/cli/mcp_commands.dart`)
   - `mcp list` - 列出所有服务器
   - `mcp add <name> <command> [args...]` - 添加服务器
   - `mcp remove <name>` - 移除服务器
   - `mcp connect <name>` - 连接到服务器
   - `mcp disconnect <name>` - 断开连接
   - `mcp tools` - 列出所有工具
   - `mcp resources` - 列出所有资源
   - `mcp show <name>` - 显示服务器详情

## 使用示例

### 添加 MCP 服务器

```bash
# 添加文件系统服务器
dart run bin/clart_code.dart mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /tmp

# 添加自定义服务器
dart run bin/clart_code.dart mcp add myserver node server.js --arg1 value1
```

### 连接和使用

```bash
# 连接到服务器
dart run bin/clart_code.dart mcp connect filesystem

# 列出可用工具
dart run bin/clart_code.dart mcp tools

# 列出可用资源
dart run bin/clart_code.dart mcp resources
```

### 在代码中使用

```dart
import 'package:clart_code/src/mcp/mcp_manager.dart';
import 'package:clart_code/src/tools/mcp_tools.dart';

// 初始化管理器
final manager = McpManager(
  registryPath: '.clart/mcp_servers.json',
);

// 连接到所有服务器
await manager.connectAll();

// 列出工具
final tools = await manager.listAllTools();

// 调用工具（格式：server/tool）
final result = await manager.callTool(
  name: 'filesystem/read_file',
  arguments: {'path': '/tmp/test.txt'},
);

// 读取资源（格式：server://uri）
final content = await manager.readResource('filesystem:///tmp/test.txt');
```

## 集成到现有系统

MCP 工具会自动注册到 `ToolRegistry`，可以像使用内置工具一样使用：

```dart
// 在应用启动时初始化 MCP
await initializeMcp(
  toolRegistry: toolRegistry,
  workspaceRoot: workspaceRoot,
);

// MCP 工具现在可以通过 Tool 系统调用
```

## 测试

所有核心功能都有单元测试覆盖：

```bash
# 运行 MCP 测试
dart test test/mcp/

# 测试覆盖：
# - JSON-RPC 协议（请求/响应/通知）
# - MCP 类型序列化
# - MCP 管理器（注册表、连接管理）
```

## 限制和未来改进

### 当前实现
- ✅ Stdio 传输
- ✅ 基础工具调用
- ✅ 资源读取
- ✅ 服务器注册表

### 未来改进
- ⏳ SSE/HTTP/WebSocket 传输
- ⏳ OAuth 认证
- ⏳ Prompts 支持
- ⏳ 服务器自动重连
- ⏳ 工具调用超时和重试
- ⏳ 更细粒度的权限控制

## 参考

- MCP 规范：https://modelcontextprotocol.io/
- TypeScript SDK：@modelcontextprotocol/sdk
- 官方服务器示例：@modelcontextprotocol/server-*
