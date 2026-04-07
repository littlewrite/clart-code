# Clart Code SDK 下一阶段能力规划

> 目的：围绕 `tools`、`skills`、`MCP`、`multi-agent` 四块，回答两个问题：
>
> 1. 它们是不是当前 agent SDK 需要实现的能力？
> 2. 如果要实现，应该从 `./claude-code` 提取哪些源码入口和工作包？

## 结论先行

### 1. Tools

判断：`是，必须属于 agent SDK 主线`

原因：

- agent SDK 的核心价值就是“程序化 agent loop + tool loop”
- 没有稳定的 tool 平台，SDK 只是 provider wrapper
- `open-agent-sdk-typescript` 也把 tool system 作为核心 public API

当前判断：

- Dart 侧已有最小闭环
- 但离“健全”还有明显距离
- 下一阶段应该继续做，而且优先级最高

### 2. MCP

判断：`是，属于 agent SDK 主线`

原因：

- MCP 是 SDK 侧扩展工具与资源的重要标准入口
- 对程序化调用来说，MCP 比 CLI 命令更接近 SDK 的自然边界
- `open-agent-sdk-typescript` 也把 MCP integration 当作一等能力

当前判断：

- Dart 侧已有最小接入
- 但目前还不健全
- 必须继续做，而且优先级与 tools 同级

### 3. Skills

判断：`是，但不属于当前最前面的 P0`

原因：

- skills 本质上是“可复用 prompt/template capability”
- 对 SDK 有价值，但前提是 tool / MCP / hook / permission 基座先稳定
- 否则 skill 只是 prompt 包装，落地价值有限

当前判断：

- Dart 侧基本未实现
- 可以纳入下一阶段规划
- 但排在 tools/MCP 基座之后

### 4. Multi-agent

判断：`最终应该属于 agent SDK，但不应现在优先做重型版本`

原因：

- `open-agent-sdk-typescript` 已把 subagent / team coordination 纳入 SDK 能力面
- 但这类能力高度依赖稳定的 tool / session / interrupt / permission / hooks 语义
- 如果基础层还不稳，multi-agent 会把复杂度放大

当前判断：

- Dart 侧基本未实现
- 只适合做“最小 subagent API”
- 不适合现在直接追 Claude Code 的 team/coordinator/background/remote 版本

## 从 `./claude-code` 提取出来的相关源码入口

### Tools

核心入口：

- `./claude-code/src/Tool.ts`
- `./claude-code/src/tools.ts`
- `./claude-code/src/services/tools/toolOrchestration.ts`
- `./claude-code/src/services/tools/toolExecution.ts`
- `./claude-code/src/services/tools/toolHooks.ts`

主要工具目录：

- `./claude-code/src/tools/BashTool/*`
- `./claude-code/src/tools/FileReadTool/*`
- `./claude-code/src/tools/FileWriteTool/*`
- `./claude-code/src/tools/FileEditTool/*`
- `./claude-code/src/tools/GlobTool/*`
- `./claude-code/src/tools/GrepTool/*`
- `./claude-code/src/tools/NotebookEditTool/*`
- `./claude-code/src/tools/WebFetchTool/*`
- `./claude-code/src/tools/WebSearchTool/*`
- `./claude-code/src/tools/AskUserQuestionTool/*`
- `./claude-code/src/tools/ToolSearchTool/*`

当前 Dart 对应代码：

- `lib/src/tools/tool_models.dart`
- `lib/src/tools/tool_registry.dart`
- `lib/src/tools/tool_scheduler.dart`
- `lib/src/tools/tool_executor.dart`
- `lib/src/tools/builtin_tools.dart`
- `lib/src/sdk/clart_code_agent.dart`

### Skills

核心入口：

- `./claude-code/src/tools/SkillTool/SkillTool.ts`
- `./claude-code/src/skills/bundledSkills.ts`
- `./claude-code/src/skills/loadSkillsDir.ts`
- `./claude-code/src/skills/mcpSkillBuilders.ts`
- `./claude-code/src/skills/bundled/*`

当前 Dart 对应代码：

- 暂无稳定 SDK 代码

### MCP

核心入口：

- `./claude-code/src/services/mcp/client.ts`
- `./claude-code/src/services/mcp/types.ts`
- `./claude-code/src/services/mcp/config.ts`
- `./claude-code/src/services/mcp/MCPConnectionManager.tsx`
- `./claude-code/src/tools/MCPTool/*`
- `./claude-code/src/tools/ListMcpResourcesTool/*`
- `./claude-code/src/tools/ReadMcpResourceTool/*`
- `./claude-code/src/tools/McpAuthTool/*`

