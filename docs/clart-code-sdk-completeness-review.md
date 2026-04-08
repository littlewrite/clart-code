# Clart Code SDK 完备度对照

> 时间：2026-04-08
>
> 目的：重新回答一个更精确的问题：
>
> 1. TS 参考实现里有哪些“大功能 / 子功能”？
> 2. 这些能力里哪些应当算 Dart SDK 主线？
> 3. 以 `open-agent-sdk-typescript` 的 public API 为基线，当前 Dart SDK 能不能算“功能完备”？

## 对照基线

- SDK public API 基线：`/Users/th/Node/open-agent-sdk-typescript`
- 产品能力来源：`./claude-code`、`./claudecode`
- Dart 实现范围：`lib/clart_code_sdk.dart` 与 `lib/src/sdk/*`

本次判断原则：

- `open-agent-sdk-typescript` 决定“SDK 应该具备什么 public surface”。
- `claude-code` / `claudecode` 主要用于识别完整产品的能力域来源。
- Claude Code 的 CLI、TUI、remote、plugin、OAuth、bridge、notification、heavy team/task/workflow 默认不直接算 Dart SDK 缺项。

## 一、TS 参考实现的大功能与子功能

### A. `open-agent-sdk-typescript` 的 SDK 核心能力

| 大功能 | 子功能 | 是否应进入 Dart SDK 主线 |
| --- | --- | --- |
| Agent facade | `createAgent()`、`Agent.query()`、`Agent.prompt()`、`clear()`、`interrupt()`、`close()`、`setModel()`、`setPermissionMode()`、`setMaxThinkingTokens()`、`getSessionId()`、`getApiType()`、`getMessages()` | 是 |
| Request / output control | `systemPrompt`、`appendSystemPrompt`、`tools` preset、`allowedTools` / `disallowedTools`、`maxTurns`、`maxBudgetUsd`、`maxTokens`、`thinking`、`effort`、`jsonSchema` / `outputFormat`、`includePartialMessages`、`abortController` / `abortSignal` | 是 |
| Session API | `saveSession()`、`loadSession()`、`listSessions()`、`forkSession()`、`renameSession()`、`tagSession()`、`appendToSession()`、`deleteSession()`、`getSessionInfo()`、`getSessionMessages()`、`resume` / `continue` / `persistSession` | 是 |
| Provider abstraction | `createProvider()`、Anthropic/OpenAI provider、`apiType` 自动判定、归一化 message/tool schema | 是 |
| Tool platform | `tool()` helper、`defineTool()`、`toApiTool()`、`getAllBaseTools()`、`filterTools()`、`assembleToolPool()`、30+ builtin tools | 是 |
| Permission system | `permissionMode`、`canUseTool()`、`updatedInput` / deny message、tool allow/deny lists | 是 |
| Hooks | `HookRegistry`、matcher、function/shell hook、`PreToolUse` / `PostToolUse` / `SessionStart` / `SessionEnd` / `Stop` / `PreCompact` / `PostCompact` 等 | 是 |
| MCP integration | 外部 MCP server 连接、in-process SDK MCP server、tools/resources 注入 | 是 |
| Skills | registry、bundled skills、alias、`whenToUse`、`allowedTools`、`model`、`hooks`、`inline/fork` | 是 |
| Subagents / orchestration | `agents` definitions、`AgentTool`、`SendMessageTool`、team/task/worktree/plan tools | 部分是 |
| Context / compaction / observability utilities | `getSystemContext()`、`getUserContext()`、`getGitStatus()`、context cache、auto-compact / micro-compact、retry、token / cost utils、message utils | 部分是 |

补记：

- TS SDK 虽然导出了 tasks/team/worktree/plan 等能力，但其中有一部分已经开始贴近“产品化 SDK”，不应机械当作 Dart P0。
- 但 request/output control、session、provider、tool、permission、hooks、MCP、skills 这些仍然是明确的 SDK 主线。

### B. `claude-code` / `claudecode` 的产品层能力域

这两个仓库主要提供“能力来源索引”，大功能可粗分为：

