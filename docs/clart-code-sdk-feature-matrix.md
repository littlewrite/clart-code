# Clart Code SDK 功能矩阵

> 目的：把“参考来源”“是否应该进入当前 SDK 主线”“Dart 当前状态”放到一张表里，防止把 Claude Code 的产品层能力直接搬成 SDK backlog。

## 参考口径

- SDK public API 基线：`/Users/th/Node/open-agent-sdk-typescript`
- 产品能力来源：`./claude-code`、`./claudecode`
- 当前约束：只推进 SDK，不启动 CLI/TUI 对接工作
- 翻译规则：只搬适合 Dart SDK public API 的语义；不搬 telemetry、anti-abuse、third-party SDK guard、以及 terminal app 特有产品逻辑

## 能力域矩阵

| 能力域 | 主要参考来源 | 是否纳入当前 SDK 主线 | Dart 当前状态 | 备注 |
| --- | --- | --- | --- | --- |
| SDK 入口 | `open-agent-sdk-typescript/src/index.ts` | 是 | 已完成 | `lib/clart_code_sdk.dart` 已独立导出 |
| 高层 Agent API | `src/agent.ts` | 是 | 已完成 | `ClartCodeAgent` 已支持 `query/prompt/clear/setModel/stop/close` |
| One-shot helper | `src/agent.ts` / examples | 是 | 已完成 | top-level `query()/prompt()` 已支持 external cancellation，且现已支持 per-call `effort` override |
| Session 持久化 | `src/session.ts` | 是 | 已完成 | 已支持 save/load/list/fork/rename/tag；本轮已从 CLI store 解耦 |
| Streaming event 协议 | `src/types.ts` | 是 | 基本对齐 | 基线事件面仍以 `init/delta/assistant/tool_call/tool_result/result` 为主；Dart 另外补了最小 synthetic `subagent` / `skill` lifecycle extension，但不把它当作 TS public SDK 基线 |
| Provider 抽象 | `src/providers/*` | 是 | 已完成 | local / Claude / OpenAI 已具备 |
| Tool loop | `src/engine.ts` | 是 | 已完成 | 优先 provider-native tool calling，fallback JSON plan；SDK 已支持 direct custom tool registration，且第一批 builtin tools 已可真实执行，input/error 约束也已基本收口 |
| Tool 权限 | `examples/10-permissions.ts` | 是 | 部分完成 | 已有 `allow/deny/ask`、`canUseTool`、`resolveToolPermission` 与 permission decision hook |
| Lifecycle hooks | `src/hooks.ts` / `examples/13-hooks.ts` | 是 | 部分完成 | 已有 session/tool hooks，并补了 model turn / permission decision / cancelled terminal / subagent start-end，以及 inline skill `activation/end` hooks（显式区分 `replaced_by_skill/query_end/cancelled/error/max_turns_reached`）；`parent query()` 已可实时 merge child events，child lifecycle 也已收口为 synthetic `subagent/start + subagent/end`（`terminalSubtype` 保留 child terminal subtype），inline active skill 只在 `cancelled/error/max_turns_reached` 时额外发出最小 synthetic `skill/end` stream event，`query_end/replaced_by_skill` 仍刻意只走 hooks；child `assistant_delta` 已支持 opt-in；仍缺 interrupt 与更细 session state 事件面 |
| MCP tools/resources | `sdk-mcp-server.ts` / agent options | 是 | 部分完成 | SDK 内 registry/runtime/error 语义已收敛，并补了最小 in-process SDK MCP helper；CLI transport 收尾仍后置 |
| Session interrupt / queued input | `src/agent.ts` / Claude Code query loop | 是 | 部分完成 | 已有 session 内串行 queue、`interrupt()` 与 `clearQueuedInputs()`；仍缺更细状态事件面 |
| Session metadata convenience API | `src/session.ts` + Agent convenience | 是 | 已完成 | `ClartCodeAgent` 已支持 `snapshot/renameSession/setSessionTags/addSessionTag/removeSessionTag/forkSession` |
| Context injection service | `src/utils/context.ts` | 以后再说 | 未开始 | 当前不应先做成产品化上下文系统 |
| Task service | Claude Code tasks / open-agent tasks tools | 以后再说 | 未开始 | 仓库内有基础能力，但不应先公开成 SDK |
| Skills | `src/skills/*` | 是 | 部分完成 | 已有最小 skill public API、registry、bundled init、local `SKILL.md` loader、`skill` tool 与 agent prompt 注入；`getPrompt(args, context)` 现已可拿到动态 runtime `turn/model/effort` context；`allowedTools` 与 `disallowedTools` 都已开始真实作用于 tool loop，same-turn 后续 invocation activation 与 later skill override 也已收口，`model` 与字符串级别 `effort(low|medium|high|max)` 都已开始作用于后续 turns；inline skill metadata 现已显式暴露 `runtime_scope=current_query` 与 `cleanup_boundary=query_end`，并有回归测试锁住“不跨 query 泄漏”；agent hooks 现在也能显式收到 inline skill `activation/end` lifecycle；query stream 在 active inline skill 以 `cancelled/error/max_turns_reached` 结束时也会补一个 synthetic `skill/end`；`context=fork` 已接最小 child-agent 执行，forked child terminal error 现已按 TS `SkillTool` 方向保留为成功的 `skill` tool result + child metadata；`skill.agent` 现在会按 Dart SDK 语义复用现有 named agent definitions，而不是引入 TS terminal app 的 agent-type 体系；`disable-model-invocation` 与 slash-prefixed skill name 的最小 SDK 语义也已收口，模型可见 skill 列表会过滤掉 `disable-model-invocation` 的 skill；provider 侧当前由 OpenAI Responses 真正消费 `effort`，Claude 继续维持现有兼容口径；`cascadeAssistantDeltas` 也可把 child `assistant_delta` opt-in 回流到 parent surface，但完整 lifecycle/orchestration 仍未完成 |
| Subagents / Team | `examples/09-subagents.ts` | 是 | 部分完成 | 已有最小 one-shot subagent public API：`ClartCodeAgent.runSubagent()` 与 top-level `runSubagent()`，并补了 named agent definitions（`ClartCodeAgentDefinition` / `ClartCodeAgentsOptions`）、agent registry、local agents directory loader、最小 `agent` tool、parent-child lifecycle hooks/cancellation relation、terminal transcript cascade、compact cascaded subagent event messages，以及 parent `query()` stream 上的实时 child event merge；child lifecycle event 现已统一为 synthetic `subagent/start + subagent/end`，child `assistant_delta` 也支持按 subagent/agent/skill definition 显式 opt-in；named agent / subagent 现也已接入字符串级别 `effort` public surface；background/resume/send-message/team 仍未实现 |
| Cron / Workflow / Monitor | Claude Code tools/tasks | 否 | 未实现 | 明显属于产品层能力 |
| CLI commands | `claude-code/src/commands.ts` | 否 | 不在本轮范围 | 不进入当前 SDK 工作 |
| TUI / Ink / rich UI | `claude-code/src/main.tsx` / UI 组件 | 否 | 不在本轮范围 | 不进入当前 SDK 工作 |
| Bridge / IDE / plugin / OAuth / remote | Claude Code 产品层模块 | 否 | 不在本轮范围 | 只作为未来 service 来源，不是近期 SDK backlog |

