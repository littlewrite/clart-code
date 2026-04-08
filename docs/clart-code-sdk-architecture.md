# Clart Code SDK 架构与边界

> 时间：2026-04-08
>
> 目的：用当前代码状态说明 Dart SDK 的入口、运行时分层、以及它和 CLI / Claude Code 产品层之间的边界。

## 目标

- 保留现有 CLI，不把 CLI/TUI 当作当前 SDK 工作的主线。
- 让 `ClartCodeAgent` 成为稳定的高层程序化入口。
- 让 tool loop、session、MCP、skills、最小 subagent 都通过 SDK surface 暴露。
- 继续参考 `./claude-code`、`./claudecode`、`/Users/th/Node/open-agent-sdk-typescript`，但只对齐适合 Dart SDK 的 public API，不照搬产品层逻辑。

## 入口

- SDK 入口：`lib/clart_code_sdk.dart`
- CLI 入口：`lib/clart_code.dart`

当前两条入口并行存在：

- CLI 继续服务命令行使用场景。
- SDK 面向测试、程序化调用、以及未来可能重做的轻量 UI。

## 当前公开能力

SDK 当前已公开这些主能力域：

- `ClartCodeAgent` 高层 API
- top-level `query()` / `prompt()` / `runSubagent()`
- request / output control
- session 持久化与 continue helper
- provider 抽象
- tool loop 与最小 custom tool DSL
- MCP registry / manager / SDK in-process helper
- skills registry / loader / runtime constraints
- named agents / 最小 subagent public API
- hooks / cancellation / observability

## 运行时分层

### 1. SDK facade

主要文件：

- `lib/src/sdk/clart_code_agent.dart`
- `lib/src/sdk/sdk_models.dart`
- `lib/src/sdk/sdk_helpers.dart`
- `lib/src/sdk/session_store.dart`

职责：

- 组装 provider、tool executor、MCP、skills、agents
- 对外提供 `query()`、`prompt()`、`runSubagent()` 等高层调用
- 维护会话、history、stream/result 聚合、runtime hooks

### 2. Core runtime

主要文件：

- `lib/src/core/models.dart`
- `lib/src/core/transcript.dart`
- `lib/src/core/runtime_error.dart`
- `lib/src/core/turn_executor.dart`

职责：

- request / response / usage / error 的底层模型
- transcript 与 runtime message 基础抽象
- 单轮执行和 provider 结果归一化

### 3. Provider abstraction

主要文件：

- `lib/src/providers/llm_provider.dart`
- `lib/src/providers/provider_strategy.dart`

职责：

- 统一 local / Claude / OpenAI provider surface
- 处理 provider-native tool calling、streaming、usage、rate limit 信息
- 把 provider 差异归一化回 SDK runtime

### 4. Tool platform

主要文件：

- `lib/src/tools/tool_models.dart`
- `lib/src/tools/tool_executor.dart`
- `lib/src/tools/builtin_tools.dart`
- `lib/src/tools/tool_permissions.dart`
- `lib/src/tools/mcp_tools.dart`
- `lib/src/tools/skill_tool.dart`
- `lib/src/tools/agent_tool.dart`

职责：

- 统一 builtin / custom / MCP / skill / agent 工具
- 做权限决策、执行调度、错误归一化
- 把 tool result 回注到 agent loop

### 5. MCP / Skills / Agents 扩展层

主要文件：

- `lib/src/mcp/*`
- `lib/src/skills/*`
- `lib/src/agents/*`

职责：

- 作为 tool loop 之上的扩展能力层
- 保持“最小可编程”语义，不向 CLI/TUI 产品层扩张

## 边界判断

当前明确属于 SDK 主线：

- Agent facade
- request / output control
- session API
- provider abstraction
- tool platform
- permission semantics
- hooks
- MCP integration
- skills
- 最小 subagent orchestration

当前明确不纳入 SDK 主线：

- CLI command 系统
- TUI / rich 输入编辑 / fullscreen UI
- slash command UI
- workflow / cron / monitor
- IDE / plugin / OAuth / bridge / remote session
- 重型 team/coordinator/swarm 产品形态

## 当前真实状态

和早期 Phase 1 文档不同，当前 SDK 已经不再停留在“只有 agent + session + stream 协议”的阶段。

当前已经成立的闭环包括：

- provider-native tool calling + fallback tool loop
- direct custom tool registration 与最小 `tool()` / `defineTool()` DSL
- session helper 与 continue helper
- skills registry / loader / `skill` tool
- named agents / `agent` tool / `runSubagent()`
- `status` / `compact_boundary` 的最小 observability runtime producer

## 当前仍然缺的层

- `createAgent()`、`setPermissionMode()`、`setMaxThinkingTokens()`、`getApiType()` 这类 agent facade convenience API
- 真正的 compact service，而不只是 `status` / `compact_boundary` 边界事件
- 更强的 typed tool helper 与更大的 builtin tool 覆盖
- MCP `sse/http/ws` runtime transport
- `SendMessageTool`、background/resume、team 等更深一层 orchestration

## 推荐阅读顺序

- 使用方式：`docs/clart-code-sdk-usage.md`
- 能力对照：`docs/clart-code-sdk-feature-matrix.md`
- 完成度判断：`docs/clart-code-sdk-completeness-review.md`
- 下一步优先级：`docs/clart-code-sdk-roadmap.md`