| 大功能 | 子功能示例 | 是否应直接当作 Dart SDK 缺项 |
| --- | --- | --- |
| 命令系统 | `/resume`、`/permissions`、`/tasks`、`/plugin`、`/mcp`、`/review` 等 commands | 否 |
| 终端 / TUI / React UI | Ink、permissions dialog、task panels、skills UI、team UI | 否 |
| Remote / bridge | remote session、SDK message adapter、WebSocket session manager | 否 |
| Plugin / IDE / OAuth | plugin marketplace、IDE integration、OAuth flow、remote managed settings | 否 |
| Team / background / remote tasks | Local/Remote agent task、coordinator、team memory sync | 默认否 |
| 产品化 context / memory / notification | memory、summary、tips、notifs、prompt suggestion、agent summary | 默认否 |

结论：

- 这两份 TS 代码不应该被直接翻译成 Dart SDK backlog。
- 它们主要用于帮助判断某个概念究竟属于“SDK 能力”还是“产品能力”。

## 二、Dart SDK 当前对照结果

### 1. 已基本具备的能力

| 能力域 | Dart 当前状态 | 判断 |
| --- | --- | --- |
| SDK 入口 | `lib/clart_code_sdk.dart` 已独立导出 agent / provider / tool / session / mcp / skill / agent-definition 类型 | 对齐 |
| 高层 Agent API | `ClartCodeAgent.query()`、`prompt()`、`clear()`、`setModel()`、`interrupt()`、`close()` | 基本对齐 |
| One-shot helper | top-level `query()` / `prompt()` / `runSubagent()` 已存在 | 对齐 |
| Session 基础持久化 | `ClartCodeSessionStore.save/load/list/fork/rename/tag` + agent `snapshot()/renameSession()/setSessionTags()/forkSession()` | 基本对齐 |
| Provider 基座 | local / Claude / OpenAI provider，且 provider-native tool calling + fallback loop 已接入 | 基本对齐 |
| Tool loop | SDK 已能完成模型 -> tool -> tool result -> 再入模型的闭环 | 对齐 |
| MCP 最小能力 | registry、manager、resource tools、`createSdkMcpServer()`、in-process server | 基本对齐 |
| Skills 最小能力 | registry、bundled skill、目录加载、inline/fork、runtime constraints | 基本对齐 |
| Subagent 最小能力 | `runSubagent()`、named agents、`agent` tool、child event cascade | 基本对齐 |

### 2. 明确仍是“部分完成”的能力

| 能力域 | 当前缺口 |
| --- | --- |
| Agent facade 完整度 | 缺 `createAgent()` 风格 factory；缺 `setPermissionMode()`、`setMaxThinkingTokens()`、`getApiType()` 这类便利 API；实例级 `query()/prompt()` 已支持 per-call `effort` override |
| Request / output control | 第一层 public surface 已补齐，`maxBudgetUsd` 也已做 best-effort runtime enforcement；`status` / `compact_boundary` 也已有最小 live producer，当前主要是仍未和真正的 compact service 对齐 |
| Session API 完整度 | top-level helper 已补 `load/list/latest/active/info/messages/append/delete` 与 `continueLatest*` / `continueActive*`；当前更多是易用性打磨，不再是硬缺口 |
| Tool platform 完整度 | Dart 目前 builtin tools 主要是 `read/write/edit/glob/grep/shell + skill/agent/mcp_*`；相比 TS 缺 web、ask-user、notebook、tool-search、todo、config、LSP 等一批工具；当前已补最小 `tool()` / `defineTool()` helper DSL，但更强的 typed helper 仍缺 |
| Hooks 形态 | Dart hooks 现在是 typed callback 风格，核心生命周期已不少，但没有 `HookRegistry` / matcher / shell hook 这一层；也没有 TS 那套 `PreCompact/PostCompact` 事件，因为当前并没有 compact service |
| Permission 体系 | 已有 `allow/deny/ask` 与 `updatedInput`，但缺 TS public API 里的 `permissionMode` 完整语义分层，以及配套的 ask-user / permission prompt 一类能力 |
| MCP transport 范围 | 类型层已识别 `stdio/sse/http/ws/sdk`，但运行时当前只支持 `stdio` 与 `sdk`；`sse/http/ws` 仍是 registry 识别而非 runtime 完成 |
| Subagent orchestration | 当前只有最小 one-shot subagent；缺 `SendMessageTool`、team、background/resume、多代理协同状态机 |

