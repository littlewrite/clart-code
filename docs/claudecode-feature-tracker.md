# Claude Code 功能清单与迁移跟踪

> 维护规则：每次迭代都更新此文档，保证“源功能清单”与“Dart 已实现清单”同步。

## A. Claude Code（TS）功能清单（按能力域）

来源基线：`claudecode/src`（约 1900+ 文件），重点参考 `entrypoints/cli.tsx`、`main.tsx`、`commands.ts`、`tools.ts`、`query.ts`、`Task.ts`、`services/mcp/*`。

### A1. CLI 与会话控制

- 多入口/快速路径：`--version`、daemon、bridge、remote-control、bg sessions、templates、runner 模式。
- 主命令系统（`commands.ts` 聚合）：包含会话、上下文、配置、模型、权限、插件、MCP、IDE、统计、恢复、导出等大量命令。
- 交互与非交互双模式：REPL（Ink）与 `-p/--print` headless。

### A2. Query 主循环与消息系统

- `query.ts` 异步流式主循环。
- 用户输入处理、slash command 分流、hook 触发、消息归一化。
- token/预算/compact/recovery 等上下文控制。

### A3. Tool 平台

- Tool 抽象 + 大上下文 `ToolUseContext`。
- 工具调度：按并发安全性分批并行/串行执行。
- 典型工具族：文件读写编辑、shell、web fetch/search、task、agent、plan、MCP 资源等。

### A4. Task 与多代理

- Task 类型与状态机（local shell / local agent / remote agent / teammate / monitor / dream）。
- 子代理、团队协作、后台任务。

### A5. MCP 与外部集成

- MCP 多传输（stdio/sse/http/ws）与工具/资源桥接。
- MCP 鉴权与会话管理。
- IDE、OAuth、plugins、skills、bridge 等扩展系统。

### A6. 权限与安全

- 多权限模式与规则体系（allow/deny/ask）。
- sandbox、策略限制、组织策略、风控/保护逻辑。

### A7. 可观测性

- analytics、telemetry、diagnostics、性能剖析。

## B. Dart 迁移目标映射（按“完整可运行”迭代）

- 约束：每个迭代必须可执行；未实现能力使用稳定空壳；埋点函数保留但 no-op。

### B1. 已实现（当前）

- 可执行 CLI 程序：`help/version/status/features/chat/print/repl`。
- 可执行 CLI 程序：`help/version/start/status/features/chat/print/repl/loop/tool`。
- 配置加载：env + JSON 配置文件（`--config`）。
- 命令架构：命令注册表 + 调度器（非文件映射方式）。
- Query 最小执行链：`runCli -> QueryEngine -> LlmProvider`。
- 最小多轮循环：`loop --max-turns N <prompt>`（迭代占位策略为自动续轮）。
- provider 级流事件输出：`loop --stream-json ...`（json lines）。
- Tool 平台最小版：`ToolExecutor + ToolScheduler`（串行调度）。
- Tool 权限最小版：`ToolPermissionPolicy`（allow/deny）+ 工作区默认权限持久化。
- 基础工具：`read`、`write`、`shell(stub)`。
- CLI 工具入口：`tool` 命令（可直接验证工具链路）。
- workspace 辅助命令最小版：
  - `doctor`：输出工作区/配置/权限/MCP/任务/记忆/git 诊断
  - `memory`：读写 `./.clart/memory.md`
  - `tasks`：读写 `./.clart/tasks.json`
  - `permissions`：持久化默认 tool permission（`./.clart/permissions.json`）
  - `export`：导出 workspace snapshot JSON
  - `mcp`：管理本地 MCP server 注册表（`./.clart/mcp_servers.json`）
  - `diff`：查看当前 git working tree 的最小 diff 摘要 / JSON
  - `review`：基于当前 git diff 构造最小 code review prompt 并执行一轮
- 本地 session 闭环最小版：
  - `chat / repl / loop` 会写入 `./.clart/sessions/<id>.json`
  - `review` 执行结果也会生成本地 session 快照
  - `session`：列出/查看当前或指定 session
  - `resume`：基于保存的 session 继续一轮 prompt
  - `share`：把 session 导出为 Markdown/JSON
