# Clart Code SDK 工作日志

> 用途：记录 SDK 线的阶段结果、当前断点、下次继续的第一步。

约束补记：

- 除非用户明确提出，否则当前工作默认只推进 SDK，不启动 CLI 对接 SDK 的落地。

## 2026-04-07 / Stage B session interrupt / queued input 最小语义

本轮完成：

- 更新 `lib/src/sdk/clart_code_agent.dart`
  - agent 现在会对并发 `query()/prompt()` 做 session 内串行化
  - 新增最小 queue 语义：
    - 后续 prompt 会排队等待当前 active run 完成
    - `interrupt()` 会只打断当前 active run
    - active run 被 interrupt 后，queued run 会自动继续消费
  - 新增 `queuedInputCount`
  - 新增 `clearQueuedInputs()`
  - queued run 在开始前被取消时，会返回稳定 cancelled terminal result
- 保留边界：
  - 仍然只是 SDK 级最小 session queue
  - 还不是 Claude Code 那种前台输入/后台任务/permission prompt 共享的完整状态机
  - 也还没有更细的 queued-input 专门事件流

新增测试：

- 更新 `test/sdk/clart_code_agent_test.dart`
  - 并发 prompt 自动串行排队
  - `clearQueuedInputs()` 只取消 pending queue，不影响 active run
  - `interrupt()` 打断当前 run 后，queued prompt 自动继续执行
- 补跑回归：
  - `test/sdk/sdk_helpers_test.dart`
  - `test/sdk/session_store_test.dart`

验证记录：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/src/sdk/clart_code_agent.dart lib/src/sdk/sdk_models.dart test/sdk/clart_code_agent_test.dart`
- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart test test/sdk/clart_code_agent_test.dart`
- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart test test/sdk/sdk_helpers_test.dart test/sdk/session_store_test.dart`

当前剩余断点：

- session interrupt / queued input 已有最小 SDK 语义，但还没有完整状态事件面
- 如果继续只做 SDK，下一步优先级可以切到 `MCP transport` 的 CLI 收尾，或再评估更细 builtin input/error 约束

## 2026-04-07 / Stage B hooks 细化

本轮完成：

- 更新 `lib/src/sdk/sdk_models.dart`
  - 新增更细粒度 hooks/event：
    - `onModelTurnStart`
    - `onModelTurnEnd`
    - `onToolPermissionDecision`
    - `onCancelledTerminal`
  - 新增事件模型：
    - `ClartCodeModelTurnStartEvent`
    - `ClartCodeModelTurnEndEvent`
    - `ClartCodeToolPermissionEvent`
    - `ClartCodeCancelledTerminalEvent`
- 更新 `lib/src/sdk/clart_code_agent.dart`
  - agent 主循环现在会在每轮 provider turn 前后发出 turn hooks
  - permission 决策现在会明确区分来源：
    - `resolveToolPermission`
    - `canUseTool`
  - cancellation terminal 现在会保留 stop reason，并通过专门 hook 发出
- 取消路径小幅收口：
  - `_stoppedError()` 现在会携带更具体的 cancellation reason
  - `stop(reason: ...)` 的原因会继续流入 terminal cancelled event

新增测试：

- 更新 `test/sdk/clart_code_agent_test.dart`
  - 覆盖 model turn start/end hook 顺序与载荷
  - 覆盖 `onToolPermissionDecision`
  - 覆盖 `onCancelledTerminal` 与 stop reason 回流

验证记录：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/src/sdk/sdk_models.dart lib/src/sdk/clart_code_agent.dart test/sdk/clart_code_agent_test.dart test/sdk/sdk_helpers_test.dart`
- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart test test/sdk/clart_code_agent_test.dart test/sdk/sdk_helpers_test.dart`
- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart test test/tools/tool_scheduler_test.dart`

当前剩余断点：

- 更细粒度 hooks / permission decision 已基本收口
- 下一步应直接进入更完整的 session interrupt / queued input / cancellation 语义
- `MCP transport` 的 CLI 收尾继续后置

## 2026-04-07 / `P0-5 MCP tool/resource` 错误语义补齐

