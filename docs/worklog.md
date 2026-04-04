# 迁移工作日志

## 2026-04-03 / Iteration 1

- 建立可运行迁移骨架（help/version/chat/print）。
- 建立 `AppRuntime + QueryEngine + LlmProvider` 最小链路。
- 增加 `TelemetryService` no-op 空壳。
- 增加 `ClaudeApiProvider` 空壳（可调用但未接真实 API）。
- 输出基础分析与迭代计划文档。

## 2026-04-03 / Iteration 2

- 新增配置系统：env + `--config` JSON 文件加载。
- 新增命令注册表与调度器，替代硬编码 switch。
- 新增全局参数：`--provider`、`--model`、`--config`。
- 新增命令：`status`、`features`、`repl`。
- 新增功能跟踪文档：
  - `docs/claudecode-feature-tracker.md`
  - `docs/claudecode-capability-index.md`
  - `docs/third-party-open-questions.md`
- 保持“每次可运行”原则：未实现能力继续空壳化。

## 2026-04-03 / Iteration 3

- 新增最小多轮 query 循环命令：`loop`。
- 新增循环参数：`--max-turns`、`--stream-json`。
- 新增简版事件流（json lines）：`turn_start / assistant / done`。
- 更新功能跟踪文档，标注多轮循环与流输出已落地（最小版）。
- 继续保持占位策略：自动续轮为迁移期占位逻辑，可后续替换。

## 2026-04-03 / Iteration 4

- 新增 Tool 抽象：`ToolInvocation`、`ToolExecutionResult`、`ToolExecutionHint`。
- 新增最小权限策略：`ToolPermissionPolicy`（`allow|deny`）。
- 新增 Tool 注册表与调度器：`ToolRegistry` + `ToolScheduler`（当前串行执行）。
- 新增 Tool 执行器：`ToolExecutor`，并接入 `AppRuntime`。
- 新增基础工具实现：
  - `read`（读取文件）
  - `write`（写入文件）
  - `shell`（稳定占位，返回 `NOT_IMPLEMENTED`）
- 新增 CLI 命令：`tool`（可直接验证工具执行链路）。
- 补充测试覆盖 `tool read/write/permission deny`。

## 2026-04-03 / Iteration 5

- 新增 `start` 启动流程（无参数默认进入）：
  - 信任目录判定（trust gate）
  - 交互式 1/2 选择（Yes proceed / No exit）
  - 非交互模式保护（未信任时直接拒绝并给出 `--yes` 提示）
- 新增目录信任持久化：默认写入 `./.clart/trust.json`。
- 新增欢迎屏渲染（终端面板，动态宽度适配）。
- 新增 `start` 参数：
  - `--yes`（自动信任并继续）
  - `--no`（直接退出）
  - `--trust-file PATH`（自定义信任文件，便于测试/CI）
- 新增测试覆盖 `start --yes/--no/冲突参数`。

## 2026-04-03 / Iteration 6

- 新增统一错误模型：`RuntimeError + RuntimeErrorCode`。
- Query 层接入统一错误：
  - `securityRejected`
  - `providerFailure`
- 新增 Query 事件协议：`turnStart / assistant / error / done`。
- `QueryLoopResult` 增加 `success` 字段并在失败路径返回非 0 退出码。
- 启动渲染接入 `dart_console`（终端宽度计算与分隔线渲染）。
- 依赖升级：
  - `dart_console: ^4.1.2`
  - `dart_openai: ^6.1.1`（已引入，待后续 provider 实接）
- 新增测试覆盖 provider 异常映射与 loop 失败状态。

## 2026-04-03 / Iteration 7

- 新增 `openai` provider（基于 `dart_openai`）并接入 `--provider openai`。
- `openai` provider 支持：
  - 基础 chat completion 调用（非流式）
  - `OPENAI_API_KEY` 缺失时的稳定错误返回（非崩溃）
  - `OPENAI_BASE_URL` 可选覆盖
- 配置系统扩展：
  - provider 枚举增加 `openai`
  - env/config 增加 `openAiApiKey/openAiBaseUrl`
- 新增测试覆盖：
  - `--provider openai` 参数有效
  - 缺失 key 时返回错误码路径

## 2026-04-03 / Iteration 8