- 启动体验最小版：`start`（trust gate + welcome panel）。
- 无参数默认入口：进入 `start`，并在交互终端自动进入 REPL loop。
- REPL 已支持流式输出：按 provider `textDelta` 增量回显到终端。
- REPL 最小命令：`/help`、`/model`、`/provider`、`/status`、`/doctor`、`/diff`、`/memory`、`/tasks`、`/permissions`、`/mcp`、`/session`、`/clear`、`/exit`。
- REPL 支持 `--stream-json`（turn 级 json lines）。
- REPL 运行期切换：`/model <name>` 与 `/provider <local|claude|openai>`。
- REPL 初始化命令：`/init <claude|openai> <apiKey> [baseUrl] [model]`（最小内联配置，立即生效）。
- 交互 UI 预览：`repl --ui rich` / `start --ui rich`（全屏布局 + 底部输入栏 + 流式重绘）。
- REPL 输入续行：plain 支持行尾 `\` + Enter。
- rich composer：支持 true multiline（`Ctrl+J` 换行）+ 草稿多行展示（最近几行）。
- rich composer 光标与编辑：支持跨行光标移动、行内编辑、边界历史检索（Up/Down）。
- REPL 流式中断：流式输出中 `Ctrl+C` 可中断当前回答（不中断会话）。
- rich 输入退出语义：`Ctrl+C` 双击退出（首次提示，二次退出）。
- rich CJK 显示宽度修复：中文等宽字符按 2 列计算（光标定位与换行对齐）。
- `QueryLoop` 统一事件通道：`stream-json` 与文本模式共用流式事件路径（`providerDelta/assistant/error/done` 字段一致）。
- `loop` 文本模式结束行增强：输出 `turns/status/model`，与 `done` 事件字段对齐。
- 默认配置自动加载：`./.clart/config.json`（存在即生效）。
- auth 持久化命令：`auth --provider ... --api-key ... --base-url ...`。
- init 持久化命令：`init --provider ... --api-key ... --base-url ... --model ...`。
- provider 凭据全局覆盖参数：
  - `--claude-api-key` / `--claude-base-url`
  - `--openai-api-key` / `--openai-base-url`
- Query 统一错误模型：`RuntimeError + RuntimeErrorCode`。
- Query 结构化事件：`turnStart/providerDelta/assistant/error/done`。
- 控制台渲染底座：已接入 `dart_console`（最小使用）。
- OpenAI provider：已接入 `--provider openai`（`dart_openai` 最小 chat completion）。
- Claude provider：已从 stub 升级为最小 HTTP 调用（Messages API）。
- provider 级流式抽象：已完成 `textDelta/done/error` 统一事件模型。
- 交互组件：已接入 `interact_cli`（trust 选择器）。
- 日志样式：已接入 `mason_logger`（CLI 提示输出）。
- Provider 切换：`--provider local|claude|openai`。
- 启动/切换 provider 提示：provider 为 local 或远端缺少 key 时，提示运行 `/init`。
- 埋点上报：`TelemetryService` no-op。
- 安全保护：`SecurityGuard` 占位开关，默认关闭（可裁剪）。

### B2. 未实现（已占位/待实现）

- 完整多轮 query 状态机、compact/token budget、完整 stream-json 协议。
- tool 并发分组调度器（parallel-safe batch）与复杂工具上下文。
- 高级终端渲染（复杂布局、快捷键、状态栏、滚动视图）。
- task 系统与后台任务编排（当前仅本地 JSON 任务清单）。
- MCP 真实连接与资源/工具桥接（当前仅本地注册表）。
- 远程/后台/多分支 session 管理（当前仅本地快照 + active session）。
- 复杂权限策略与 sandbox 集成。
- 插件/skills/bridge/IDE 深度集成。

## C. 当前状态快照（2026-04-04）

- TS 侧：功能完备，模块庞大（~1900+ 文件）。
- Dart 侧：已升级为”可运行迁移基座（Iteration 9.10 级别）”，核心功能 70% 完整。
- 迁移策略：继续按能力域增量落地，始终保持主程序可运行。
- 代码质量：MVP 级别实现完成，架构清晰，类型安全，缺少单元测试。

## D. 下一步优先级（2026-04-04 后续）

### P0（关键）
- [ ] 添加单元测试覆盖核心模块（query_engine, turn_executor, providers）
- [ ] 实现 Tool 并发分组调度（当前仅串行）
- [ ] 完善错误恢复机制

### P1（重要）
- [ ] 实现 Task 后台任务系统（基础版）
- [ ] 添加 MCP 真实连接
- [ ] 完善权限细粒度控制

### P2（优化）
- [ ] 添加代码注释和文档
- [ ] 优化 Provider 流式解析
- [ ] 实现连接超时和重试
