# Clart Code SDK 路线图

> 时间：2026-04-08
>
> 目标：以 `open-agent-sdk-typescript` 的 public API 为主要基线，继续补齐 Dart SDK 主线能力；默认不启动 CLI/TUI 对接工作。

## 总体原则

- SDK 优先，CLI/TUI 不在当前迭代范围。
- 参考 `open-agent-sdk-typescript` 时，优先对齐 SDK public surface。
- 参考 `./claude-code`、`./claudecode` 时，只提取能力域，不直接继承产品层 backlog。
- 先收口会影响“SDK 是否完备”的 public surface，再考虑扩展型 service。

## 当前判断

当前 Dart SDK 的状态更准确地说是：

- 核心闭环已具备
- public API 仍有几块明显缺口

这里的“核心闭环”指：

- `ClartCodeAgent`
- request / output control 第一层
- session helper
- tool loop
- MCP 最小接入
- skills 最小接入
- named agent / 最小 subagent

## P0：先补真正影响完备度的缺口

### 1. Agent facade convenience API

目标：

- 让 Dart 侧 agent facade 更接近 TS SDK，而不是把能力都埋在 options 与 helper 里

当前仍缺：

- `createAgent()` 风格 factory
- `setPermissionMode()`
- `setMaxThinkingTokens()`
- `getApiType()`

### 2. Observability / compaction runtime

目标：

- 让 observability 不停留在“边界事件已发出，但 runtime 还没真正成立”的中间状态

当前状态：

- `stream_event` / `rate_limit_event` 已有
- `status` / `compact_boundary` 已有最小 live runtime producer

当前仍缺：

- 真正 compact service
- 更细的 interrupt / queued-input / session-state 事件面

### 3. MCP runtime truthfulness

目标：

- 让文档、类型、运行时能力保持一致

当前状态：

- `stdio` / `sdk` 已可用
- `sse/http/ws` 仍不是 runtime 完成

下一步策略：

- 要么继续明确标为 unsupported
- 要么补完整 runtime
- 但不能继续在文档或 surface 上制造“看起来可用”的错觉

## P1：补 SDK 易用性

### 1. 更强的 typed tool helper

当前状态：

- 已有最小 `tool()` / `defineTool()` DSL

仍缺：

- 更顺手的 typed args / result helper
- 更接近 TS helper 生态的注册体验

### 2. 更像 SDK 主线的 builtin tools

优先顺序：

1. `web`
2. `ask-user`
3. `tool-search`
4. `notebook`

说明：

- `todo`、`config`、LSP、plan/worktree/task/team 工具先后置评估
- 其中一部分已经开始更接近扩展型 SDK 或产品层，不应机械当作当前 P0

### 3. 更完整的 permission mode public semantics

当前状态：

- 已有 `allow/deny/ask`
- 已有 `updatedInput`
- 已有 permission decision hook

仍缺：

- 更接近 TS 的 `permissionMode` 语义分层
- ask-user / permission prompt 一类配套能力

## P2：再决定要不要继续做更深的 orchestration

### 1. Skills

当前状态：

- 已有 registry / loader / inline/fork / runtime constraints / hooks integration

下一步：

- 继续扩完整 lifecycle surface
- 继续评估哪些事件需要进入 stream public surface

### 2. Multi-agent

当前状态：

- 已有 `runSubagent()`、named agents、agent registry、`agent` tool、child event merge

下一步：

- 继续补 `SendMessageTool`
- 再评估 background / resume / team 是否值得进入 SDK 主线

## 明确不做

- CLI 命令迁移到 SDK
- rich/fullscreen TUI
- slash command UI
- workflow / cron / monitor
- IDE / plugin / OAuth / bridge / remote session
- 重型 team/coordinator/swarm 模式

## 建议阅读顺序

- API 使用：`docs/clart-code-sdk-usage.md`
- 能力对照：`docs/clart-code-sdk-feature-matrix.md`
- 完成度判断：`docs/clart-code-sdk-completeness-review.md`
- 架构边界：`docs/clart-code-sdk-architecture.md`