- `start` trust 交互升级为组件化输入（`interact_cli.Select`）。
- 引入 `mason_logger` 用于 CLI 统一提示输出样式。
- `ClaudeApiProvider` 从 stub 升级为最小 HTTP 调用：
  - `POST /v1/messages`
  - `x-api-key` + `anthropic-version` 头
  - 失败路径映射到 `RuntimeError`
- 新增测试覆盖：
  - `claude` 缺失 key 返回错误码路径
- 新增三方库映射文档：
  - `docs/third-party-lib-mapping.md`

## 2026-04-03 / Iteration 9

- provider 层新增统一流事件抽象：
  - `ProviderStreamEventType`: `textDelta/done/error`
  - `LlmProvider.stream()` 默认回退到 `run()`，并支持 provider 自定义流实现
- `OpenAiApiProvider` 已接入 `createStream()` 并输出增量文本事件。
- `ClaudeApiProvider` 已接入 SSE（Messages stream）并映射到统一流事件。
- `QueryEngine` 新增 `runStream()`，复用安全检查与 telemetry 逻辑。
- `QueryLoop` 在 `--stream-json` 路径消费 provider 流事件：
  - 输出 `providerDelta` 事件
  - 保持终态 `assistant/error/done` 语义
- 新增测试覆盖：
  - provider 增量事件在 `stream-json` 路径可见
  - provider 流错误路径返回失败状态

## 2026-04-03 / Iteration 9.1（交互补齐）

- 修复默认启动体验：`fvm dart run ./bin/clart_code.dart` 不再停在欢迎页后退出。
- `start` 命令在交互终端会自动进入 REPL；新增 `start --no-repl` 可仅渲染欢迎页。
- `repl` 升级为流式回显：每轮消费 `QueryEngine.runStream()`，增量输出 provider `textDelta`。
- REPL 增加最小命令：`/help`、`/model`、`/clear`、`/exit`。
- `repl` 新增 `--stream-json`，用于事件流调试（json lines）。

## 2026-04-03 / Iteration 9.2（LLM 接入补齐）

- 配置层新增默认自动加载：当 `./.clart/config.json` 存在时，无需 `--config` 也会加载。
- CLI 全局参数新增 provider 凭据覆盖：
  - `--claude-api-key` / `--claude-base-url`
  - `--openai-api-key` / `--openai-base-url`
- 新增 `auth` 命令，用于持久化 provider + key + host 到配置文件：
  - `auth --provider claude|openai --api-key ... --base-url ...`
  - `auth --show` 查看当前生效配置摘要（key 脱敏显示）
- `status` 增强为显示当前 provider 的 host/key 摘要（脱敏）。
- provider 模型选择增强：`QueryRequest.model` 现在可覆盖 provider 默认模型（openai/claude 均支持）。
- REPL slash 命令增强：
  - `/model <name>` 运行期切换模型（对后续请求生效）
  - `/provider <local|claude|openai>` 运行期切换 provider
- 新增测试覆盖：
  - `auth` 写入配置文件
  - `ConfigLoader` 默认自动加载 `./.clart/config.json`
  - 全局 host/key 覆盖参数路径

## 2026-04-03 / Iteration 9.3（交互 UI 预览）

- `repl` / `start` 新增 `--ui plain|rich`（默认 `plain`）。
- 新增 `rich` 模式（全屏重绘）：
  - 顶部状态面板（workspace/provider/model）
  - 中间消息区（user/assistant/system/error）
  - 底部固定输入栏与状态行
  - provider 流式增量时实时重绘 assistant 输出
- 新增 `repl` 命令补充：
  - `/status` 查看当前 provider/model
- 终端兼容性处理：
  - 小尺寸终端自动回退到 `plain`
  - `rich` 输入改为稳定的 `stdin.readLineSync()`，避免部分终端光标查询冲突导致崩溃

## 2026-04-03 / Iteration 9.4（交互输入与中断语义补齐）