当前 Dart 对应代码：

- `lib/src/mcp/mcp_types.dart`
- `lib/src/mcp/mcp_client.dart`
- `lib/src/mcp/mcp_manager.dart`
- `lib/src/mcp/mcp_stdio_transport.dart`
- `lib/src/tools/mcp_tools.dart`
- `lib/src/sdk/clart_code_agent.dart`

### Multi-agent

核心入口：

- `./claude-code/src/tools/AgentTool/*`
- `./claude-code/src/tools/SendMessageTool/*`
- `./claude-code/src/tools/TeamCreateTool/*`
- `./claude-code/src/tools/TeamDeleteTool/*`
- `./claude-code/src/tools/shared/spawnMultiAgent.ts`
- `./claude-code/src/tasks/LocalAgentTask/*`
- `./claude-code/src/tasks/InProcessTeammateTask/*`
- `./claude-code/src/tasks/RemoteAgentTask/*`

当前 Dart 对应代码：

- 暂无稳定 SDK 代码

## 当前 Dart 状态与是否健全

| 能力 | 当前状态 | 是否健全 | 说明 |
| --- | --- | --- | --- |
| Tools | 有最小闭环 | 否 | loop/permission/hooks 有，内建工具仍过少，`shell` 还是 stub |
| Skills | 基本未实现 | 否 | 当前 SDK 没有 skill registry / loader / skill tool |
| MCP | 有最小接入 | 否 | stdio 基本可用，但格式、传输能力和 SDK/CLI 对齐还不完整 |
| Multi-agent | 基本未实现 | 否 | 当前没有 subagent/team public API |

## 现在最该做的实现顺序

### Phase A: Tool 平台补强

优先级：`P0`

目标：

- 让 Dart SDK 的 tool system 从“最小可跑”变成“稳定可扩展”

工作包：

- 实现真实 `shell` tool，替换当前 stub
- 设计更顺手的 SDK custom tool registration API
  - 当前虽然可以注入 `ToolExecutor`
  - 但这还不是好用的 public SDK 体验
- 补 richer permission decision
  - 不只 `bool`
  - 至少支持 deny reason / maybe updated input / terminal event
- 补更细粒度 tool lifecycle hooks
- 扩大工具集时，优先做 SDK 核心工具
  - `read`
  - `write`
  - `edit`
  - `glob`
  - `grep`
  - `shell`

建议主要参考：

- `./claude-code/src/Tool.ts`
- `./claude-code/src/tools.ts`
- `./claude-code/src/services/tools/toolOrchestration.ts`
- `/Users/th/Node/open-agent-sdk-typescript/src/index.ts`

### Phase B: MCP 补强与统一

优先级：`P0`

目标：

- 让 MCP 成为 SDK 的稳定扩展层，而不是最小桥接

前置问题，必须先修：

- SDK 默认读取的 MCP 注册表，与 CLI 当前写入的 `.clart/mcp_servers.json` 格式不一致
- 类型层和 CLI 命令层声明了 `stdio/sse/http/ws`
- 但 SDK 当前真正实现的只有 `stdio`

工作包：

- 统一 SDK/CLI 的 MCP registry format
  - 要么统一读写一种格式
  - 要么做兼容解析与迁移
- 明确 Dart SDK 当前正式支持的 transport
  - 如果只支持 `stdio`，就不要继续对外伪装成 `sse/http/ws` 已可用
- 完善 MCP tool/resource error 语义与测试
- 评估是否需要 SDK 级 in-process MCP server helper
  - 对齐 `open-agent-sdk-typescript` 的 `createSdkMcpServer` 能力面

建议主要参考：

- `./claude-code/src/services/mcp/*`
- `./claude-code/src/tools/MCPTool/*`
- `/Users/th/Node/open-agent-sdk-typescript/src/sdk-mcp-server.ts`

## 下一步直接开工：`tools + MCP` 实现设计拆解

### 先说结论

如果下一步只开一个工作面，应该先做 `MCP registry 对齐`，再进入 `tool public API + builtin tools`。

原因不是 MCP 比 tools 更重要，而是当前两者已经耦合在一起：

