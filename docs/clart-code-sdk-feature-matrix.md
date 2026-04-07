# Clart Code SDK 功能矩阵

> 目的：把“参考来源”“是否应该进入当前 SDK 主线”“Dart 当前状态”放到一张表里，防止把 Claude Code 的产品层能力直接搬成 SDK backlog。

## 参考口径

- SDK public API 基线：`/Users/th/Node/open-agent-sdk-typescript`
- 产品能力来源：`./claude-code`、`./claudecode`
- 当前约束：只推进 SDK，不启动 CLI/TUI 对接工作

## 能力域矩阵

| 能力域 | 主要参考来源 | 是否纳入当前 SDK 主线 | Dart 当前状态 | 备注 |
| --- | --- | --- | --- | --- |
| SDK 入口 | `open-agent-sdk-typescript/src/index.ts` | 是 | 已完成 | `lib/clart_code_sdk.dart` 已独立导出 |
| 高层 Agent API | `src/agent.ts` | 是 | 已完成 | `ClartCodeAgent` 已支持 `query/prompt/clear/setModel/stop/close` |
| One-shot helper | `src/agent.ts` / examples | 是 | 已完成 | top-level `query()/prompt()` 已支持 external cancellation |
| Session 持久化 | `src/session.ts` | 是 | 已完成 | 已支持 save/load/list/fork/rename/tag；本轮已从 CLI store 解耦 |
| Streaming event 协议 | `src/types.ts` | 是 | 已完成 | 当前事件面已覆盖 init、delta、assistant、tool_call、tool_result、result |
| Provider 抽象 | `src/providers/*` | 是 | 已完成 | local / Claude / OpenAI 已具备 |
| Tool loop | `src/engine.ts` | 是 | 已完成 | 优先 provider-native tool calling，fallback JSON plan；SDK 已支持 direct custom tool registration |
| Tool 权限 | `examples/10-permissions.ts` | 是 | 部分完成 | 已有 `allow/deny/ask`、`canUseTool` 与可扩展的 `resolveToolPermission` |
| Lifecycle hooks | `src/hooks.ts` / `examples/13-hooks.ts` | 是 | 部分完成 | 已有 session/tool hooks；缺更细粒度事件 |
| MCP tools/resources | `sdk-mcp-server.ts` / agent options | 是 | 部分完成 | registry 已统一；transport 语义已在 SDK 类型/runtime 上收紧到 `stdio`，CLI 收尾仍后置 |
| Session interrupt / queued input | `src/agent.ts` / Claude Code query loop | 是 | 未完成 | 目前只有 request-scoped cancellation |
| Session metadata convenience API | `src/session.ts` + Agent convenience | 是 | 已完成 | `ClartCodeAgent` 已支持 `snapshot/renameSession/setSessionTags/addSessionTag/removeSessionTag/forkSession` |
| Context injection service | `src/utils/context.ts` | 以后再说 | 未开始 | 当前不应先做成产品化上下文系统 |
| Task service | Claude Code tasks / open-agent tasks tools | 以后再说 | 未开始 | 仓库内有基础能力，但不应先公开成 SDK |
| Skills | `src/skills/*` | 后续纳入 | 未实现 | 应做最小 public API，但排在 `tools/MCP` 之后 |
| Subagents / Team | `examples/09-subagents.ts` | 后续纳入 | 未实现 | 只先做最小 subagent API，不追重型 team/coordinator 版本 |
| Cron / Workflow / Monitor | Claude Code tools/tasks | 否 | 未实现 | 明显属于产品层能力 |
| CLI commands | `claude-code/src/commands.ts` | 否 | 不在本轮范围 | 不进入当前 SDK 工作 |
| TUI / Ink / rich UI | `claude-code/src/main.tsx` / UI 组件 | 否 | 不在本轮范围 | 不进入当前 SDK 工作 |
| Bridge / IDE / plugin / OAuth / remote | Claude Code 产品层模块 | 否 | 不在本轮范围 | 只作为未来 service 来源，不是近期 SDK backlog |

## 结论

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
- 更细粒度 hooks / permission decision / cancelled terminal event

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
