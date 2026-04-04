# Claude Code Dart 迁移迭代计划（可运行优先）

## 目标约束（按你的要求固化）

- 每个迭代必须是可执行版本：`dart run bin/clart_code.dart ...` 可运行。
- 未实现能力一律保留空壳：函数保留、可调用、返回明确 `NOT_IMPLEMENTED`。
- 埋点/上报默认不做：保留调用点，具体实现全部 no-op。
- Claude API 高耦合能力可裁剪：先抽象 provider 接口，后续按需移除特性。
- 安全/防护中“你不需要”的部分先不迁：保持开关关闭，必要处留占位。
- 三方库找不到等价实现时：先做接口占位，不阻塞主程序可运行，并单独列出待你确认项。
- 不做文件级翻译：按“完整程序逐步可运行”迁移。

## 当前迭代状态（Iteration 9.10，已落地）

- 已有可执行 CLI：`help/version/start/status/features/chat/print/repl/loop/tool/diff/review`。
- 已分离运行时核心：`AppRuntime + QueryEngine + LlmProvider`。
- 已实现命令注册表与调度器。
- 已实现配置加载：环境变量 + `--config` JSON。
- 已实现 provider 显式切换：`--provider local|claude|openai`。
- 已实现最小多轮循环：`loop --max-turns N <prompt>`。
- 已实现 provider 级流输出：`loop --stream-json`（json lines）。
- 已实现 Tool 抽象与执行器：`ToolExecutor` + `ToolScheduler`（串行）。
- 已实现基础工具：`read`、`write`、`shell`（stub）。
- 已实现最小工具权限策略：`ToolPermissionPolicy`（allow/deny）。
- 已提供 CLI 工具入口：`tool` 命令。
- 已实现 git 工作区状态最小版：
  - 当前仓库识别
  - working tree 文件清单/增删行统计
  - tracked patch 读取
  - 小体积 untracked 文件预览
- 已新增 `diff` 命令：
  - `diff --json`
  - `diff --stat`
  - `diff --name-only`
- 已新增 `review` 命令：
  - 基于当前 git diff 构造最小 code review prompt
  - 复用现有 `PromptSubmitter + UserInputProcessor + TurnExecutor` 执行链
  - `review --prompt-only` 可直接查看生成的 review prompt
  - review 结果会像 `chat` 一样落盘为本地 session
- 已实现启动体验最小版：`start` 命令（目录信任 + 欢迎屏 + REPL 进入）。
- 已实现无参默认启动到 `start`，并在交互终端自动进入 REPL。
- 已实现 REPL 流式回显（provider `textDelta` 增量输出）。
- 已实现 REPL 最小命令：`/help`、`/model`、`/provider`、`/status`、`/doctor`、`/diff`、`/memory`、`/tasks`、`/permissions`、`/mcp`、`/session`、`/clear`、`/exit`。
- 已实现 `/status` 命令（查看当前 provider/model）。
- 已支持 REPL 运行期切换 model/provider（后续请求生效）。
- 已新增统一输入提交链路：
  - `PromptSubmitter`
  - `UserInputProcessor`
  - `ConversationSession`