- SDK agent 会在启动时通过 `ClartCodeMcpOptions` 读取 `.clart/mcp_servers.json`
- CLI 当前也在写 `.clart/mcp_servers.json`
- 但两边理解的文件格式不同，导致 MCP 作为 SDK 扩展层还不稳定
- 这个问题不先收敛，后面继续补 tool platform 时，MCP 仍然会是一个不可靠入口

### 当前代码现状核对

MCP 相关现状：

- SDK/agent 侧：
  - `lib/src/sdk/clart_code_agent.dart`
  - `lib/src/mcp/mcp_manager.dart`
  - `lib/src/mcp/mcp_types.dart`
  - `lib/src/tools/mcp_tools.dart`
- CLI/workspace 侧：
  - `lib/src/cli/workspace_store.dart`
  - `lib/src/cli/runner.dart`
  - `lib/src/cli/repl_command_dispatcher.dart`

已经确认的实际问题：

- SDK `McpManager.loadRegistry()` 当前读取的是：
  - `{"servers": { "<name>": { "command": "...", "args": [...] }}}`
- CLI `workspace_store.dart` / `runner.dart` 当前写入的是：
  - `[{"name":"...","transport":"stdio|sse|http|ws","target":"..."}]`
- 仓库根目录还存在一个更接近 Claude Code / open-agent-sdk-typescript 的格式：
  - `.mcp.json`
  - `{"mcpServers": { "<name>": { ... }}}`
- Dart 当前真正可用的 transport 只有 `stdio`
- 但类型和 CLI 参数仍然对外暴露 `sse/http/ws`

这意味着当前最合理的 P0 起点不是“继续加更多 MCP 功能”，而是：

1. 先统一 registry model
2. 再收缩 transport 语义
3. 然后补工具层和 MCP 错误语义

### 设计决策

#### 1. MCP registry 采用单一 canonical schema

建议把 `.clart/mcp_servers.json` 的 canonical schema 统一为：

```json
{
  "mcpServers": {
    "filesystem": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "env": {
        "KEY": "value"
      }
    }
  }
}
```

理由：

- 这和 `claude-code` 的 `.mcp.json` / `open-agent-sdk-typescript` 的 `mcpServers` 口径一致
- 名称到配置的 map 结构比 CLI 现在的数组结构更适合 SDK 直接装载
- 后续如要引入 `sdk` in-process server，也能自然扩展

同时保留兼容读取，但不再继续扩散旧格式：

- 兼容读旧 SDK 格式：`{"servers": {...}}`
- 兼容读旧 CLI 格式：`[{name, transport, target}]`
- 统一写新格式：`{"mcpServers": {...}}`

#### 2. transport 能力要按真实实现收缩

下一轮不应继续对外暗示 Dart SDK 已支持完整 `sse/http/ws`。

建议策略：

- SDK 的正式运行时支持：`stdio`
- registry parser 可识别 `sse/http/ws` 条目，但应明确标记为 unsupported
- CLI `mcp add` 如果仍保留，应先只接受 `stdio`，或者至少在写入时明确报错 unsupported transport

这比“先把类型写大，后面再补实现”更稳，因为当前最重要的是让 SDK 行为和文档一致。

#### 3. tools 与 MCP 要通过统一 registry/registry loader 接口衔接

下一步不建议继续让 `ClartCodeAgent` 直接拼接 MCP 装载细节。

更合理的结构是：

- `McpRegistryLoader`
  - 只负责读取/兼容解析/迁移 registry 文件
- `McpManager`
  - 只负责连接与协议调用
- `buildMcpTools()`
  - 只负责把已连接 server 暴露成 tool definitions
- `ClartCodeAgent`
  - 只负责在 runtime prepare 阶段调用上面三层

这样后面补 `sdk` in-process MCP server 时，不需要重新拆 agent。

### 具体任务清单

#### P0-1. MCP registry 对齐

目标：

- 让 SDK、CLI、文档对 `.clart/mcp_servers.json` 的理解一致

任务：

- 在 `lib/src/mcp` 下补独立 registry model / parser / writer
- `McpManager.loadRegistry()` 改为读取 canonical `mcpServers`
- 同时兼容：
  - 旧 `servers` map 格式
  - 旧 CLI `List<WorkspaceMcpServer>` 格式
- `McpManager.saveRegistry()` 统一写回 `mcpServers`
- 给旧 CLI list format 加迁移测试
- 给旧 SDK `servers` format 加兼容测试
- 明确 malformed / unsupported entry 的错误语义

建议落地文件：