本轮完成：

- 更新 `lib/src/mcp/mcp_types.dart`
  - 新增结构化 `McpOperationException`
  - 稳定区分：
    - `invalid_tool_name`
    - `invalid_resource_uri`
    - `server_not_connected`
    - `unsupported_transport`
    - `tool_not_found`
    - `resource_not_found`
    - `mcp_call_failed`
    - `mcp_read_failed`
    - `mcp_list_resources_failed`
- 更新 `lib/src/mcp/mcp_client.dart`
  - 不再只抛零散字符串异常
  - `tools/call` / `resources/read` / `resources/list` 现在会产出结构化 MCP error
  - `resources/read` 返回空 contents 时也会收敛到稳定的 `resource_not_found`
- 更新 `lib/src/mcp/mcp_manager.dart`
  - `callTool()` / `readResource()` 不再只用裸 `Exception`
  - 现在可区分：
    - server 未连接
    - unsupported transport
    - invalid tool/resource 标识
- 更新 `lib/src/tools/mcp_tools.dart`
  - `McpToolWrapper` / `McpReadResourceTool` / `McpListResourcesTool` 统一输出稳定 error code
  - MCP 返回 `isError` 时，稳定返回 `mcp_tool_error`
  - tool/resource/list failure 现在都会带 MCP metadata
- 更新 `lib/src/sdk/sdk_models.dart`
- 更新 `lib/src/sdk/clart_code_agent.dart`
  - `tool_result` 现在会透传 `metadata`
  - agent transcript / provider 看到的 tool payload 不再只剩 `error_code` / `error_message`

新增测试：

- 新增 `test/tools/mcp_tools_test.dart`
  - MCP tool success
  - MCP `isError`
  - `tool_not_found`
  - read resource success/failure
  - list resources failure
- 更新 `test/mcp/mcp_manager_test.dart`
  - invalid tool/resource format
  - server 未连接
  - unsupported transport
- 更新 `test/sdk/clart_code_agent_test.dart`
  - MCP tool `isError` metadata 回流到 transcript / tool payload
  - MCP resource failure metadata 回流到 transcript / tool payload

验证记录：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/src/mcp/mcp_types.dart lib/src/mcp/mcp_client.dart lib/src/mcp/mcp_manager.dart lib/src/tools/mcp_tools.dart lib/src/sdk/sdk_models.dart lib/src/sdk/clart_code_agent.dart test/tools/mcp_tools_test.dart test/mcp/mcp_manager_test.dart test/sdk/clart_code_agent_test.dart`
- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart test test/tools/mcp_tools_test.dart test/mcp/mcp_manager_test.dart test/sdk/clart_code_agent_test.dart`

当前剩余断点：

- `P0-5` 在 SDK 范围内已收尾
- 下一步应回到更细粒度 hooks / permission decision / interrupt
- `MCP transport` 的 CLI 收尾仍后置

## 2026-04-07 / `P0-4 builtin tools` 第一批补齐

本轮完成：

- 更新 `lib/src/tools/builtin_tools.dart`
  - `shell` 已从 stub 改为真实执行
  - 支持：
    - `command`
    - 可选 `cwd`
    - 可选 `env`
    - 可选 `timeoutMs`
  - 成功时返回真实 stdout/stderr 聚合输出与 metadata
  - 失败时返回稳定错误码：
    - `invalid_input`
    - `spawn_failed`
    - `command_failed`
    - `timeout`
- builtin file tools 现在可绑定 SDK session cwd
  - `read`
  - `write`
- 新增 builtin tools：
  - `edit`
  - `glob`
  - `grep`
- 更新 `lib/src/tools/tool_executor.dart`
  - `ToolExecutor.minimal()` 现在默认包含：
    - `read`
    - `write`
    - `edit`
    - `glob`
    - `grep`
    - `shell`
- 更新 `lib/src/sdk/clart_code_agent.dart`
  - agent 默认 builtin tool executor 现在会绑定到 session cwd
  - `shell pwd`
  - `glob`
  - `grep`
  - `edit`
  都按 SDK cwd 语义执行

新增测试：

