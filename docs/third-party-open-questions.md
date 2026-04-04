# Third-Party Open Questions

用于记录“TS 依赖在 Dart 无直接等价实现”的决策点。
已落地库与 TS 能力映射见：`docs/third-party-lib-mapping.md`。

## 模板

- 能力名称：
- TS 现有依赖：
- Dart 候选方案：
- 临时方案（stub/mock）：
- 风险：
- 需要你确认：

## 当前列表

- 能力名称：终端渲染与键盘交互（TUI/Prompt）
- TS 现有依赖：Ink/React + 交互式终端组件
- Dart 候选方案：
  - `dart_console`（低层控制，窗口尺寸/光标/按键/raw mode）
  - `interact_cli`（选择器、确认框、spinner 等现成组件）
  - `mason_logger`（交互日志与基础确认/进度能力）
- 临时方案（stub/mock）：
  - 已引入 `dart_console` 并在启动面板中最小接入，仍保留 `dart:io` 回退。
- 风险：
  - 第三方库引入后需要处理跨平台终端差异（macOS/Linux/Windows）。
  - 与现有命令解析/事件流的适配成本需要单独评估。
- 需要你确认：
  - 已确认：`dart_console` 继续作为主渲染底座推进。
  - 已确认：引入 `interact_cli` 替代手写 trust 选择输入。

- 能力名称：LLM API SDK（OpenAI 通道）
- TS 现有依赖：内部 provider + 多通道适配
- Dart 候选方案：
  - `dart_openai`（已引入并用于 `openai` provider 最小实接）
  - `http` + 自实现 adapter（备选）
- 临时方案（stub/mock）：
  - `openai/claude` provider 均可用，且已接入统一 provider 级流式事件抽象。
- 风险：
  - 多 provider 的配置字段会继续增长，后续建议收敛到统一 provider 配置结构。
  - SDK 升级可能带来模型参数结构变更。
- 需要你确认：
  - 已确认：保留 `claude` provider 名称与通道。