- `lib/src/mcp/mcp_registry.dart` 新增
- `lib/src/mcp/mcp_manager.dart`
- `test/mcp/mcp_manager_test.dart`
- 新增 `test/mcp/mcp_registry_test.dart`

收尾标准：

- 同一份 `.clart/mcp_servers.json` 能被 SDK 正确读取
- 旧格式文件首次被保存后会落成 canonical schema
- 文档中不再同时出现三种互相冲突的 registry 说法

#### P0-2. transport 语义收缩到真实能力

目标：

- 让 public API、CLI 行为、文档都明确“当前只正式支持 stdio”

任务：

- 审查 `lib/src/mcp/mcp_types.dart` 的 transport type 暴露
- 区分：
  - parser 可识别的 transport
  - runtime 真正支持的 transport
- `runner.dart` 的 `mcp add` 调整为：
  - 仅支持 `stdio`
  - 或对 `sse/http/ws` 给出明确 unsupported 错误
- `/mcp` 与 `export` 输出改为基于 canonical MCP config，而不是旧 `target` 串
- 同步修正文档里的 transport 描述

建议落地文件：

- `lib/src/mcp/mcp_types.dart`
- `lib/src/cli/runner.dart`
- `lib/src/cli/repl_command_dispatcher.dart`
- `lib/src/cli/workspace_store.dart`
- `test/clart_code_test.dart`

收尾标准：

- 用户无法再通过 CLI 成功写入“看起来可用、实际上 SDK 不支持”的 transport 配置
- 文档、CLI help、类型定义不再相互矛盾

#### P0-3. Tool public API 补强

目标：

- 让 tool platform 从“最小闭环”变成“稳定 SDK public API”

任务：

- 重新梳理 `Tool` / `ToolInvocation` / `ToolExecutionResult`
- 增加更清晰的 SDK 侧 custom tool 注册入口
  - 不只接受整个 `ToolExecutor`
  - 也支持直接传 `tools`
- 为后续 richer permission result 预留结构
  - 当前 `canUseTool` 是 `bool`
  - 下一轮应能扩到 `allow/deny + message + updated input`
- 让 tool metadata 更接近 `open-agent-sdk-typescript` 的 tool definition

建议落地文件：

- `lib/src/tools/tool_models.dart`
- `lib/src/tools/tool_registry.dart`
- `lib/src/tools/tool_executor.dart`
- `lib/src/sdk/sdk_models.dart`
- `lib/src/sdk/clart_code_agent.dart`

收尾标准：

- SDK 用户可以不用手工组装 `ToolExecutor` 也能注册 custom tools
- 后续扩 permission/hook 不需要再推翻 tool base model

#### P0-4. builtin tools 第一批补齐

目标：

- 把 P0 工具集补到能支撑真实 agent loop

范围建议：

- `shell`：替换当前 stub
- `edit`
- `glob`
- `grep`

说明：

- `read` / `write` 已有最小实现，但仍需要后续补输入约束与错误语义
- `shell` 是最优先，因为现在它还是 stub，明显不满足 SDK 主线预期

建议落地文件：

- `lib/src/tools/builtin_tools.dart`
- 如需要可拆分：
  - `lib/src/tools/shell_tool.dart`
  - `lib/src/tools/file_edit_tool.dart`
  - `lib/src/tools/glob_tool.dart`
  - `lib/src/tools/grep_tool.dart`
- `test/tools/*`
- `test/sdk/clart_code_agent_test.dart`

收尾标准：

- `ToolExecutor.minimal()` 不再包含 stub shell
- SDK agent 能在真实工具链下完成至少 `read/write/edit/glob/grep/shell` 的基本闭环测试

#### P0-5. MCP tool/resource 错误语义补齐

目标：

- 让 MCP tool/resource 在 SDK 里具备稳定、可预测的错误行为

任务：

- 区分：
  - server 未连接
  - tool 不存在
  - MCP 返回 `isError`
  - resource 不存在
  - unsupported transport
- `McpToolWrapper` / `McpReadResourceTool` / `McpListResourcesTool` 输出统一 error code
- 让 agent transcript / tool_result 能保留足够的 MCP 错误信息

建议落地文件：

- `lib/src/tools/mcp_tools.dart`
- `lib/src/mcp/mcp_manager.dart`
- `test/sdk/clart_code_agent_test.dart`
- 新增 `test/tools/mcp_tools_test.dart`

收尾标准：

- MCP 工具失败时，模型收到的是稳定结构，而不是零散字符串错误
- 失败路径有独立测试，不只测 happy path