- 新增 `test/tools/builtin_tools_test.dart`
  - relative `read/write`
  - real `shell`
  - non-zero exit code
  - timeout
  - `edit`
  - `glob`
  - `grep`
- 更新 `test/sdk/clart_code_agent_test.dart`
  - `write + shell` 闭环改为真实 shell cwd 断言
  - 新增 `edit + glob + grep` agent 闭环

当前剩余断点：

- builtin tools 第一批已可用，但输入约束与错误语义仍可继续细化
- 下一步应直接进入 `P0-5 MCP tool/resource` 错误语义补齐

## 2026-04-07 / `P0-3 Tool public API` 补强

本轮完成：

- 更新 `lib/src/tools/tool_models.dart`
  - `ToolInvocation` 新增 `id`
  - `ToolInvocation` 新增 `copyWith()`
  - `ToolExecutionResult` 新增 `metadata`
  - `ToolExecutionResult` 新增 `copyWith()`
  - `Tool` 新增可选 metadata getter：
    - `title`
    - `annotations`
- 更新 `lib/src/tools/tool_registry.dart`
  - 新增 `copy()`
  - 新增 `merged()`
- 更新 `lib/src/tools/tool_executor.dart`
  - 新增 `ToolExecutor.fromTools()`
  - 新增 `withAdditionalTools()`
- 更新 `lib/src/tools/tool_scheduler.dart`
  - permission resolver 不再只返回 allow/deny 枚举
  - 现在可返回 `ToolPermissionResolution`
  - 可携带 deny message
  - 可携带 rewritten invocation
- 更新 `lib/src/sdk/sdk_models.dart`
  - `ClartCodeAgentOptions` 新增 `tools`
  - `ClartCodeAgentOptions` 新增 `resolveToolPermission`
  - 新增 `ClartCodeToolPermissionOutcome`
  - `ClartCodeToolDefinition` 新增：
    - `title`
    - `annotations`
- 更新 `lib/src/sdk/clart_code_agent.dart`
  - SDK 用户现在可直接通过 `options.tools` 注册 custom tools
  - `resolveToolPermission` 可重写 invocation input
  - `resolveToolPermission` 的 deny message 会透传到 tool result
  - 旧 `canUseTool` 路径继续兼容保留

新增测试：

- `test/tools/tool_registry_test.dart`
  - `copy()`
  - `merged()`
- `test/tools/tool_scheduler_test.dart`
  - permission resolver 重写 invocation input
  - permission resolver deny message
- `test/sdk/clart_code_agent_test.dart`
  - `options.tools` 直接注册 custom tool
  - custom tool metadata 暴露到 `toolDefinitions`
  - `resolveToolPermission` 重写输入
  - `resolveToolPermission` deny message 回流

当前剩余断点：

- `shell` 仍是 stub，SDK tool public API 已够用，但 builtin tool 面还不够真实
- 下一步应直接进入 `P0-4 builtin tools`，优先替换 stub shell

## 2026-04-07 / `P0-2 MCP transport` SDK 语义收缩

本轮完成：

- 更新 `lib/src/mcp/mcp_types.dart`
  - 显式区分 registry 可识别 transport 与 runtime 正式支持 transport
  - 新增 `mcpRegistryTransportTypes`
  - 新增 `mcpRuntimeSupportedTransportTypes`
  - `McpServerConfig` 现在可直接判断 `isRuntimeSupported`
- 更新 `lib/src/mcp/mcp_manager.dart`
  - 暴露 `recognizedTransportTypes` / `supportedTransportTypes`
  - unsupported transport 错误文案现在明确包含“当前 Dart runtime 只支持 stdio”
- 更新 `lib/src/sdk/clart_code_agent.dart`
  - 新增 `prepare()`
  - 新增 `mcpConnections`
  - 新增 `failedMcpConnections`
  - SDK 调用方不必再靠“tool 没注入”来猜 MCP 初始化失败原因

新增测试：

- `test/mcp/mcp_manager_test.dart`
  - canonical `http` config 可被 parser 识别，但会被标记为 runtime unsupported
  - malformed registry error 语义
  - manager 暴露 recognized vs supported transport
