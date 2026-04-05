# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在此代码仓库中工作时提供指导。

## 项目概述

Clart-code 是 Claude Code 的 Dart 实现，从原始的 TypeScript 代码库迁移而来（原始代码位于 `claudecode/` 目录供参考）。项目目前处于 MVP+ 级别（完成度 80%），测试通过率 164/165。

`claudecode/` 是 sourcemap转出来的源码，所以他可能会丢失一些细节。`claude-code/` 是人工校验补全后能运行的代码。所以，你的工作主要围绕 `claudecode/` 展开，如果遇到不清楚，或者感觉代码不全，那么就需要去 `claude-code/` 目录下看看能运行的代码是怎样的。

## 常用命令

> 我使用了 fvm 管理 dart，flutter 环境，执行命令时请带上 fvm

### 运行应用
```bash
# 运行 CLI
fvm dart run bin/clart_code.dart

# 或使用 Flutter Version Manager
fvm dart run bin/clart_code.dart

# 带参数运行（例如 REPL 模式）
fvm dart run bin/clart_code.dart repl
```

### 测试
```bash
# 运行所有测试
dart test

# 运行特定测试文件
dart test test/core/query_engine_test.dart

# 运行测试并生成覆盖率报告
dart test --coverage
```

### 代码质量
```bash
# 运行静态分析
dart analyze

# 格式化代码
dart format lib/ test/ bin/

# 自动修复格式问题
dart fix --apply
```

### 开发
```bash
# 获取依赖
dart pub get

# 更新依赖
dart pub upgrade
```

## 架构概览

### 核心执行流程

应用采用分层架构，关注点清晰分离：

1. **CLI 层** (`lib/src/cli/`)
   - `runner.dart` - 主 CLI 入口，命令注册和分发
   - `command_registry.dart` - 命令注册系统
   - `repl_command_dispatcher.dart` - REPL 专用命令处理
   - `provider_setup.dart` - 交互式 provider 配置
   - `mcp_commands.dart` - MCP 服务器管理命令

2. **核心 Query 引擎** (`lib/src/core/`)
   - `query_engine.dart` - 主查询执行引擎（同步和流式）
   - `query_loop.dart` - 多轮对话循环，包含续轮逻辑
   - `turn_executor.dart` - 单轮执行，支持流式和中断处理
   - `process_user_input.dart` - 用户输入处理和验证
   - `transcript.dart` - 对话历史管理

3. **Provider 层** (`lib/src/providers/`)
   - `llm_provider.dart` - LLM provider 抽象基类
   - 实现类：`LocalEchoProvider`、`ClaudeApiProvider`、`OpenAiApiProvider`
   - `sse_parser.dart` - 流式响应的 Server-Sent Events 解析
   - `http_retry.dart` - 带指数退避的 HTTP 重试逻辑

4. **Tool 系统** (`lib/src/tools/`)
   - `tool_executor.dart` - Tool 执行编排
   - `tool_registry.dart` - 动态 tool 注册和查找
   - `tool_scheduler.dart` - Tool 调度（当前串行，计划支持并行）
   - `tool_permissions.dart` - 权限检查和策略执行
   - `builtin_tools.dart` - 内置工具（read、write、shell）
   - `mcp_tools.dart` - MCP tool 包装器和资源访问

5. **Task 系统** (`lib/src/tasks/`)
   - `task_executor.dart` - 后台任务执行
   - `task_store.dart` - 任务状态管理
   - `task_models.dart` - 任务数据模型

6. **MCP 集成** (`lib/src/mcp/`)
   - `json_rpc.dart` - JSON-RPC 2.0 协议实现
   - `mcp_types.dart` - MCP 类型定义（服务器、工具、资源）
   - `mcp_client.dart` - MCP 客户端（initialize、tools/list、tools/call、resources/*）
   - `mcp_stdio_transport.dart` - 子进程通信的 Stdio 传输
   - `mcp_manager.dart` - 多服务器连接管理器，支持持久化

7. **Runtime** (`lib/src/runtime/`)
   - `app_runtime.dart` - 依赖注入容器，管理 providers、tools 和 services

### 关键架构模式

**事件驱动流式处理**：Query 引擎使用流式事件模型，包含 `turnStart`、`providerDelta`、`assistant`、`error` 和 `done` 等事件。这允许实时 UI 更新和中断处理。

**Provider 抽象**：所有 LLM provider 实现相同的 `LlmProvider` 接口，提供同步（`run()`）和流式（`runStream()`）方法。这使得可以轻松切换 provider 而无需更改核心逻辑。

**Tool 执行管道**：Tool 经过以下管道：注册 → 权限检查 → 调度 → 执行 → 结果处理。调度器当前串行执行 tool，但设计上支持未来的并行执行。

**MCP 集成**：MCP 服务器通过持久化到 `.clart/mcp_servers.json` 的注册表管理。来自 MCP 服务器的 tool 动态注册到 tool registry，与内置 tool 一起显示。

**配置系统**：配置存储在 `.clart/config.json`，包括 provider 设置（API keys、base URLs、models）、workspace 状态和 MCP 服务器注册表。

## 重要实现细节

### Provider 配置
- 默认 provider 是 `local`（echo 模式），不需要 API keys
- 用户必须运行 `/init` 命令来配置真实 provider（OpenAI 或 Claude）
- 启动时检查 provider 状态，如果未配置会提示用户
- 配置持久化，下次运行时自动加载

### REPL 交互
- REPL 支持纯文本和富 UI 两种模式
- Ctrl+C 中断流式响应但不结束会话
- 命令以 `/` 开头（例如 `/init`、`/help`、`/model`）
- 富模式正确处理 UTF-8 和 CJK 字符，支持 2 列宽度

### Tool 系统
- Tool 在 `ToolRegistry` 中注册，包含名称、描述和执行器
- 执行前通过 `ToolPermissionPolicy` 进行权限检查
- MCP tool 包装在 `McpToolWrapper` 中，桥接 MCP 和 Clart tool 接口
- 内置 tool：`read`、`write`、`shell`（stub）

### MCP 服务器管理
- 通过 `mcp add <name> <command> [args...]` 添加服务器
- 启动时自动连接已注册的服务器
- 来自已连接服务器的 tool 动态注册
- 可通过 `mcp resources` 和 `mcp read <uri>` 访问资源

## 测试策略

测试按模块组织：
- `test/core/` - 核心引擎测试（query_engine、turn_executor、input_processor）
- `test/providers/` - Provider 测试（llm_provider、http_retry、sse_parser）
- `test/tools/` - Tool 系统测试（registry、permissions、scheduler、executor）
- `test/tasks/` - Task 系统测试
- `test/mcp/` - MCP 集成测试（json_rpc、types、manager）

测试使用标准 Dart `test` 包，通过 `setUp`/`tearDown` 管理状态。

## 参考文档

详细实现说明请参阅：
- `docs/claudecode-mvp-minimal-flow.md` - MVP 功能范围和启动流程
- `docs/mcp-implementation.md` - MCP 集成架构
- `docs/progress-update-2026-04-05.md` - 最新进度总结
- `docs/dart_status.md` - Dart 实现完整度评估

## TypeScript 参考

原始 TypeScript 实现位于 `claudecode/` 目录，可作为以下参考：
- 功能完整度对比
- 实现模式
- 边界情况处理

当前 TS→Dart 映射核心功能约完成 70%。