#### P0-6. in-process MCP server helper 评估

目标：

- 判断这一轮是否顺手补一个最小 `createSdkMcpServer` 对应物

建议判断：

- 如果 P0-1 到 P0-5 结束后结构已稳定，可以做最小版
- 如果 registry/transport/tool public API 还在收敛，不要抢先做

最小可接受范围：

- 只支持内存内 tool list
- 不做 remote transport
- 不做 auth
- 不做完整 Claude Code product layer 封装

### 建议执行顺序

建议直接按下面顺序落地，而不是把 tools 和 MCP 平铺并行：

1. `P0-1 MCP registry 对齐`
2. `P0-2 transport 语义收缩`
3. `P0-3 Tool public API 补强`
4. `P0-4 builtin tools 第一批补齐`
5. `P0-5 MCP tool/resource 错误语义补齐`
6. `P0-6 in-process MCP helper 评估`

### 对应的首批测试清单

- `test/mcp/mcp_registry_test.dart`
  - 旧 CLI list format -> canonical parse
  - 旧 SDK `servers` format -> canonical parse
  - canonical write-back
- `test/mcp/mcp_manager_test.dart`
  - unsupported transport
  - malformed config
  - missing server
- `test/tools/mcp_tools_test.dart`
  - tool call success/failure
  - read resource success/failure
- `test/tools/tool_scheduler_test.dart`
  - richer permission result 接口扩展时不回归
- `test/sdk/clart_code_agent_test.dart`
  - agent 首轮装载 canonical MCP registry
  - canonical MCP config 下 tool/resource 注入
  - builtin shell 非 stub 闭环

### Phase C: Skills 最小实现

优先级：`P1`

目标：

- 给 SDK 一个最小但真实可用的 skill system

建议范围：

- skill definition/registry
- bundled skills 初始化
- local skills directory loading
- `SkillTool` 最小实现
- skill prompt blocks / metadata / allowed tools

当前不要急着做的部分：

- MCP skill builders
- 很重的 frontmatter / hooks / managed/plugin skill 来源

建议主要参考：

- `./claude-code/src/tools/SkillTool/SkillTool.ts`
- `./claude-code/src/skills/bundledSkills.ts`
- `./claude-code/src/skills/loadSkillsDir.ts`
- `/Users/th/Node/open-agent-sdk-typescript/src/index.ts`

### Phase D: Multi-agent 最小实现

优先级：`P2`

目标：

- 只做“SDK 意义上的最小 subagent API”

建议范围：

- agent definition
- `AgentTool` 最小版
- one-shot subagent invocation
- 父子 session / event / cancellation 关系

当前不要急着做的部分：

- `SendMessageTool`
- `TeamCreateTool`
- `TeamDeleteTool`
- background agents
- remote agents
- teammate/coordinator/swarm

原因：

- 这些都明显更靠近 Claude Code 的产品层，而不是当前 Dart SDK 的第一阶段主干

建议主要参考：

- `./claude-code/src/tools/AgentTool/*`
- `./claude-code/src/tools/shared/spawnMultiAgent.ts`
- `/Users/th/Node/open-agent-sdk-typescript/examples/09-subagents.ts`

## 哪些是 agent SDK 必须实现的，哪些不是

### 应该纳入 agent SDK 主线

- tool platform
- MCP integration
- skills 的最小 public API
- multi-agent 的最小 subagent API

### 暂时不应该纳入当前 agent SDK 主线

- Claude Code 的 team/coordinator/swarm 模式
- remote/background agent orchestration
- MCP auth/OAuth/full remote transport product layer
- workflow / cron / monitor
- 与 UI 深耦合的 tool/skill/agent 交互

## 建议的落地顺序

1. 先补 `tools + MCP`
2. 再做 `skills`
3. 最后做 `multi-agent` 最小版

如果顺序反过来，后面实现 multi-agent 时会反复返工：

- permission
- interrupt/cancel
- session
- tool loop
- MCP integration

## 这份规划对后续工作的直接指导

后续如果继续推进 SDK，这四块不应该被当成同优先级并行开工，而应该拆成：

- 第一批：`tools`、`MCP`
- 第二批：`skills`
- 第三批：`multi-agent`

其中：

- `tools` 和 `MCP` 是“SDK 基座继续补强”
- `skills` 是“建立复用能力层”
- `multi-agent` 是“在基座稳定之后追加的高级能力”