- `test/sdk/clart_code_agent_test.dart`
  - `prepare()` 可在不发 prompt 的情况下完成 MCP runtime 初始化
  - canonical registry 下 unsupported transport 会出现在 `mcpConnections` / `failedMcpConnections`

当前剩余断点：

- CLI 仍未收紧 `mcp add` 的 transport 写入面
- `/mcp` 与 `export` 的 transport 展示口径仍属于 CLI 收尾工作
- 因当前约束是优先 SDK，这两项继续后置

## 2026-04-07 / `P0-1 MCP registry` 对齐

本轮完成：

- 新增 `lib/src/mcp/mcp_registry.dart`
  - 统一解析 canonical `{"mcpServers": {...}}`
  - 兼容旧 SDK `{"servers": {...}}`
  - 兼容旧 CLI `[{name, transport, target}]`
  - 统一写回 canonical `mcpServers`
- 扩展 `lib/src/mcp/mcp_types.dart`
  - 为 registry 层补了 `sse/http/ws` config model
  - `McpServerConfig` 现在带 `transportType`
- 更新 `lib/src/mcp/mcp_manager.dart`
  - registry 读写统一走 `McpRegistry`
  - `connect()` 现在可明确把非 `stdio` transport 标记为 failed，而不是隐式假装已支持
- 更新 `lib/src/cli/workspace_store.dart`
  - `WorkspaceMcpServer` 视图保留
  - 但底层 `.clart/mcp_servers.json` 现在改为 canonical `mcpServers` 格式
  - 旧 list format 仍可被读取

新增测试：

- `test/mcp/mcp_registry_test.dart`
  - canonical `mcpServers`
  - legacy `servers`
  - legacy CLI list format
  - command split/join helper
- `test/mcp/mcp_manager_test.dart`
  - legacy CLI list format load
  - unsupported transport -> failed connection
- `test/clart_code_test.dart`
  - `/mcp` 写盘后的 registry 文件已断言为 canonical `mcpServers`
  - `mcp add` + `export` 后的 registry 文件也已断言为 canonical `mcpServers`

验证记录：

