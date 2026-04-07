# Clart Code SDK 能力审计

> 目的：先把“什么应该算 SDK 能力、什么不应该算”说清楚，再决定后续补什么。本文只讨论 SDK，不启动 CLI/TUI 迭代。

## 审计基线

本次审计同时参考三类基线，但三者用途不同：

- `./claude-code`、`./claudecode`
  - 用来识别完整产品的能力域来源。
  - 不能把它们的全部命令、UI、bridge、插件、远程能力直接当成 Dart SDK backlog。
- `/Users/th/Node/open-agent-sdk-typescript`
  - 用来识别“什么是 SDK public API”。
  - 这是本轮最重要的对照基线。
- `./lib`
  - 用来核对 Dart 当前已经实现了什么、哪些实现只是最小版、哪些地方已经偏离“SDK 优先”的边界。

## 审计结论

### 1. Claude Code 是能力来源，不是 SDK 范围本身

`claude-code` / `claudecode` 里包含大量产品层能力：

- 命令系统
- TUI / Ink UI
- bridge / remote control
- IDE / OAuth / plugin / browser / notification
- background sessions / remote sessions
- 大量 feature-flag 工具与工作流

这些能力可以帮助我们识别将来可能需要的 service，但不应该直接进入当前 Dart SDK 主线。

### 2. open-agent-sdk-typescript 才是更接近当前目标的对照物

从 `open-agent-sdk-typescript` 看，当前 SDK 主干应该先对齐的是：

- 高层 agent API：`createAgent` / `Agent.query` / `Agent.prompt`
- one-shot helper：`query()` / `prompt()`
- session 持久化与基本管理
- provider 抽象
- tool loop
- permission 决策
- lifecycle hooks
- MCP tools/resources 注入

而不是优先对齐：

- skills
- subagents / team
- tasks / cron / workflow
- context compact / token budget 的完整产品化版本

### 3. Dart 当前实现没有走偏到“错方向”，但有一个明确的结构性耦合点

当前 Dart SDK 的主方向基本正确：

- 有独立 SDK 入口
- 有 `ClartCodeAgent`
- 有 one-shot helper
- 有 session store
- 有 provider-native tool calling 与 JSON plan fallback
- 有 permission / hooks / MCP 的最小公开能力
- 有 external cancellation

但有一个明显偏差：

- SDK 的 session 持久化之前直接依赖 `lib/src/cli/workspace_store.dart`

这会导致 SDK 对 CLI 模块产生实现级耦合。它不影响功能，但不符合“SDK 先独立，再让 CLI 退化为 adapter”的方向。

本轮已修正：

- SDK session 持久化已收敛到 `lib/src/sdk/session_store.dart`
- 继续复用 `.clart/sessions/*.json` 与 `active_session.json` 格式
- 但 SDK 不再直接 import CLI store 实现

## 当前 Dart SDK 能力盘点

| 能力域 | 当前状态 | 结论 |
| --- | --- | --- |
| SDK 入口 | `lib/clart_code_sdk.dart` 已独立导出 agent/provider/tool/session/mcp 类型 | 对齐 |
| 高层 Agent API | `ClartCodeAgent.query/prompt/clear/setModel/stop/close` | 对齐 |
| One-shot helper | `sdk_helpers.dart` 已有 top-level `query()/prompt()`，且支持 external cancellation | 对齐 |
| Session 持久化 | 已支持 save/load/list/fork/rename/tag；本轮已从 CLI store 解耦 | 对齐 |
| Streaming event 协议 | 已有 `system/assistant_delta/assistant/tool_call/tool_result/result` | 基本对齐 |
| Provider 抽象 | 已有 local / Claude / OpenAI provider | 对齐 |
| Tool loop | 已有 provider-native tool calling，provider 不支持时回退 JSON plan | 对齐 |
| Tool 权限 | 已有 `allow/deny/ask` 最小版与 `canUseTool` | 部分对齐 |
| Hooks | 已有 `SessionStart/SessionEnd/Stop/PreToolUse/PostToolUse/PostToolUseFailure` | 部分对齐 |
| MCP 注入 | `ClartCodeMcpOptions` 已可装载 tools/resources | 基本对齐 |
| Session-level interrupt / queued input | 尚无完整语义 | 未完成 |
| Agent/session metadata convenience API | `ClartCodeAgent` 已补 `snapshot()/renameSession()/setSessionTags()/addSessionTag()/removeSessionTag()/forkSession()` | 对齐 |
| 更细粒度 hooks | 缺少 model turn start/end、permission decision、cancelled terminal event 等 | 未完成 |
| Context service | 还没有独立 SDK context injection service | 未开始 |
| Task service | 仓库内部有基础能力，但没有稳定 SDK API | 未开始 |
| Skills / Subagents / Team | 未实现 | 后续纳入，但不属于当前 P0 |

## 当前“偏差”与判断

### 偏差 A：把 Claude Code 产品层功能直接映射为 SDK 近期 backlog

判断：

- 这是文档层偏差，不是实现层 bug。
- 需要修正文档口径，避免继续把命令、UI、bridge、workflow、plugin 等功能当作 SDK Phase 的自然后续。

纠正：

- 后续 SDK 文档以 `open-agent-sdk-typescript` 的 public API 为主要基线。
- `claude-code` / `claudecode` 只作为能力来源索引，不直接决定优先级。

### 偏差 B：SDK session store 直接依赖 CLI 实现

判断：

- 这是实现层偏差。
- 会让 SDK 的存储演进被 CLI 内部模块绑定。

纠正：

- 本轮已修正。
- 后续如果要共享格式，只共享文件格式，不共享 CLI 实现模块。

### 偏差 C：当前文档里“下一步建议”偏早进入增量加功能

判断：

- 在本次重新梳理之前，这种写法会让后续继续往 convenience API / hooks 细节上堆功能。
- 但更优先的是先把 SDK 的能力边界写实，再做补齐。

纠正：

- 后续优先级先从“补更多功能”改成“补齐 core SDK 边界和语义”。

## 建议的 SDK 主线范围

### 当前必须继续留在 SDK 主干里的能力

- `ClartCodeAgent`
- one-shot `query()` / `prompt()`
- session 持久化与基础管理
- provider 抽象
- tool loop
- tool permission
- lifecycle hooks
- MCP tools/resources 装载
- cancellation / interrupt 语义

### 当前不要纳入 SDK 主线的能力

- CLI 命令迁移
- rich/fullscreen TUI
- slash command 体验
- bridge / remote control / remote sessions
- plugin / IDE / OAuth / browser / notification
- workflow / cron / monitor 一类产品化工具
- 重型 team/coordinator/swarm 模式

## 纠偏后的优先顺序

1. 先把 SDK 核心边界写实并保持解耦
2. 再补更细粒度 hooks / permission decision / cancelled lifecycle event
3. 再补 session-level interrupt / queued input 语义
4. 再评估 context service / task service 是否进入 SDK
5. 最后才讨论 CLI 如何消费 SDK

## 本轮之后的建议

如果下一轮继续只做 SDK，建议先做：

- 更细粒度 SDK hooks
  - model turn start/end
  - permission decision
  - cancelled terminal event

然后再做：

- 更完整的 session-level interrupt / queued input 语义
