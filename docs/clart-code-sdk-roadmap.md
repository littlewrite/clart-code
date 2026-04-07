# Clart Code SDK 路线图

> 目标：把当前项目从“CLI 驱动内核”逐步收敛为“SDK 驱动 CLI”。

## 总体策略

- 保留现有 CLI，不做破坏式重写。
- 新功能优先进入 SDK 层。
- 每个阶段都要求：
  - 可运行
  - 有文档
  - 有测试
  - 有明确收尾条件

## Phase 1

状态：已完成

范围：

- 新增 `lib/clart_code_sdk.dart`
- 新增 `ClartCodeAgent`
- 新增 SDK 消息模型
- 新增 `ClartCodeSessionStore`
- 复用 `.clart/sessions` 现有格式

收尾标准：

- SDK 可被单独 import
- `query/prompt` 可工作
- local provider 路径有测试
- session resume 有测试

## Phase 2

状态：进行中，最高优先级

目标：

- 把 `ClartCodeAgent` 从“provider stream wrapper”升级为“真正 agent loop”

范围：

- 设计 SDK tool definition
- 设计 tool call / tool result 事件
- 建立 tool registry/filter API
- 支持 `allowedTools/disallowedTools`
- 把 `ToolExecutor + ToolScheduler` 接进 agent 主循环
- 提供 top-level `query()` helper
- 扩展 session store 的 list/load/fork 基础操作

当前已完成：

- SDK public tool types 已加入 `sdk_models.dart`
- `ClartCodeSdkMessage` 已加入 `tool_call` / `tool_result` 事件
- `ClartCodeAgentOptions` 已加入 `allowedTools` / `disallowedTools` / `permissionMode` / `maxTurns`
- `ClartCodeAgent` 已接入最小可运行 tool loop
- 已补 `read` / `write` / `shell(stub)` 与 deny permission 路径测试
- 已补 top-level `query()` / `prompt()` helper
- session store 已补 `fork/rename/tag`
- SDK 已补 `canUseTool` 与最小 lifecycle hooks
- OpenAI-compatible Responses provider 已支持 provider-native tool calling：
  - 请求体携带 `tools`
  - 响应可返回结构化 `toolCalls`
  - tool result 通过 `previous_response_id + function_call_output` 回注
- Claude Messages provider 已支持 provider-native tool calling：
  - 请求体携带 `tools`
  - assistant/tool 历史可映射回 `tool_use` / `tool_result`
  - 非流式原生 tool calling 已打通；带 tools 的流式路径当前退回完整 `run()` 结果
- `ClartCodeAgent` 已优先消费 provider-native tool calls，并仅在 provider 不支持时回退 JSON plan
- SDK agent 已支持通过 `ClartCodeMcpOptions` 装载 MCP tools/resources
- `stop()` 已会触发 provider 级 active request cancel（OpenAI / Claude）

当前未完成：

- local/custom provider 仍未统一到 provider-native tool calling；当前 OpenAI-compatible Responses 与 Claude Messages 路径已完成，其他 provider 仍可能回退 JSON plan
- `stop()` 已能触发 provider active request cancel，但仍未抽象成更完整的跨 provider cancellation/session interrupt 语义

收尾标准：

- 模型可以触发一个或多个工具调用
- 工具结果能回注到下一轮模型请求
- agent 在无工具 / 有工具两条路径都能结束
- 至少覆盖 `read`、`write`、`shell(stub)` 三个工具路径测试

## Phase 3

目标：

- 把权限与 hooks 提升到 SDK 一等公民

范围：

- `permissionMode`
- 自定义 `canUseTool`
- SDK hook registry
- `PreToolUse/PostToolUse/PostToolUseFailure`
- `SessionStart/SessionEnd/Stop`

收尾标准：

- 可以通过 hook 观察工具执行
- 可以通过 permission 机制拒绝工具
- 被拒绝的工具能在 event/result 中体现

## Phase 4

目标：

- 统一 SDK service 层，让 CLI 不再直接拼底层模块

范围：

- MCP manager/client 接入 SDK
- task service 接入 SDK
- workspace/git/session 状态服务抽象
- review/diff 相关能力从 CLI 下沉为 service

收尾标准：

- agent 可装载 MCP tools/resources
- CLI 的部分命令开始调用 SDK service
- 文档明确 CLI 与 SDK 的边界

## Phase 5

目标：

- 处理中高复杂能力，但仍不碰 TUI 重构

范围：

- skills 占位或最小实现
- context injection
- compact/token budget 接口化
- 更完整的 session 管理能力
- 评估 subagent API 的最小可行设计

收尾标准：

- SDK API 基本稳定
- CLI 不再是唯一入口
- 复杂能力具备明确占位和演进方向

## Phase 6

目标：

- 让 CLI/TUI 成为 SDK adapter

范围：

- 让现有 CLI 主链逐步消费 SDK
- 未来如要重做 TUI，只订阅 SDK events，不直接管理状态机

收尾标准：

- UI 与核心循环彻底解耦
- 新 UI 可以复用现有 session/tool/mcp/runtime

## 当前最近两次迭代的具体执行顺序

### Iteration A

- 定义 SDK tool types
- 设计 `ClartCodeSdkMessage` 中 tool 相关事件
- 为 `ClartCodeAgent` 增加 tool registry / allowedTools / disallowedTools

### Iteration B

- 将 tool loop 接入 agent
- 增加 tool 结果回注
- 补齐测试

## 近期不做的事

- 复杂 rich TUI 调整
- 基于 UI 的 slash command 体验优化
- feature-flag 特性的一次性搬运
- 大范围复刻 `claude-code` 产品层功能

## 继续执行时的优先判断

如果下一次工作时间有限，优先做：

1. provider-native tool calling
2. MCP tool/resource 注入进 SDK agent
3. 更完整的 stop/interrupt 与 provider 取消

不要先做：

1. TUI
2. 多代理
3. Skills
4. 高级 MCP 认证
