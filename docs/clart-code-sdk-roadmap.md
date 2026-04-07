# Clart Code SDK 路线图

> 目标：先把 Dart 侧 SDK 边界梳理正确，再继续补齐 SDK 主线能力。当前默认不启动 CLI/TUI 对接工作。

## 总体原则

- SDK 优先，CLI/TUI 不在当前迭代范围。
- 参考 `open-agent-sdk-typescript` 时，优先对齐 SDK public API。
- 参考 `claude-code` / `claudecode` 时，只提取能力域，不直接继承产品层 backlog。
- 先纠正边界和耦合，再继续加功能。
- 具体见：`docs/clart-code-sdk-next-capabilities-plan.md`

## Stage A: 能力审计与边界纠偏

状态：已完成

范围：

- 重新梳理 `./claude-code`、`./claudecode`、`open-agent-sdk-typescript`
- 明确哪些能力属于 SDK 主线，哪些属于产品层
- 核对 Dart 当前实现是否偏离
- 修正明显的结构性偏差

本轮落地：

- 新增 `docs/clart-code-sdk-capability-audit.md`
- 重写 `docs/clart-code-sdk-feature-matrix.md`
- 更新 `docs/clart-code-sdk-architecture.md`
- SDK session store 不再直接依赖 `lib/src/cli/workspace_store.dart`

收尾标准：

- 文档明确 SDK 主线与产品层边界
- 至少修正一个明确的 SDK/CLI 结构耦合点

## Stage B: 完整化现有 SDK 主线

状态：进行中

目标：

- 在不扩大产品层范围的前提下，把当前已经进入 SDK 的能力补完整

范围：

- `ClartCodeAgent` 上的 session metadata convenience API
  - `snapshot()`
  - `renameSession()`
  - `setSessionTags()`
  - `addSessionTag()`
  - `removeSessionTag()`
  - `forkSession()`
- 更细粒度 hooks
  - model turn start/end
  - permission decision
  - cancelled terminal event
- 更完整的 session interrupt / queued input / cancellation 语义

当前已完成：

- `ClartCodeAgent` 已补 `snapshot()/renameSession()/setSessionTags()/addSessionTag()/removeSessionTag()/forkSession()`

收尾标准：

- session 元数据不必只通过 store 层操作
- cancellation 语义不再只停留在 request-scoped 最小版
- hooks 能覆盖 agent 主循环中的关键生命周期点

## Stage C: SDK service 边界补齐

状态：待评估

目标：

- 只把确实应该成为 SDK service 的能力提升出来

候选范围：

- context injection service
- task service
- config/context state 的 SDK 化抽象

说明：

- 这一阶段开始前，需要再次确认这些能力是否真的是 SDK public API 缺口
- 不要因为 Claude Code 有完整产品能力，就提前把 service 面做大

## Stage D: 下一阶段能力实现

状态：已规划，待开工

范围：

- `tools`
- `MCP`
- `skills`
- `multi-agent`

执行顺序：

1. 先补 `tools + MCP`
2. 再做 `skills`
3. 最后做 `multi-agent` 最小版

说明：

- 详细拆解见 `docs/clart-code-sdk-next-capabilities-plan.md`
- `tools` 与 `MCP` 属于 SDK 基座补强
- `skills` 属于复用能力层
- `multi-agent` 只先做 SDK 意义上的最小 subagent API，不追 Claude Code 的重型 team/coordinator/background/remote 版本
- 下一步开工时，不建议把 `tools` 与 `MCP` 平铺并行；应先修 `MCP registry` 对齐，再继续补 tool public API 与 builtin tools

## 当前明确不做

- CLI 命令迁移到 SDK
- rich/fullscreen TUI
- slash command UI
- skills
- subagents / team
- workflow / cron / monitor
- IDE / plugin / OAuth / bridge / remote sessions

## 继续执行时的优先判断

如果下一轮继续只做 SDK，优先顺序是：

1. `MCP transport` 剩余收尾
2. 第一批 builtin tools（尤其是真实 `shell`）
3. MCP tool/resource error 语义与测试
4. 再回到更细粒度 hooks / permission decision / interrupt

补记：

- `MCP registry` 对齐已完成
- `MCP transport` 的 SDK 类型/runtime 收口已开始，CLI 收口仍后置
- `tool public API` 已补 direct tool registration 与可扩 permission outcome

不要先做：

1. CLI/TUI
2. Skills
3. Subagents
4. 产品层扩展能力