- REPL 输入续行补齐（plain + rich）：
  - 行尾 `\` + Enter 进入下一行输入，最终以多行 prompt 一次提交。
- rich composer 改为多行展示（显示最近几行草稿），并更新输入提示。
- 流式响应中断补齐（plain + rich）：
  - 流式输出中按 `Ctrl+C` 仅中断当前回答，不退出 REPL。
- rich 输入阶段退出语义对齐：
  - `Ctrl+C` 首次提示退出（有草稿时会清空输入并提示）
  - `Ctrl+C` 再次触发退出会话（双击退出）。
- `/help` 与输入提示文案同步更新（newline / interrupt / exit 语义）。

## 2026-04-03 / Iteration 9.5（rich true multiline 与快捷键细化）

- rich 输入从“`\` 续行”升级为 true multiline：
  - `Enter` 直接提交；
  - `Ctrl+J` 在 composer 内插入换行（非 `\` 续行语义）。
- rich composer 光标编辑增强：
  - 支持跨行移动（Up/Down/Left/Right，含 Home/End 与 Ctrl+A/Ctrl+E）。
  - 支持行内删除快捷键（Backspace/Delete/Ctrl+U/Ctrl+K/Ctrl+W）。
- rich 历史检索语义对齐：
  - Up/Down 在多行草稿内优先移动光标；
  - 仅在首行/末行边界触发历史切换。
- rich composer 渲染增强：
  - 光标所在行高亮 `>`；
  - 草稿视口会跟随光标滚动，保证编辑时光标始终可见。
- 新增单测覆盖：
  - 多行光标移动；
  - 词级删除；
  - composer 视图光标定位与换行边界。

## 2026-04-04 / Iteration 9.6（事件字段对齐 + 历史快捷键补齐）

- `QueryLoop` 事件通道对齐：
  - 文本模式与 `--stream-json` 统一走 provider 流式事件路径；
  - `onEvent` 在文本模式也可收到 `providerDelta`。
- `done` 字段对齐：
  - `done` 事件补齐 `model`；
  - `QueryLoopResult` 补齐 `status/modelUsed`，与事件终态一致。
- `loop` 文本模式输出增强：
  - 结束行改为 `turns + status + model`，与 `done` 事件字段保持一致。
- rich 输入快捷键补齐：
  - 新增 `Ctrl+P/Ctrl+N` 历史浏览（history prev/next）。
- 新增单测覆盖：
  - 文本模式 `onEvent` 可见 `providerDelta`；
  - `done` 事件与 `QueryLoopResult` 的 `status/model` 对齐。

## 2026-04-04 / Iteration 9.7（MVP 初始化链路补齐）

- 新增 `init` 命令（MVP 配置入口）：
  - `init --provider claude|openai --api-key ... [--base-url ...] [--model ...] [--config ...]`
  - 终端交互下缺省参数可提示输入（provider/api key 必填，baseUrl/model 可选）。
- REPL 新增 `/init` 最小命令（内联参数）：
  - `/init <claude|openai> <apiKey> [baseUrl] [model]`
  - 写入配置后立即切换当前会话 provider/model（无需重启 REPL）。
- 启动与 REPL 提示语义补齐：
  - provider 为 `local` 时提示“未配置真实 LLM，运行 `/init`”；
  - provider 为 `claude/openai` 但缺少 key 时提示“缺少 API key，运行 `/init`”；
  - `/provider` 切换后会同步给出同类提示。
- 启动欢迎页文案修正：
  - 将旧的“/init 创建 CLART.md”提示替换为“/init 或 `clart_code init` 配置 LLM”。
- 新增单测覆盖：
  - `init` 命令写入 provider/key/host/model；
  - provider 启动提示函数在 local/缺 key/已就绪路径下行为正确。

## 2026-04-04 / Iteration 9.8（rich 中文宽度与错误提示收敛）

- 修复 rich 输入中文光标错位：
  - 终端渲染从“按字符串长度”改为“按显示宽度”计算；
  - 中文等 CJK 字符按 2 列处理；
  - composer 换行、光标列、状态行/面板对齐统一走显示宽度逻辑。
- 新增单测覆盖：
  - `buildRichComposerView` 对中文输入的光标列计算；
  - `buildRichComposerView` 对中文宽字符换行切分。
- REPL provider 配置错误提示收敛：
  - provider 配置缺失类错误统一提示 `Run /init or clart_code init`。

## 下一步

- 继续补齐 `/init` 的 rich 模式逐步向导体验（避免内联明文 key 输入）。
- 收敛真实 LLM 往返链路与错误提示文案（网络/鉴权/host 分类），再进入 Iteration 10。
