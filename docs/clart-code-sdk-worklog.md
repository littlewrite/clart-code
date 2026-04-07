# Clart Code SDK 工作日志

> 用途：记录 SDK 线的阶段结果、当前断点、下次继续的第一步。

## 2026-04-07 / SDK Phase 1

已完成：

- 新增 SDK 入口：`lib/clart_code_sdk.dart`
- 新增 `ClartCodeAgent`
- 新增 `ClartCodeAgentOptions`
- 新增 `ClartCodeSdkMessage`
- 新增 `ClartCodePromptResult`
- 新增 `ClartCodeSessionStore`
- 新增测试：`test/sdk/clart_code_agent_test.dart`
- 新增文档：
  - `docs/clart-code-sdk-architecture.md`
  - `docs/clart-code-sdk-feature-matrix.md`
  - `docs/clart-code-sdk-roadmap.md`
  - `docs/clart-code-sdk-worklog.md`

当前能力：

- `ClartCodeAgent.query()`
- `ClartCodeAgent.prompt()`
- `ClartCodeAgent.clear()`
- `ClartCodeAgent.setModel()`
- `ClartCodeAgent.close()`
- 基于当前 workspace session 格式的持久化与 resume
- local/claude/openai provider 组装

当前已知边界：

- 还没有完整 tool loop
- 还没有 SDK hook 系统
- 还没有 SDK 级 MCP 注入
- 还没有 top-level `query()` helper
- CLI 还没有迁移成 SDK adapter

验证记录：

- `dart analyze lib/clart_code_sdk.dart lib/src/sdk test/sdk/clart_code_agent_test.dart`
- `dart test test/sdk/clart_code_agent_test.dart`

说明：

- `dart test` 运行时可能打印 Dart 自身 telemetry 文件修改时间的权限警告。
- 当前测试仍然可以通过，退出码为 `0`。
- 这不是 `ClartCodeAgent` 逻辑错误，但后续如要清理，可单独处理 Dart analytics 环境。

## 当前断点

下一步应该进入 Phase 2，而不是继续调整 TUI。

首个落点：

- 定义 SDK 侧 tool public API

原因：

- 目前 `ClartCodeAgent` 只是一层 provider 流封装。
- 只有把 tool loop 接进去，SDK 才真正接近 `open-agent-sdk-typescript` / Claude Code 的核心能力。

## 下次继续的建议顺序

1. 先定义 `SdkToolDefinition` / `SdkToolResult` / tool 事件消息
2. 再让 `ClartCodeAgent` 持有可过滤的 tool pool
3. 然后接入 tool 执行与结果回注
4. 最后补测试和文档

## 下次开工前建议先看的文档

- `docs/clart-code-sdk-feature-matrix.md`
- `docs/clart-code-sdk-roadmap.md`
- `docs/clart-code-sdk-architecture.md`

## 下次开工前建议先看的代码

- `lib/src/sdk/clart_code_agent.dart`
- `lib/src/tools/tool_executor.dart`
- `lib/src/tools/tool_scheduler.dart`
- `lib/src/tools/tool_models.dart`
- `/Users/th/Node/open-agent-sdk-typescript/src/agent.ts`
- `/Users/th/Node/open-agent-sdk-typescript/src/engine.ts`
- `/Users/th/Node/open-agent-sdk-typescript/src/tools/index.ts`

## 不建议的偏移方向

- 不要先去重写 TUI
- 不要先扩大 rich REPL 行为
- 不要先搬运大量 feature-flag 工具
- 不要让 CLI 新功能再次绕过 SDK 直接操作底层 core

## 2026-04-07 / SDK Phase 2（进行中）

本轮已完成：

- 新增 SDK public tool types：
  - `ClartCodeToolDefinition`
  - `ClartCodeToolCall`
  - `ClartCodeToolResult`
- 扩展 `ClartCodeSdkMessage`：
  - `system.init` 现在携带 tool definitions
  - 新增 `tool_call`
  - 新增 `tool_result`
