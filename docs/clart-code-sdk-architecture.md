# Clart Code SDK 架构与实施记录

## 目标

- 保留现有 CLI。
- 新增独立 SDK 入口，避免 TUI 继续绑定底层执行链。
- 先把 `ClartCodeAgent` 做成稳定的高层封装，再让 CLI/TUI 逐步退化为适配层。
- 除非用户明确提出，否则当前工作默认只推进 SDK，不启动 CLI 对接 SDK 的落地工作。

## 新入口

- SDK 入口：`lib/clart_code_sdk.dart`
- CLI 入口：`lib/clart_code.dart`

这两个入口并行存在：

- CLI 继续服务当前命令行使用场景。
- SDK 面向测试、后续 TUI、以及未来的程序化调用。

## 配套文档

- 功能矩阵：`docs/clart-code-sdk-feature-matrix.md`
- 能力审计：`docs/clart-code-sdk-capability-audit.md`
- 下一阶段能力规划：`docs/clart-code-sdk-next-capabilities-plan.md`
- 路线图：`docs/clart-code-sdk-roadmap.md`
- 工作日志：`docs/clart-code-sdk-worklog.md`

## Phase 1 已落地范围

- 新增 `ClartCodeAgent`
- 新增 `ClartCodeAgentOptions`
- 新增 SDK 流式消息模型 `ClartCodeSdkMessage`
- 新增聚合结果模型 `ClartCodePromptResult`
- 新增 `ClartCodeSessionStore`
- 复用现有 `.clart/sessions/<id>.json` 工作区会话格式

当前 `ClartCodeAgent` 已完成：

- 单轮 prompt/query 调用
- 基于现有 `QueryEngine` 的流式消费
- 会话 history / transcript 累积
- 本地 session 持久化与 resume
- 最小 provider 组装：`local|claude|openai`

## 当前边界

这一阶段刻意不做：

- TUI
- rich 输入编辑
- slash command UI
- 完整 tool-call 闭环
- hooks / subagents / tasks 的 SDK 化公开 API

说明：

- 仓库内部已经有 tool、MCP、task 的最小实现。
- 但当前 LLM 调用主链还没有把“模型输出 -> tool use -> tool result -> 再入模型”完整挂到 SDK agent 循环里。
- 所以 Phase 1 先把 Agent、Session、Stream 协议立住，不伪装成已经完成工具闭环。

## 本轮纠偏

- SDK 的 session 持久化继续复用 `.clart/sessions/<id>.json` 与 `active_session.json` 格式。
- 但 SDK 不再直接依赖 CLI 的 `workspace_store.dart` 实现。
- 后续如果 CLI 与 SDK 共享存储格式，只共享格式，不共享 CLI 私有模块。
- 参考 `./claude-code`、`./claudecode` 时，只把它们当作能力来源，不把其产品层能力直接映射成 SDK 近期 backlog。

## 后续阶段建议

### Phase 2

- 把 tool loop 正式接入 `ClartCodeAgent`
- 定义 SDK 侧 tool schema 与 tool result 事件
- 暴露 `allowedTools / disallowedTools / permissionMode`

当前进度补充：

- 以上三项已经进入实现中。
- 当前 SDK 已有一个可运行的最小 tool loop，采用文本 JSON plan 协议：
  - 模型输出 `tool_calls`
  - agent 执行工具
  - tool result 作为 `MessageRole.tool` 回注
- 这解决了 “模型 -> 工具 -> 模型” 的基础闭环，但还不是 provider-native function calling。

### Phase 3

- 把 MCP 注册与连接管理提升到 SDK 层
- 支持 agent 启动时装载 MCP tools/resources

### Phase 4

- 把 tasks、workspace 状态、review/diff 等能力统一抽到 SDK service
- CLI 改为消费 SDK，而不是继续直接编排底层 core

### Phase 5

- 在 SDK 之上重新实现轻量 TUI
- UI 只负责输入、订阅事件、渲染，不再直接掌控执行状态机

## 设计原则

- SDK 优先于 TUI
- session 格式统一，不重复造轮子
- 先做真实可测的 public API，再做复杂交互层
- 不把 CLI 私有状态机继续扩散到 SDK