- `dart format lib/src/mcp/mcp_types.dart lib/src/mcp/mcp_registry.dart lib/src/mcp/mcp_manager.dart lib/src/cli/workspace_store.dart test/mcp/mcp_manager_test.dart test/mcp/mcp_registry_test.dart test/clart_code_test.dart`
- `DART_SUPPRESS_ANALYTICS=true dart test test/mcp/mcp_manager_test.dart test/mcp/mcp_registry_test.dart test/clart_code_test.dart`
- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/src/mcp/mcp_types.dart lib/src/mcp/mcp_registry.dart lib/src/mcp/mcp_manager.dart lib/src/cli/workspace_store.dart test/mcp/mcp_manager_test.dart test/mcp/mcp_registry_test.dart test/clart_code_test.dart`

当前剩余断点：

- CLI 仍然允许写入 `sse/http/ws`，但 runtime 只会把它们标成 unsupported
- 下一步应继续 `P0-2 transport` 语义收缩，避免对外继续伪装成这些 transport 已正式可用

## 2026-04-07 / `tools + MCP` 设计拆解

本轮目标：

- 不直接继续写功能代码。
- 先把 `tools + MCP` 的实现起点拆成可执行任务。
- 尤其确认 `MCP` 为什么必须先于其它补强项开始。

本轮核对结果：

- SDK agent 当前通过 `lib/src/sdk/clart_code_agent.dart` 在启动时读取 `.clart/mcp_servers.json`
- `lib/src/mcp/mcp_manager.dart` 当前读取的是 `{"servers": {...}}`
- CLI `lib/src/cli/workspace_store.dart` / `lib/src/cli/runner.dart` 当前写的是 `[{name, transport, target}]`
- 仓库根目录 `.mcp.json` 则是 `{"mcpServers": {...}}` 口径
- Dart runtime 当前真正可用的 transport 只有 `stdio`
- 但类型与 CLI 仍然暴露了 `sse/http/ws`

本轮结论：

- `tools + MCP` 的方向判断不变，仍然是下一阶段 P0。
- 但首个真实开工点不应是“补更多 MCP 功能”或“先写 shell tool”。
- 最合理的起点是先修 `MCP registry` 对齐问题。

原因：

- registry format 不统一时，MCP 无法作为稳定 SDK 扩展层存在
- transport 语义不真实时，CLI、SDK、文档会继续互相矛盾
- 这两个点不先收敛，后面补 tool public API 与 builtin tools 仍会带着隐性返工

本轮文档更新：

- `docs/clart-code-sdk-next-capabilities-plan.md`
  - 新增 `tools + MCP` 的具体实现设计拆解
  - 明确 `P0-1` 到 `P0-6` 的任务顺序与收尾标准
- `docs/clart-code-sdk-roadmap.md`
  - 把下一轮优先顺序改为先 `MCP registry`，再补 tools
- `docs/clart-code-sdk-feature-matrix.md`
  - 把 `MCP tools/resources` 从“已完成”修正为“部分完成”

下一步建议直接按这个顺序开工：

1. `P0-1 MCP registry` 对齐
2. `P0-2 transport` 语义收缩
3. `P0-3 tool public API` 补强
4. `P0-4 builtin tools` 第一批补齐
5. `P0-5 MCP tool/resource` 错误语义与测试

下次开工前优先先看：

- `docs/clart-code-sdk-next-capabilities-plan.md`
- `lib/src/mcp/mcp_manager.dart`
- `lib/src/cli/workspace_store.dart`
- `lib/src/cli/runner.dart`
- `lib/src/tools/tool_executor.dart`
- `lib/src/tools/builtin_tools.dart`

## 2026-04-07 / SDK 能力审计与边界纠偏

本轮目标：

- 不继续顺着“补更多 SDK 功能”往下做。
- 先重新梳理 `./claude-code`、`./claudecode`、`open-agent-sdk-typescript` 与当前 Dart SDK 的关系。
- 先把“哪些能力应该进入 SDK，哪些不应该”写实。

本轮结论：

- `claude-code` / `claudecode` 应作为完整产品能力来源，不应直接当作 Dart SDK backlog。
- `open-agent-sdk-typescript` 才是当前 SDK public API 更接近的对照基线。
- Dart 当前 SDK 主方向没有走偏，但 session 持久化此前直接依赖 CLI 的 `workspace_store.dart`，这是一个明确的结构性耦合点。

本轮文档更新：

- 新增 `docs/clart-code-sdk-capability-audit.md`
- 重写 `docs/clart-code-sdk-feature-matrix.md`
- 重写 `docs/clart-code-sdk-roadmap.md`
- 更新 `docs/clart-code-sdk-architecture.md`

本轮代码纠偏：

- `lib/src/sdk/session_store.dart` 不再依赖 `lib/src/cli/workspace_store.dart`
- `lib/src/sdk/clart_code_agent.dart` 改为直接使用 SDK 自己的 session snapshot/build/save 流程
- 继续复用 `.clart/sessions/<id>.json` 与 `active_session.json` 格式，不改变既有工作区数据格式

本轮之后的下一优先级：

1. `ClartCodeAgent` 上的 session metadata convenience API
2. 更细粒度 hooks / permission decision / cancelled terminal event
3. 更完整的 session interrupt / queued input 语义

本轮继续补充：

- `ClartCodeAgent` 已补 session metadata convenience API：
  - `snapshot()`
  - `renameSession()`
  - `setSessionTags()`
  - `addSessionTag()`
  - `removeSessionTag()`
  - `forkSession()`
- 对应测试已补到 `test/sdk/session_store_test.dart`
- 新增下一阶段能力规划文档：
  - `docs/clart-code-sdk-next-capabilities-plan.md`
  - 基于 `./claude-code` 梳理了 `tools` / `skills` / `MCP` / `multi-agent` 的源码入口与建议顺序
  - 明确结论：
    - `tools` / `MCP` 应进入 SDK 主线，且优先级最高
    - `skills` 应进入 SDK，但排在 `tools` / `MCP` 之后
    - `multi-agent` 最终应进入 SDK，但只适合先做最小 subagent API

更新后的下一优先级：

1. `tools + MCP` 补强
2. 更细粒度 hooks / permission decision / cancelled terminal event
3. 更完整的 session interrupt / queued input 语义
4. `skills`
5. `multi-agent` 最小版

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

- 还没有更完整的 session-level interrupt / queued input / 多任务取消协作语义
- MCP 目前已能被 SDK agent 装载，但 CLI 还没有开始反向消费这层 SDK service

## 2026-04-07 / SDK Phase 2-6（本轮继续）

本轮完成：

- 新增 request-scoped cancellation 抽象：
  - `QueryCancellationSignal`
  - `QueryCancellationController`
  - `QueryRequest` 已可携带 cancellation signal
- `QueryEngine` 现在会统一监听 request cancellation：
  - cancel 时自动转发到 provider 的 `cancelActiveRequest()`
  - `run()` 在取消后会返回统一的 cancelled 结果
  - `runStream()` 在 provider 被取消后即使静默结束，也会补发统一的 cancelled terminal error
- `ClartCodeAgent.stop()` 已改为通过 active request cancellation controller 驱动，而不是直接在 agent 层硬调 provider cancel
- OpenAI / Claude provider 的 transport cancel 现在会映射为 `RuntimeErrorCode.cancelled`
- SDK 入口已导出：
  - `QueryCancellationSignal`
  - `QueryCancellationController`

新增测试覆盖：

- `QueryEngine.run()` cancellation -> provider cancel -> cancelled response
- `QueryEngine.runStream()` cancellation -> provider silent end -> cancelled terminal event
- 既有 SDK agent `stop()` 用例继续通过，确认 signal 驱动取消没有回归

补充验证：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/clart_code_sdk.dart lib/src/core/models.dart lib/src/core/query_engine.dart lib/src/providers/llm_provider.dart lib/src/sdk/clart_code_agent.dart test/core/query_engine_test.dart test/providers/llm_provider_test.dart test/sdk/clart_code_agent_test.dart`
- `DART_SUPPRESS_ANALYTICS=true dart test test/core/query_engine_test.dart test/providers/llm_provider_test.dart test/sdk/clart_code_agent_test.dart`

