# Claude Code（TS）分析大纲与 Dart 迁移计划

## 1. 分析范围与结论摘要

- 分析范围：`/Users/th/Dart/clart-code/clart-code/claudecode/src`（主程序）与 `claudecode/vendor`（依赖/原生扩展源码）。
- 当前项目是一个大型 CLI + TUI（Ink/React）交互系统，核心是“命令分发 + REPL 消息循环 + 模型 query + 工具调用编排 + 任务系统 + MCP 集成”。
- 对 Dart 迁移的建议：先做 **核心引擎分层迁移**，把 UI（Ink）与业务流程解耦，再替换终端 UI 层。

## 2. 代码基线（结构与规模）

按 `src/<一级目录>` 粗统计（约 1900+ 文件）：

- `utils`：564
- `components`：389
- `commands`：207
- `tools`：184
- `services`：130
- `hooks`：104
- `ink`：96
- `bridge`：31
- 其余：`skills` / `tasks` / `entrypoints` / `state` 等

这说明项目是“高度模块化但耦合面广”的 CLI 平台，而不只是一个简单命令行工具。

## 3. 主执行链路（你后续迁移最该优先对齐）

### 3.1 入口与快速路径

- 入口：`src/entrypoints/cli.tsx`
- 特征：大量 fast-path + dynamic import，避免全量启动开销。
- 功能：先处理 `--version`、bridge/daemon/bg/template 等分支，再落到 `main.tsx`。

### 3.2 主控启动

- 主控：`src/main.tsx`
- `main()` 负责：环境初始化、信号处理、argv 改写（如 ssh/remote/deeplink）、交互/非交互模式判定、Commander 命令定义。
- `run()` 负责：commander program 构建、`preAction` 初始化（init/sinks/migrations/settings），再进入 action handler。

### 3.3 命令注册与动态命令源

- 命令聚合：`src/commands.ts`
- 核心点：
  - 内置命令表（`COMMANDS`）
  - 动态来源：skills、plugins、workflow、MCP skill
  - 运行时过滤：availability + isEnabled

### 3.4 REPL 交互主循环

- UI 启动：`src/replLauncher.tsx` -> `src/screens/REPL.tsx`
- 输入处理：`src/utils/handlePromptSubmit.ts` -> `src/utils/processUserInput/processUserInput.ts`
- 分流规则：
  - slash command（本地/JSX/prompt command）
  - 普通 prompt -> query 循环

### 3.5 Query + Tool 执行核心

- 查询循环：`src/query.ts`（`export async function* query(...)`）
- 工具编排：`src/services/tools/toolOrchestration.ts`
- 关键机制：
  - 按工具“是否可并发”分批
  - 并发批次并行执行，非并发批次串行执行
  - tool result 写回 message stream

### 3.6 Tool / Task / MCP 三大平台层

- Tool 抽象：`src/Tool.ts`（巨大 `ToolUseContext`，承载几乎全部运行时上下文）
- Tool 清单：`src/tools.ts`（feature flag + env gate + capability gate）
- Task 抽象：`src/Task.ts`（任务类型、状态、ID、生命周期）
- MCP 客户端：`src/services/mcp/client.ts`（stdio/sse/http/ws transport + auth + tool/resource 映射）

## 4. 迁移到 Dart 的推荐目标架构（先拆层，再迁 UI）

建议先定义 6 层：

1. `core/runtime`
- 会话状态、消息模型、配置、事件总线

2. `core/command`
- 命令注册、解析、分发、动态命令加载

3. `core/query`
- query loop、stream 事件、token/预算控制

4. `core/tools`
- tool schema、permission gate、并发调度器

5. `core/tasks`
- 后台任务、任务状态机、输出持久化

6. `integrations/*`
- MCP、auth、analytics、plugin、bridge

UI（终端交互）建议作为独立层：

- `ui/terminal`（Dart 终端框架）
- `ui/non_interactive`（print/stream-json 模式）

## 5. 建议的迁移工作计划（可执行）

### 阶段 0：冻结行为基线（1-2 周）

- 目标：建立“可对比”的行为基线，避免迁移后回归不可控。
- 工作：
  - 梳理关键命令与关键工具调用路径（top 20）
  - 为关键链路生成 transcript 样本（输入/输出/事件）
  - 建立 golden tests（至少覆盖：命令解析、query/tool 循环、权限分支）

### 阶段 1：定义 Dart 领域模型与协议（1 周）

- 目标：先定接口，不急着搬实现。
- 工作：
  - Message / Command / Tool / Task / Permission / MCP 的 Dart 类型系统
  - 统一错误模型与事件模型
  - 明确 JSON schema 兼容策略（与现有 tool input schema 对齐）

### 阶段 2：迁移“无 UI 核心引擎”（2-4 周）

- 目标：先跑通 headless 模式（`--print` 等价能力）。
- 工作：
  - 命令解析与 dispatch
  - `processUserInput` + `query` 循环
  - tool orchestration（并发/串行批处理）
  - 基础工具（Read/Edit/Write/Bash/WebFetch）先迁最小集

### 阶段 3：迁移任务系统与 MCP（2-3 周）

- 目标：恢复复杂集成功能。
- 工作：
  - Task 生命周期、后台任务、中断/取消
  - MCP transport 层与 tool/resource 暴露
  - auth + policy + permission 交互联动

### 阶段 4：终端 UI 迁移（2-4 周）

- 目标：替换 Ink REPL UI。
- 工作：
  - 输入框、消息列表、权限弹窗、spinner、通知
  - 键盘绑定/Vim 模式/历史导航
  - 与 core runtime 通过事件流通信

### 阶段 5：灰度与切换（1-2 周）

- 双栈对比运行（TS 与 Dart）
- 差异追踪与补齐
- 分批切流

## 6. 高风险点（建议优先规避）

- `ToolUseContext` 过大：上下文耦合高，直接照搬会导致 Dart 版本难维护。
- 大量 feature/env gate：行为组合复杂，需要“配置矩阵测试”。
- REPL 与业务逻辑混杂：必须先抽离 UI 依赖。
- MCP + 权限 + 异步任务交互：并发边界复杂，迁移时要先保守串行，再逐步放并发。

## 7. 第一批落地建议（下一步）

建议你下一步让我做两件事：

1. 产出 `TS -> Dart` 的 **文件级映射表**（先覆盖入口、commands、query、tools、tasks、mcp）。
2. 生成一个 Dart 目录骨架（仅接口与空实现），让团队可以并行填充模块。

---

## 附：本次分析重点参考文件

- `src/entrypoints/cli.tsx`
- `src/main.tsx`
- `src/commands.ts`
- `src/screens/REPL.tsx`
- `src/utils/handlePromptSubmit.ts`
- `src/utils/processUserInput/processUserInput.ts`
- `src/query.ts`
- `src/services/tools/toolOrchestration.ts`
- `src/Tool.ts`
- `src/tools.ts`
- `src/Task.ts`
- `src/services/mcp/client.ts`