- 已把 plain/rich REPL 的 slash command 执行统一到 `repl_command_dispatcher.dart`。
- 已把 provider 初始化/提示/config merge 辅助逻辑从 `runner.dart` 拆到 `provider_setup.dart`。
- 已让 `chat / repl / loop` 共用“提交决策 -> query/local-command 分流”的主链路。
- 已提供交互 UI 预览：`--ui rich`（全屏重绘 + 底部输入栏 + 流式消息重绘）。
- 已提供 rich->plain 兼容回退（小终端/兼容性路径）。
- 已支持 REPL 输入续行：plain 模式行尾 `\` + Enter。
- 已支持 rich composer 多行草稿展示（最近几行可见）。
- 已支持 rich true multiline 输入编辑：`Ctrl+J` 插入换行（不依赖 `\` 续行）。
- 已支持 rich composer 光标跨行移动与边界历史检索（Up/Down）。
- 已支持 rich composer 常用编辑快捷键（Home/End/Ctrl+A/Ctrl+E/Ctrl+U/Ctrl+K/Ctrl+W）。
- 已支持 rich 历史快捷键补齐：`Ctrl+P/Ctrl+N`（history prev/next）。
- 已支持流式响应中断：`Ctrl+C` 中断当前回答（plain/rich）。
- 已支持 rich 输入阶段双击 `Ctrl+C` 优雅退出语义。
- 已完成 `QueryLoop` 事件通道对齐：文本模式与 `--stream-json` 共用流式事件路径。
- 已完成 `done` 字段对齐：`status/model` 在文本与 `stream-json` 路径一致。
- 已新增 `init` 命令（provider/key/host/model 初始化，写入配置文件）。
- 已新增 REPL `/init` 最小命令（内联参数配置并立即切换当前会话 provider/model）。
- 已新增 REPL 启动与 provider 切换提示：当 provider=local 或缺少远端 API key 时给出“Run /init”非阻塞提示。
- 已修复 rich 输入中文光标错位：按终端显示宽度（CJK 2 列）计算光标列与换行。
- 已支持默认自动加载 `./.clart/config.json`（存在即生效）。
- 已新增 `auth` 命令用于持久化 provider + key + host。
- 已新增 provider 凭据全局覆写参数（claude/openai key+host）。
- 已实现 Query 统一错误模型：`RuntimeError + RuntimeErrorCode`。
- 已实现 Query 结构化事件：`turnStart/providerDelta/assistant/error/done`。
- 已接入 `dart_console` 到启动渲染（终端宽度适配）。
- 已引入 `dart_openai` 依赖并完成 `openai` provider 最小实接。
- 已实接 `openai` provider（`dart_openai`，最小 chat completion）。
- 已引入 `interact_cli` 并将 trust 选择改为组件化输入。
- 已引入 `mason_logger` 并用于 CLI 提示样式。
- 已实接 `claude` provider（最小 HTTP 调用）。
- 已实接 provider 流式抽象：
  - `ProviderStreamEventType`: `textDelta/done/error`
  - `LlmProvider.stream()` 统一接口（openai/claude 实流式，local 自动回退）
- 已提供 provider 策略：
  - `LocalEchoProvider`（可运行默认）
  - `ClaudeApiProvider`（最小 HTTP 可用）
  - `OpenAiApiProvider`（最小 SDK 可用）
- 已提供 no-op 埋点：`TelemetryService`。
- 已提供可裁剪安全占位：`SecurityGuard`（默认关闭）。
- `doctor/export/features/help` 已同步暴露 git workspace + diff/review 能力。
- REPL 现已可直接查看本地 `doctor/diff/memory/tasks/permissions/mcp/session` 摘要，无需退出交互模式。

## MVP P0 进度看板（供新会话直接续接）

- [x] 启动链路：trust gate + welcome + REPL
- [x] 初始化链路：`init` / `/init` 持久化并即时生效
- [x] provider 缺配置引导：启动与切换时提示 `Run /init`
- [x] rich 输入稳定性：UTF-8 解码 + CJK 宽度光标/换行
- [x] 统一输入主链路第一阶段：submitter / processor / slash dispatcher 拆分
- [x] 工作区状态最小闭环：memory/tasks/permissions/mcp/session/git diff
- [x] 基础代码审查主干：`review` 基于当前 working tree 执行一轮
- [ ] rich `/init` 逐步向导（避免在命令行明文显示 key）
- [ ] 真实 LLM 失败文案细化（按网络/鉴权/host 分类）
- [ ] 首轮用户引导文案（从 local echo 到真实模型的最短路径）

## 迭代路线（每步都可运行）

### Iteration 2：命令与配置层完善（可运行）

完成定义：
- 增加统一配置入口（env + config 文件），程序仍可独立运行。
- 命令结构升级为“命令注册表 + 分发器”。
- `--provider local|claude|openai` 可显式切换。

未实现处理：
- 配置热更新先留空壳。
- 复杂 flags（如 worktree/bridge）先保留占位命令。

### Iteration 3：Query 主循环最小版（可运行） [DONE]

完成定义：
- 引入最小消息循环：`turn_start -> assistant -> done`。
- 支持基础 `maxTurns`。
- 可打印结构化事件流（简版 stream-json / json lines）。

未实现处理：
- token budget、compact、thinking 先保留接口，不实现逻辑。

### Iteration 4：Tool 执行器最小版（可运行） [DONE]

完成定义：
- Tool 抽象与调度器落地（串行 + 可并发标记）。
- 先实现 2~3 个基础工具（示例：Read、Write、ShellStub）。
- 权限层做最小可用模式（allow/deny）。

未实现处理：
- 复杂权限对话框、自动策略、细粒度规则先留空。

### Iteration 5：启动体验最小版（可运行） [DONE]

完成定义：
- 启动时信任目录确认（trust gate）。
- 欢迎面板与最小提示区渲染。
- 非交互模式下的安全兜底（未信任目录拒绝继续）。

未实现处理：
- 高级 TUI（键盘事件、滚动区域、复杂布局）先留空。
- 图形化选择器和状态条先留空。

### Iteration 6：Query 事件协议与错误模型细化（可运行） [DONE]

完成定义：
- 完善 query 流事件 schema（为 tool / task 执行对齐）。
- 统一 `query/tool` 错误码与错误上下文结构。

未实现处理：
- token budget / compact 策略先保持占位。

### Iteration 7：OpenAI Provider 接入最小版（可运行） [DONE]

完成定义：
- 新增 `--provider openai`。
- `OpenAiApiProvider` 通过 `dart_openai` 执行最小 chat completion。
- 缺失 key 和 SDK 异常路径统一映射到 `RuntimeError`。

未实现处理：
- 流式输出与函数调用协议后续补齐。
- OpenAI Responses API 路径后续补齐。

### Iteration 8：Claude API 接入最小版（可运行） [DONE]

完成定义：
- `ClaudeApiProvider` 从空壳升级为真实 HTTP 调用。
- 错误模型统一到 Dart 侧异常体系。
- 本地 provider 与 Claude provider 可切换。

未实现处理：
- Claude 特有增强能力（如某些实验参数）默认不迁。

### Iteration 9：Provider 流式抽象（可运行） [DONE]

完成定义：
- provider 层增加统一 stream 事件抽象。
- `loop --stream-json` 可消费 provider 级流事件。

未实现处理：
- 复杂增量渲染与取消控制先占位。

### Iteration 10：MCP/任务系统最小版（可运行）

完成定义：
- Task 状态机（pending/running/completed/failed）最小实现。
- MCP 保留连接抽象，先支持最小 transport 或 mock。

未实现处理：
- 高级 MCP 鉴权、复杂资源同步先占位。

### Iteration 11：交互体验增强（可运行）

完成定义：
- 终端交互增强（历史、取消、中断、状态条）。
- 兼容非交互 `print` 模式。

未实现处理：
- 高级 TUI 动画和复杂弹窗先占位。

## 占位函数规范（统一）

- 命名：`...Stub` / `...Placeholder` / `notImplementedYet`。
- 行为：
  - 不抛未捕获异常导致程序退出。
  - 返回稳定结果（如 `QueryResponse(output: '[NOT_IMPLEMENTED] ...')`）。
  - 记录 no-op telemetry（函数存在，内部空实现）。

## 三方库决策规则

- 有 Dart 等价库：直接替换并做兼容层。
- 无等价库：
  - 建 `adapter` 接口。
  - 默认 fallback 到 stub/mock。
  - 在 `docs/third-party-open-questions.md` 记录待你确认项。

## 下一步执行（我将继续）

下一步进入 MVP P0 主链路（见 `docs/claudecode-mvp-minimal-flow.md`）：
- 已补齐 `/init` 交互向导细节（rich 模式下逐步式引导输入，API key 掩码显示）。
- 启动阶段提示文案细化（按 provider 错误类型给更具体建议）。
- 继续将 `processUserInput` 对齐到 `claude-code`：
  - 已从 `runner` 抽离 `TurnExecutor`
  - 已增加 typed transcript/local-command/tool-result message 基础类型
  - 已让 `chat / repl / loop / stream-json` 共用同一 turn 执行器
  - 已让 `ConversationSession` 同时维护 query history 与 typed transcript
- 已补齐最小 git 工作区状态与 `diff/review` 命令闭环。
- REPL 主循环可用性收敛（真实 LLM 往返 + 错误提示 + 中断语义稳定）。
