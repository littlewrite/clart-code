# Clart Code SDK 功能矩阵

> 目的：把参考实现、当前 Dart 状态、以及后续落地阶段放到同一张表里，避免范围漂移。

## 参考基线

- Public API 基线：`/Users/th/Node/open-agent-sdk-typescript`
- Claude Code 能力基线：`./claude-code`、`./claudecode`
- 说明：`./claude-code` 与 `./claudecode` 当前内容高度接近，可视为同一功能面的两个本地镜像；功能盘点以 `claude-code/src/tools.ts`、`docs/claudecode-capability-index.md`、`docs/claudecode-feature-tracker.md` 为主。

## 当前原则

- SDK 优先，TUI 暂不纳入当前范围。
- CLI 继续保留，但后续要逐步变成 SDK 的适配层。
- 只把“稳定可复用的核心能力”推进到 SDK public API。
- Claude Code 中偏产品化、强 feature-flag、强 UI 依赖的部分先不做。

## 能力域矩阵

| 能力域 | 参考实现 | 当前 Dart 状态 | SDK 目标状态 | 目标阶段 |
| --- | --- | --- | --- | --- |
| SDK 入口 | `src/index.ts` | 已新增 `lib/clart_code_sdk.dart` | 稳定导出 agent/types/session/tool/mcp API | Phase 1-2 |
| 高层 Agent API | `src/agent.ts` | 已有 `ClartCodeAgent`，支持 `query/prompt/clear/setModel/close/stop`；`stop()` 已会触发 provider 级 active request cancel | 继续补更完整 cancel 语义与 session/service 装配 | Phase 2-4 |
| One-shot query API | `query({ prompt, options })` | 已补独立 top-level `query()` / `prompt()` helper | 保持便捷 one-shot 流式接口稳定 | Phase 2 |
| Session 持久化 | `src/session.ts` | 已有 `.clart/sessions`、`ClartCodeSessionStore`，并补 `list/load/fork/rename/tag` | 继续补更完整 session 管理与共享能力 | Phase 2-3 |
| Streaming event 协议 | `SDKMessage` | 已有 `assistant/tool_call/tool_result/result/system` 基础事件 | 继续对齐更完整生命周期与权限拒绝细节 | Phase 2-3 |
| Provider 抽象 | `src/providers/*` | 已有 local/claude/openai provider | 保持 SDK 层独立组装与切换 | Phase 1 |
| Query engine 主循环 | `src/engine.ts` | SDK agent 已优先消费 provider-native tool calls；OpenAI-compatible Responses 与 Claude Messages 路径原生，其他 provider 仍可回退 JSON plan | 继续补齐其他 provider 的 native tools 与更完整 agentic loop | Phase 2-3 |
| Tool registry | `src/tools/index.ts` | 已有最小 `read/write/shell(stub)`，SDK 已暴露 tool definition/过滤选项 | 继续扩展注册、导出、MCP 注入 | Phase 2-4 |
| Tool 调度 | Engine + tool helpers | 已有 `ToolScheduler`，且已接入 SDK agent 循环与结果回注 | 继续补权限 ask/hook/更多工具类型 | Phase 2-3 |
| Tool 权限 | `permissionMode/canUseTool` | SDK 已支持 `allow/deny/ask`，并补 `canUseTool` | 继续补更细粒度交互式决策与持久化策略 | Phase 3 |
| MCP tools/resources | `mcp/client.ts` + MCP tools | 已有 stdio MCP manager/client，且 `ClartCodeAgent` 可通过 `ClartCodeMcpOptions` 装载 MCP tools/resources | 继续沉淀为更完整 SDK service，并让 CLI 改消费 SDK service | Phase 3-4 |
| Tasks | `task-tools.ts` | 已有本地 `TaskExecutor/TaskStore` | 先公开 SDK service，再决定是否做 task tool | Phase 4 |
| Hooks | `src/hooks.ts` | SDK 已补 `SessionStart/SessionEnd/Stop`、`PreToolUse/PostToolUse/PostToolUseFailure` | 继续补更细粒度阻断/通知/权限更新 | Phase 3 |
| Skills | `src/skills/*` | 未实现 | 先保留占位，不进 P0 | Phase 5 |
| Subagents / team | `AgentTool/SendMessage/Team*` | 未实现 | 在 tool loop 稳定后再设计，不提前承诺 | Phase 5 |
| Context injection | `utils/context.ts` | CLI 侧有 workspace/git/session 能力，SDK 未统一注入 | 做成 SDK service，再被 CLI/TUI 共用 | Phase 4-5 |
| Auto-compact / token budget | `compact.ts/tokens.ts` | 未实现 | 先留接口，后补策略 | Phase 5 |
| Config service | `ConfigTool` / agent options | 当前主要在 CLI config | 逐步拆成 SDK 可复用 config/context service | Phase 4 |
| Web/UI adapter | examples/web + Claude Code TUI | 当前 rich/plain REPL 是 CLI 私有实现 | 暂不做；待 SDK 稳定后再重建 UI | Phase 6 |

## 参考能力收缩结论

### 必须纳入 SDK 主干的能力

- `ClartCodeAgent` 高层 API
- session 持久化与 resume
- provider 抽象
- tool loop
- tool 权限
- MCP 注入
- lifecycle hooks

### 暂不纳入当前范围的能力

- rich/fullscreen TUI
- 复杂 slash command UI
- 大量 feature-flag 工具
- monitor / workflow / push notification / browser automation 等偏产品能力
- coordinator/team swarm 一类高复杂多代理模式

### 关键依赖顺序

1. 先把 tool loop 做完整
2. 再把 permission/hook 接上
3. 再做 MCP/task/context service
4. 最后再让 CLI 改用 SDK

如果顺序反过来，CLI/TUI 会继续把底层能力绑死，SDK 只是薄壳。
