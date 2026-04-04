# Third-Party Library Mapping (Dart ↔ TS)

> 目的：记录 Dart 迁移中引入的三方库、用途，以及在 TS 侧的对应能力来源（库名或模块域）。

## 当前映射

| Dart 库 | 当前用途 | TS 侧对应能力/库 |
| --- | --- | --- |
| `dart_console` | 终端尺寸、光标与基础控制（启动页面板宽度适配） | Ink/React 终端渲染能力（`src/screens/*`, `src/components/*`） |
| `interact_cli` | 交互式选择组件（`start` 的 trust 选择器） | REPL/Prompt 交互组件能力（TS 侧由 Ink 组件体系实现） |
| `mason_logger` | 统一 CLI 文本输出样式（info/warn/success 等） | 终端日志样式与提示能力（TS 侧 console/样式化输出能力域） |
| `dart_openai` | `openai` provider 的最小 chat + stream 调用 | TS 侧 LLM provider SDK 调用能力（provider 层） |
| `dart:io` `HttpClient` | `claude` provider 的最小 HTTP + SSE stream 调用 | TS 侧 Claude provider HTTP/SDK 调用能力（provider 层） |

## 说明

- 当前仓库内 `claudecode` 目录未包含 `package.json`，因此部分 TS 映射以“能力域”标注，而非精确 npm 包名。
- 后续若补齐 TS 依赖清单，可将本表升级为“Dart 包 ↔ 精确 npm 包”一一对应。