- 扩展 `ClartCodeAgentOptions`：
  - `allowedTools`
  - `disallowedTools`
  - `permissionMode`
  - `maxTurns`
- `ClartCodeAgent` 已接入最小 tool loop：
  - 模型输出 JSON tool plan
  - agent 执行 `ToolExecutor.executeBatch()`
  - 工具结果以 `MessageRole.tool` 回注下一轮模型请求
  - 最终 assistant 响应与 session history/transcript 一起持久化
- tool metadata 已补到内建工具：
  - `read`
  - `write`
  - `shell`

测试新增覆盖：

- `read` tool loop
- batched `write + shell(stub)` tool loop
- `permissionMode: deny` 下的 shell 工具拒绝路径

验证记录：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/clart_code_sdk.dart lib/src/sdk test/sdk/clart_code_agent_test.dart`
- `DART_SUPPRESS_ANALYTICS=true dart test test/sdk/clart_code_agent_test.dart`

说明：

- `dart analyze` 在 `HOME=/tmp` 下可正常通过。
- `dart test` 若同时改成 `HOME=/tmp`，当前环境会因为 `package test` 解析走到远端镜像而失败，这不是 SDK 逻辑问题。
- `dart test` 在默认 `HOME` 下可以通过，但仍会打印 Dart telemetry 文件修改时间的权限警告；退出码为 `0`。

当前剩余断点：

- 还没有 top-level `query()` helper
- 当前 tool loop 使用的是文本 JSON 协议，不是 provider-native tool calling
- `ask` 型 permission 还没有接入交互式决策
- MCP tool/resource 注入还没提升到 SDK 一等公民

补充进展：

- 已把 SDK 内部和文档中的 `ClatCode*` 命名统一纠正为 `ClartCode*`
- 保留了最薄兼容层：
  - `lib/src/sdk/clat_code_agent.dart` 转发到新文件
  - 旧 `ClatCode*` 类型名保留为 deprecated typedef
- 新增 OpenAI-compatible 联调入口：
  - `examples/sdk_openai_agent.dart`
  - `test/sdk/clart_code_agent_live_test.dart`
- `OpenAiApiProvider.stream()` 已补一层退化：
  - 当 SSE 在首个文本 delta 之前失败时，自动回退到 non-stream `/responses`
  - 用于兼容部分网关“stream 失败、普通请求成功”的实现

本轮继续完成：

- 新增 top-level SDK helper：
  - `query({ prompt, options, model })`
  - `prompt({ prompt, options, model })`
- 扩展 `ClartCodeSessionStore`：
  - `fork`
  - `rename`
  - `setTags/addTag/removeTag`
- session snapshot 元数据已扩到 `tags`
- `ClartCodeAgent` 持久化现在会保留被重命名的 `title` 和 `tags`
- SDK 权限与 hooks 已进入 agent 主循环：
  - `permissionMode: ask`
  - `canUseTool`
  - `ClartCodeAgentHooks`
  - `SessionStart/SessionEnd/Stop`
  - `PreToolUse/PostToolUse/PostToolUseFailure`
- `ClartCodeAgent` 已补最小 `stop()`：
  - 当前为 best-effort
  - 中断点位于 provider stream 消费与 tool loop 轮转处
  - 尚不是 provider transport 级硬取消

新增测试覆盖：

- top-level `query()` helper
- top-level `prompt()` helper
- session store `rename/tag/fork`
- resume 后 title/tags 持续保留
- `permissionMode: ask` + `canUseTool` allow 路径
- `permissionMode: ask` + `canUseTool` deny 路径

补充验证：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/clart_code_sdk.dart lib/src/sdk lib/src/providers test/sdk test/providers examples/sdk_openai_agent.dart`
- `DART_SUPPRESS_ANALYTICS=true dart test test/providers/llm_provider_test.dart test/sdk/clart_code_agent_test.dart`
- `OPENAI_API_KEY=*** OPENAI_BASE_URL=https://www.dmxapi.com/v1 OPENAI_MODEL=gpt-4o-mini DART_SUPPRESS_ANALYTICS=true dart test test/sdk/clart_code_agent_live_test.dart`
- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/clart_code_sdk.dart lib/src/sdk lib/src/tools lib/src/cli/workspace_store.dart lib/src/core/runtime_error.dart test/sdk test/tools`
- `DART_SUPPRESS_ANALYTICS=true dart test test/sdk/clart_code_agent_test.dart test/sdk/sdk_helpers_test.dart test/sdk/session_store_test.dart test/tools/tool_scheduler_test.dart test/tools/tool_permissions_test.dart`

下次继续建议：

1. 先做 provider-native tool calling，替换当前文本 JSON plan 协议
2. 再把 MCP tool/resource 注册直接挂进 `ClartCodeAgent`
3. 然后评估 provider 级 interrupt/cancel 接口

## 2026-04-07 / SDK Phase 2-4（本轮继续）

本轮完成：

- 扩展 core/provider 模型：
  - `QueryRequest` 新增 `toolDefinitions`
  - `QueryRequest` / `QueryResponse` / `ProviderStreamEvent` 新增 provider state token
  - `QueryResponse` / `ProviderStreamEvent` 新增结构化 `toolCalls`
- OpenAI-compatible Responses provider 已接入 provider-native tool calling：
  - 请求体带 `tools`
  - `response.completed` / 非流式响应可提取 `function_call`
  - 下一轮通过 `previous_response_id + function_call_output` 继续
- Claude Messages provider 已接入 provider-native tool calling：
  - 请求体带 `tools`
  - assistant/tool 历史可映射回 `tool_use` / `tool_result`
  - 非流式工具闭环已打通；带 tools 的 streaming 当前回退为完整 `run()` 结果
- `ClartCodeAgent` tool loop 现已：
  - 优先消费 provider-native tool calls
  - provider 不支持时仍保留 JSON plan 回退
  - 不再对支持 native tool calling 的 provider 注入文本 tool protocol prompt
- `ClartCodeAgent.stop()` 现已：
  - 除 agent loop 本地 stop flag 外
  - 还会向 provider 发出 active request cancel
  - OpenAI / Claude HTTP 请求会在 stop 时被主动关闭
- SDK agent 已支持 MCP 注入：
  - `ClartCodeMcpOptions`
  - `mcpManagerOverride`（便于测试或外部接管 manager）
  - agent 在首轮 query/prompt 前懒加载 MCP tools/resources
- SDK 入口已导出：
  - `QueryToolDefinition`
  - `QueryToolCall`
  - `McpManager`
  - `mcp_types.dart`

新增测试覆盖：

- OpenAI Responses request body 中 native tools / continuation payload
- OpenAI Responses stream completed 事件中的 native tool call 解析
- Claude request body 中 native tools / `tool_use` / `tool_result` 映射
- Claude provider 非流式 native tool call 提取
- SDK agent 的 provider-native tool calling 路径
- SDK agent 的 MCP tools/resources 注入路径
- SDK agent `stop()` -> provider cancel 路径

补充验证：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/clart_code_sdk.dart lib/src/core/models.dart lib/src/providers/llm_provider.dart lib/src/sdk lib/src/tools/mcp_tools.dart test/providers/llm_provider_test.dart test/sdk/clart_code_agent_test.dart`
- `DART_SUPPRESS_ANALYTICS=true dart test test/providers/llm_provider_test.dart test/sdk/clart_code_agent_test.dart test/sdk/sdk_helpers_test.dart test/sdk/session_store_test.dart`

当前剩余断点：

- local/custom provider 还没有统一成 provider-native tool calling
- Claude 带 tools 的 streaming 当前为正确性优先的 `run()` 回退，还没做细粒度 stream parser
- `stop()` 已能触发 provider transport cancel，但还没有统一成更完整的 interrupt/session cancellation 抽象
- MCP 目前已能被 SDK agent 装载，但 CLI 还没有开始反向消费这层 SDK service