说明：

- `dart test` 仍会打印 Dart telemetry 文件修改时间权限警告，但测试通过，退出码为 `0`。

## 2026-04-07 / SDK Phase 2-5（本轮继续）

本轮完成：

- Claude Messages provider 的 streaming native tool calling 已补齐：
  - 不再在带 `tools` 时回退完整 `run()`
  - 现在会细粒度解析 SSE `content_block_start/delta/stop`
  - `tool_use` 的 `input_json_delta` 会增量拼装，最终产出结构化 `toolCalls`
- SDK provider 抽象新增统一基类：
  - `NativeToolCallingLlmProvider`
  - custom/local provider 如需原生工具闭环，可直接继承该基类，而不是手动覆写 `supportsNativeToolCalling`
  - 默认 `LlmProvider.stream()` 包装路径仍会保留 `QueryResponse.toolCalls`

新增测试覆盖：

- Claude provider streaming `tool_use` / `input_json_delta` 解析
- SDK custom native provider 改为通过统一基类参与 native tool calling

补充验证：

- `HOME=/tmp DART_SUPPRESS_ANALYTICS=true dart analyze lib/clart_code_sdk.dart lib/src/providers/llm_provider.dart lib/src/sdk/clart_code_agent.dart test/providers/llm_provider_test.dart test/sdk/clart_code_agent_test.dart`
- `DART_SUPPRESS_ANALYTICS=true dart test test/providers/llm_provider_test.dart test/sdk/clart_code_agent_test.dart`

说明：

- `dart test` 仍会打印 Dart telemetry 文件修改时间权限警告，但测试通过，退出码为 `0`。

当前剩余断点：

- `stop()` 已能触发 provider transport cancel，但还没有统一成更完整的 interrupt/session cancellation 抽象
- MCP 目前已能被 SDK agent 装载，但 CLI 还没有开始反向消费这层 SDK service
