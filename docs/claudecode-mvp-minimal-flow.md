# Clart MVP 最小功能流（启动 / 初始化 / 事件循环）

目标：先做“可真正调用 LLM 并稳定交互”的最小闭环。  
暂缓：context 压缩、skills、MCP、复杂权限与多 agent 编排。

## 1. MVP 范围（P0）

- 可启动：`fvm dart run ./bin/clart_code.dart`
- 可初始化 provider 与 key（交互式）
- 可在 REPL 中发送消息并拿到真实 LLM 回复（非本地 echo）
- 可中断流式输出，且不中断会话
- 可查看/切换 provider 与 model
- 可持久化配置并在下次自动生效

## 2. 启动流程（Start Flow）

对齐 `claude-code` 的最小思路：先进入统一入口，再决定交互模式与 provider 状态。

1. CLI 入口解析参数与 config（已有）
2. trust gate（已有）
3. 若是交互终端，进入 REPL（已有）
4. 若当前 provider=`local` 且未配置远端 key，给出强提示并引导 `/init`

当前差距：默认 `local` 会导致“只能 echo”，用户感知为“没接上模型”。

## 3. 初始化流程（Init Flow）

新增最小 `/init`（REPL 内）：

1. 选择 provider：`openai | claude`
2. 输入 `apiKey`（可选 baseUrl）
3. 可选输入 model（留空走 provider 默认）
4. 持久化到 `./.clart/config.json`（复用现有 `auth` 写入逻辑）
5. 当前会话立即切换到新 provider/model（无需重启）
6. 回显脱敏配置摘要 + 一条“可直接提问”的状态提示

这样用户第一轮就能真正拿到 LLM 回复，不会停在 echo。

## 4. 事件循环流程（Loop Flow）

最小事件模型保持：

- `turnStart`
- `providerDelta`
- `assistant | error`
- `done(status/model/turns/output)`

当前状态：文本模式与 `--stream-json` 已对齐到同一路径（Iteration 9.6）。

MVP 要求：

- REPL 默认文本渲染（用户可选 rich）
- rich/plain 均可 `Ctrl+C` 中断当前流式回答
- 出错时输出统一错误文案，并保持 REPL 可继续下一轮

## 5. 交付标准（Definition of Done）

- 新用户从零开始，3 分钟内完成：
  - 启动
  - `/init`
  - 发送问题并拿到真实 LLM 回复
- `dart test` 全绿
- `flutter analyze` 无问题
- 文档包含：
  - 启动指引
  - `/init` 使用说明
  - provider/key/model 常见错误处理

## 6. 建议实施顺序（按天）

Day 1:
- 实现 `/init` 交互向导（仅 provider + key + model）
- 复用现有配置写入与 session 切换

Day 2:
- REPL 启动时 provider 状态检查与提示
- 错误提示与帮助文案收敛

Day 3:
- 回归测试 + 文档补齐 + 小范围手测（openai/claude 各一条）

## 7. 当前进度（2026-04-04）

- [x] `init` 命令落地（provider/key/host/model 写入配置）
- [x] REPL `/init` 最小命令落地（内联参数，当前会话即时切换）
- [x] provider 未配置提示落地（启动/切换时提示运行 `/init`）
- [x] rich 输入稳定性补齐（UTF-8 中文输入 + CJK 2 列宽光标/换行）
- [ ] rich 模式逐步式 `/init` 向导（隐藏明文 key 输入）
- [ ] provider 失败错误文案细化（network/auth/host 分类）

## 8. 下个会话计划（可直接执行）

1. 添加单元测试覆盖核心模块（query_engine, turn_executor, providers）。
2. 实现 Tool 并发分组调度（当前仅串行）。
3. 实现 Task 后台任务系统（基础版）。
4. 做一次端到端手测脚本（local/openai/claude 各一条）并补文档。