### 3. 当前还没有进入 SDK 主线，或应显式后置的能力

| 能力域 | 当前判断 |
| --- | --- |
| Claude Code command/TUI/UI | 不应算 Dart SDK 缺项 |
| bridge / remote / plugin / OAuth / IDE | 不应算 Dart SDK 缺项 |
| heavy tasks / workflow / cron / monitor | 默认后置，不是当前 SDK 完备度的核心判断项 |
| full product context / memory / notification | 可以作为未来 service 来源，但当前不是主线 |

## 三、最关键的差异结论

### 结论 1：Dart SDK 已经不是“空壳”，核心闭环是成立的

如果标准是“能否程序化创建 agent，并完成会话、tool loop、skills、MCP、最小 subagent 调用”，当前 Dart SDK 已经可以工作，且不是 demo 级空实现。

### 结论 2：但如果以 `open-agent-sdk-typescript` public API 为基线，当前还不能算“功能完备”

最主要不是差在 CLI/TUI，而是差在下面几层 SDK public surface：

1. agent facade convenience API 仍不够完整
2. stream/result observability 与 compaction runtime 仍不完整
3. builtin tool 覆盖与 typed helper 生态仍明显偏窄
4. permission / MCP runtime transport / subagent orchestration 仍有明显缺口
5. context/compact/token/cost 这一层仍缺稳定公开 API

### 结论 3：当前最容易误判的点，是把“产品层没做”与“SDK 不完备”混在一起

更准确的说法应该是：

- 相对 `claude-code` / `claudecode`：当前 Dart 明显还远不完整，但其中大部分不是 SDK 缺项。
- 相对 `open-agent-sdk-typescript`：当前 Dart 已覆盖核心主干，但仍有一批明确 public API 缺口，所以不能说“SDK 部分已经完备”。

## 四、建议的下一步优先级

### P0：先补 SDK public surface 的硬缺口

2026-04-08 更新：

- `ClartCodeAgentOptions` / per-call `ClartCodeRequestOptions` 已补第一层 request/output control
- `ClartCodeSdkMessage` / `ClartCodePromptResult` 已补 usage / cost / model usage
- session top-level helper 已补 `load/list/latest/active/info/messages/append/delete`
- 剩余 P0 收尾点主要变成：
  - `maxBudgetUsd` 已做 best-effort runtime enforcement
  - continue-latest / continue-active convenience 已补
  - `stream_event` / `rate_limit_event` 已补
  - `status` / `compact_boundary` 已补最小 runtime producer，但仍没有真正的 compact service

1. 收口 agent facade convenience API
   - 缺 `createAgent()` 风格 factory
   - 缺 `setPermissionMode()`、`setMaxThinkingTokens()`、`getApiType()` 这类实例便利 API
   - per-call `effort` override 已补，不再算硬缺口
2. 收口 observability / compaction runtime
   - `stream_event` / `rate_limit_event` 已落地
   - `status` / `compact_boundary` 的最小 runtime 触发边界已落地
   - 但 compaction runtime 本身仍后置，interrupt / queued-input 事件面也还偏薄
3. 保持 session API 为已基本收口状态
   - `delete / info / messages / continue` convenience 已基本补齐
   - 后续更多是易用性打磨，而不是 P0 硬缺口

### P1：再补 SDK 易用性

1. 自定义工具 helper DSL
2. web / ask-user / tool-search / notebook 这批更接近 SDK 的 builtin tools
3. 更完整的 permission mode public semantics

### P2：最后再评估是否继续向 TS 的扩展型 SDK 靠拢

- compact/context utilities
- token/cost helpers
- send-message/team/background subagent
- task/worktree/plan 这类更重的 orchestration surface

## 最终判断

一句话结论：

- 当前 Dart `clart code agent sdk` 的“核心 SDK 主干”已经成型。
- 但若以 `open-agent-sdk-typescript` 为基线，它还不能算功能完备，当前更准确的状态是：`核心闭环已具备，但 public API 仍有几块明显缺口`。