## 结论

补记：

- “当前是否完备”的集中判断，见 `docs/clart-code-sdk-completeness-review.md`
- 该文档偏能力域矩阵；完备度复盘文档偏“已做 / 缺项 / 下一步”

### Provider Support Matrix

| 语义 | OpenAI Responses | Claude | Local echo |
| --- | --- | --- | --- |
| `QueryRequest.effort` / agent-skill effort surface | 真正透传到 `reasoning.effort` | 当前不消费，继续保持既有 `thinking={type:disabled}` 兼容口径 | 不消费，作为 no-op |
| top-level `query()/prompt()` per-call `effort` override | 支持 | 支持 SDK surface，但 provider 侧仍不消费 | 支持 SDK surface，但 provider 侧仍不消费 |

### 当前已经进入稳定主线的能力

- SDK 入口
- Agent API
- one-shot helper
- session store
- provider 抽象
- tool loop
- permission / hooks / MCP 的最小公开能力
- external cancellation

### 当前应该继续补齐，但仍属于 SDK 主线的能力

- session-level interrupt / queued input 语义
- skills 执行语义补全
- parent/child transcript / cascaded event surface 的进一步扩展
- named agents 的更完整 frontmatter/runtime 语义

### 当前明确存在的 SDK public surface 缺项

- `ClartCodeAgentOptions` / per-call `ClartCodeRequestOptions` 已补齐第一层 request/output control
  - `maxBudgetUsd` 已按累计 `costUsd` 做 best-effort 预算约束
- `ClartCodeSdkMessage` / `ClartCodePromptResult` 已补 usage / token / cost / model usage
  - `stream_event` / `rate_limit_event` 已支持 opt-in
  - `status` / `compact_boundary` 已支持最小 live runtime producer
  - 但仍没有真正的 compact service
- session public API 已有 top-level helper
  - `continueLatest*` / `continueActive*` convenience 已补
- 已有最小 `tool()` / `defineTool()` helper DSL
- 但 builtin tool 覆盖面与更强的 typed helper 仍明显小于 TS
- MCP runtime transport 当前仅 `stdio` / `sdk` 真正可用；`sse/http/ws` 仍非 runtime 完成

### 当前不应该纳入的能力

- CLI 命令迁移
- TUI / rich 输入编辑 / slash command UI
- workflow / cron / monitor / browser / notification
- IDE / plugin / OAuth / bridge / remote sessions
- 重型 team/coordinator/swarm 模式

## 使用规则

后续每次继续 SDK 工作时，优先先问三个问题：

1. 这是 `open-agent-sdk-typescript` 意义上的 SDK public API 吗？
2. 这项能力如果不做，是否会让 `ClartCodeAgent` 的程序化调用明显缺口？
3. 这项能力是否其实属于 Claude Code 的产品层，而不是 SDK 主干？

如果第 3 个问题答案是“是”，当前默认不做。
