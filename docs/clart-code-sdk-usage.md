# Clart Code SDK 使用文档

> 时间：2026-04-08
>
> 目标：给当前 Dart SDK 一份“现在就能试”的使用说明，只写当前仓库里已经存在并可用的能力。

## 适用范围

当前文档覆盖这些已可用能力：

- `ClartCodeAgent`
- top-level `query()` / `prompt()` / `runSubagent()`
- request / output control
- 内置 tools 与自定义 tools
- MCP
- skills
- named agents / subagent
- session / cancellation / hooks
- token / cost / model usage observability

不覆盖尚未完成或尚未稳定公开的能力：

- `sse/http/ws` MCP runtime transport
- send-message/team/background subagent

## 1. 引入 SDK

```dart
import 'package:clart_code/clart_code_sdk.dart';
```

SDK 入口导出见 `lib/clart_code_sdk.dart`。

## 2. 最小可运行示例

### 2.1 本地 echo provider

```dart
import 'package:clart_code/clart_code_sdk.dart';

Future<void> main() async {
  final agent = ClartCodeAgent(
    const ClartCodeAgentOptions(
      provider: ProviderKind.local,
      persistSession: false,
    ),
  );

  final result = await agent.prompt('hello sdk');
  print(result.text);
  await agent.close();
}
```

### 2.2 OpenAI-compatible provider

```dart
import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart';

Future<void> main() async {
  final agent = ClartCodeAgent(
    ClartCodeAgentOptions(
      provider: ProviderKind.openai,
      openAiApiKey: Platform.environment['OPENAI_API_KEY'],
      openAiBaseUrl: Platform.environment['OPENAI_BASE_URL'],
      model: Platform.environment['OPENAI_MODEL'] ?? 'gpt-4o-mini',
      persistSession: false,
    ),
  );

  final result = await agent.prompt('Reply with exactly CLART_OK.');
  print(result.text);
  await agent.close();
}
```

可参考 `examples/sdk_openai_agent.dart`。

## 3. `query()` 与 `prompt()` 的区别

- `query()` 返回 `Stream<ClartCodeSdkMessage>`，适合流式消费事件
- `prompt()` 返回 `Future<ClartCodePromptResult>`，适合一次性拿最终结果

### 3.1 流式 query

```dart
final agent = ClartCodeAgent(
  const ClartCodeAgentOptions(persistSession: false),
);

await for (final message in agent.query('hello')) {
  if (message.type == 'assistant_delta' && message.delta != null) {
    stdout.write(message.delta);
  }
  if (message.type == 'result') {
    stdout.writeln('\nsubtype=${message.subtype} error=${message.isError}');
  }
}
```

### 3.2 top-level helper

```dart
final result = await prompt(
  prompt: 'hello',
  options: const ClartCodeAgentOptions(
    provider: ProviderKind.local,
    persistSession: false,
  ),
);

print(result.text);
```

top-level helper 会自动创建并关闭 agent。

## 4. 当前可用的事件类型

当前 stream 里你可以稳定看到这些类型：

- `system`
- `assistant_delta`
- `assistant`
- `tool_call`
- `tool_result`
- `result`
- `subagent`
- `skill`

在 `includeObservabilityMessages=true` 时，额外还可以看到：

- `system/status`
- `system/compact_boundary`
- `stream_event`
- `rate_limit_event`

其中：

- `subagent` / `skill` 是 Dart 侧额外补的最小 lifecycle surface
- 主基线事件仍然是 `system/init + assistant_delta + assistant + tool_call + tool_result + result`
- `system/status` 当前会覆盖最小 runtime producer：`running_model` / `running_tools` / `compacting`
- `system/compact_boundary` 当前会在 provider-native continuation 切到 `providerStateToken` 时出现
- `stream_event` / `rate_limit_event` 默认关闭，避免把 provider 原始噪声直接塞进常规 stream

## 5. Tools

### 5.1 默认内置 tools

当前默认最核心的 builtin tools 是：

- `read`
- `write`
- `edit`
- `glob`
- `grep`
- `shell`

如果启用了 skills / agents / MCP，对应还会注入：

- `skill`
- `agent`
- `mcp_list_resources`
- `mcp_read_resource`
- `server/tool_name` 形式的 MCP tool

### 5.2 限制可用 tools

```dart
final agent = ClartCodeAgent(
  const ClartCodeAgentOptions(
    allowedTools: ['read', 'grep'],
    persistSession: false,
  ),
);
```

或者：

```dart
final agent = ClartCodeAgent(
  const ClartCodeAgentOptions(
    disallowedTools: ['write', 'shell'],
    persistSession: false,
  ),
);
```

### 5.3 注入自定义 Tool

当前有两种方式：

- 直接实现 `Tool` 接口
- 用最小 closure helper：`tool()` / `defineTool()`

更推荐先用 `tool()`，样板会少很多：

```dart
import 'package:clart_code/clart_code_sdk.dart';

final echoMathTool = tool(
  name: 'echo_math',
  description: 'Echo a math expression without evaluating it.',
  inputSchema: const {
    'type': 'object',
    'properties': {
      'expression': {
        'type': 'string',
        'description': 'Math expression text.',
      },
    },
    'required': ['expression'],
  },
  executionHint: ToolExecutionHint.parallelSafe,
  run: (invocation) => ToolExecutionResult.success(
    tool: 'echo_math',
    output: 'expression=${invocation.input['expression'] ?? ''}',
  ),
);

final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    tools: [
      ...ToolExecutor.baseTools(),
      echoMathTool,
    ],
    persistSession: false,
  ),
);
```

如果你只是想在默认 builtin tools 基础上追加自定义工具，也可以继续用：

```dart
final executor = ToolExecutor.fromTools([
  ...ToolExecutor.baseTools(),
  echoMathTool,
]);
```

如果你需要更复杂的封装或复用状态，仍然可以直接实现 `Tool` 接口：

```dart
import 'package:clart_code/clart_code_sdk.dart';

class EchoMathTool implements Tool {
  @override
  String get name => 'echo_math';

  @override
  String get description => 'Echo a math expression without evaluating it.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'expression': {
            'type': 'string',
            'description': 'Math expression text.',
          },
        },
        'required': ['expression'],
      };

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final expression = invocation.input['expression'] as String? ?? '';
    return ToolExecutionResult.success(
      tool: name,
      output: 'expression=$expression',
    );
  }
}

final executor = ToolExecutor.minimal().withAdditionalTools([
  EchoMathTool(),
]);

final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    toolExecutor: executor,
    persistSession: false,
  ),
);
```

当前已补最小 `tool()` / `defineTool()` helper DSL，但相比 TS 仍缺更强的 typed args / helper 生态。

### 5.4 Tool 权限

#### 用 policy 做静态规则

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    permissionPolicy: ToolPermissionPolicy(
      defaultMode: ToolPermissionMode.ask,
      rules: {
        'read': ToolPermissionRule(
          toolName: 'read',
          mode: ToolPermissionMode.allow,
        ),
        'write': ToolPermissionRule(
          toolName: 'write',
          mode: ToolPermissionMode.deny,
          description: 'Read-only run',
        ),
      },
    ),
    persistSession: false,
  ),
);
```

#### 用 callback 做动态决策

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    resolveToolPermission: (toolCall, context) {
      if (toolCall.name == 'shell') {
        return ClartCodeToolPermissionOutcome.deny(
          message: 'shell is disabled in this run',
        );
      }
      return ClartCodeToolPermissionOutcome.allow();
    },
    persistSession: false,
  ),
);
```

## 6. MCP

### 6.1 in-process SDK MCP server

这是当前最容易直接试的方式。

```dart
import 'package:clart_code/clart_code_sdk.dart';

class LocalEchoTool implements Tool {
  @override
  String get name => 'echo_local';

  @override
  String get description => 'Echo back the message.';

  @override
  Map<String, Object?> get inputSchema => const {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
        'required': ['message'],
      };

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final message = invocation.input['message'] as String? ?? '';
    return ToolExecutionResult(
      tool: name,
      ok: true,
      output: 'sdk:$message',
    );
  }
}

final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    mcp: ClartCodeMcpOptions(
      sdkServers: [
        createSdkMcpServer(
          name: 'local',
          version: '1.0.0',
          tools: [LocalEchoTool()],
        ),
      ],
    ),
    persistSession: false,
  ),
);
```

这样模型侧可见的工具名会是：

- `local/echo_local`

### 6.2 使用工作区注册表里的 MCP server

默认注册表路径是：

- `.clart/mcp_servers.json`

也可以显式传：

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    cwd: '/path/to/project',
    mcp: const ClartCodeMcpOptions(
      registryPath: '/path/to/project/.clart/mcp_servers.json',
    ),
  ),
);
```

如果只想连接部分 server：

```dart
mcp: const ClartCodeMcpOptions(
  serverNames: ['filesystem', 'fetcher'],
)
```

### 6.3 资源工具

默认 `includeResourceTools = true`，会额外注入：

- `mcp_list_resources`
- `mcp_read_resource`

如果你只想要 MCP tools，不想暴露 resource tools：

```dart
mcp: const ClartCodeMcpOptions(
  includeResourceTools: false,
)
```

### 6.4 当前限制

当前 Dart runtime 真正支持的 MCP transport 只有：

- `stdio`
- `sdk`

`sse/http/ws` 现在还不是运行时已完成能力。

## 7. Skills

### 7.1 代码里直接注册 skills

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    skills: ClartCodeSkillsOptions(
      includeBundledSkills: false,
      skills: [
        ClartCodeSkillDefinition(
          name: 'review_local',
          description: 'Review code in a focused scope.',
          whenToUse: 'Use when the user asks for a focused review.',
          argumentHint: '[scope]',
          allowedTools: const ['read', 'grep'],
          getPrompt: (args, context) async => [
            ClartCodeSkillContentBlock.text(
              'Review carefully.${args.trim().isEmpty ? '' : '\nScope: ${args.trim()}'}',
            ),
            ClartCodeSkillContentBlock.text(
              'Turn=${context.turn};Model=${context.model}',
            ),
          ],
        ),
      ],
    ),
    persistSession: false,
  ),
);
```

启用后：

- `skill` tool 会自动进入 tool pool
- agent system prompt 里会出现 `Available skills:`
- 模型可以调用 `skill` tool 触发该 skill

### 7.2 slash-prefixed name

当前 skill lookup 兼容：

- `review`
- `/review`

### 7.3 禁止模型调用

```dart
ClartCodeSkillDefinition(
  name: 'slash_only',
  description: 'Only for explicit slash-style invocation.',
  disableModelInvocation: true,
  getPrompt: (args, context) async => const [
    ClartCodeSkillContentBlock.text('slash-only prompt'),
  ],
)
```

效果：

- 模型看不到它
- 通过 `skill` tool 主动传这个 skill 名时会返回稳定错误

### 7.4 从目录加载 skills

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    skills: ClartCodeSkillsOptions(
      directories: ['/path/to/skills'],
    ),
  ),
);
```

目录里会递归查找 `SKILL.md`。

一个最小 `SKILL.md` 例子：

```md
---
name: review_local
description: Focused review skill
when_to_use: Use when the user asks for a code review
argument_hint: [scope]
allowed_tools: [read, grep]
context: inline
model: review-model
effort: medium
---

Review the requested scope carefully and return findings first.
```

当前 frontmatter 支持的常用字段包括：

- `name`
- `description`
- `aliases`
- `when_to_use`
- `argument_hint`
- `allowed_tools`
- `disallowed_tools`
- `context`
- `agent`
- `model`
- `effort`
- `disable-model-invocation`
- `cascade-assistant-deltas`

### 7.5 forked skill

如果 skill 配置为：

- `context: fork`

它会在 child agent 中执行，而不是只把 prompt 内联回当前 query。

## 8. Named Agents 与 `runSubagent()`

### 8.1 代码里注册 named agents

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    agents: const ClartCodeAgentsOptions(
      agents: [
        ClartCodeAgentDefinition(
          name: 'code-reviewer',
          description: 'Review code with a tight read-only scope.',
          prompt: 'Review the requested code carefully and return findings first.',
          allowedTools: ['read'],
          disallowedTools: ['write'],
          model: 'review-model',
          effort: ClartCodeReasoningEffort.medium,
        ),
      ],
    ),
    persistSession: false,
  ),
);
```

启用后：

- `agent` tool 会注入
- 模型可以调用 named agent

### 8.2 one-shot subagent API

```dart
final result = await agent.runSubagent(
  'inspect the target',
  options: const ClartCodeSubagentOptions(
    name: 'reviewer',
    model: 'child-model',
    allowedTools: ['read'],
    promptPrefix: 'You are a focused reviewer.',
  ),
);

print(result.text);
```

### 8.3 从目录加载 agents

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    agents: ClartCodeAgentsOptions(
      directories: ['/path/to/agents'],
    ),
  ),
);
```

目录里会递归加载 markdown 文件。

一个最小 agent markdown 示例：

```md
---
name: code-reviewer
description: Focused code reviewer
tools: [read, grep]
model: review-model
effort: medium
inherit_mcp: true
---

Review the delegated target carefully and return findings first.
```

## 9. Session

### 9.1 自动持久化

默认会持久化到当前工作区：

- `.clart/sessions/<id>.json`
- `.clart/active_session.json`

关闭持久化：

```dart
const ClartCodeAgentOptions(
  persistSession: false,
)
```

### 9.2 resume 指定 session

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    cwd: '/path/to/project',
    resumeSessionId: 'existing-session-id',
  ),
);
```

### 9.3 continue latest / active session helper

```dart
final latest = await continueLatestPrompt(
  prompt: 'follow up',
  options: ClartCodeAgentOptions(cwd: '/path/to/project'),
);

await for (final message in continueActiveQuery(
  prompt: 'one more thing',
  options: ClartCodeAgentOptions(cwd: '/path/to/project'),
)) {
  // consume stream
}
```

如果当前 workspace 还没有 session，这些 helper 会退化为新建 session。

### 9.4 读当前 session snapshot

```dart
final snapshot = agent.snapshot();
print(snapshot.id);
print(snapshot.title);
print(snapshot.tags);
```

### 9.5 修改 session metadata

```dart
agent.renameSession('My Session');
agent.setSessionTags(['sdk', 'review']);
agent.addSessionTag('phase2');
agent.removeSessionTag('review');
final forked = agent.forkSession(title: 'Forked Session');
```

## 10. Cancellation / Interrupt

### 10.1 request-scoped cancellation

```dart
final controller = QueryCancellationController();

final future = agent.prompt(
  'long running task',
  cancellationSignal: controller.signal,
);

controller.cancel('manual cancel');
final result = await future;
```

### 10.2 interrupt active run

```dart
await agent.interrupt(reason: 'manual_interrupt');
```

### 10.3 清理排队请求

```dart
final cleared = await agent.clearQueuedInputs(
  reason: 'queued inputs cleared',
);
print(cleared);
```

## 11. Hooks

```dart
final agent = ClartCodeAgent(
  ClartCodeAgentOptions(
    hooks: ClartCodeAgentHooks(
      onSessionStart: (event) {
        print('session start: ${event.sessionId}');
      },
      onModelTurnStart: (event) {
        print('turn start: ${event.turn}');
      },
      onToolPermissionDecision: (event) {
        print('permission: ${event.toolCall.name} -> ${event.decision.name}');
      },
      onSubagentStart: (event) {
        print('subagent start: ${event.name}');
      },
      onSubagentEnd: (event) {
        print('subagent end: ${event.name} error=${event.result.isError}');
      },
    ),
    persistSession: false,
  ),
);
```

当前已有的 hook 面主要包括：

- session start / end
- stop
- model turn start / end
- pre / post tool use
- tool permission decision
- cancelled terminal
- subagent start / end
- skill activation / end

## 12. 当前最建议你先试的路径

建议按这个顺序感受当前 SDK：

1. 先跑最小 `prompt()` / `query()`
2. 再试 `allowedTools` / `disallowedTools`
3. 再试自定义 `Tool`
4. 再试 in-process MCP server
5. 再试 programmatic skill
6. 最后试 named agent + `runSubagent()`

## 13. 当前已知缺口

在试用时你最可能感受到这些还没补齐：

- `maxBudgetUsd` 现在已做 best-effort runtime enforcement，但仍依赖 provider 返回 `costUsd`
- `status` / `compact_boundary` 现在已有最小 live producer，但还没有真正的 compact service
- 自定义 tool 已有最小 helper DSL，但更强的 typed helper 还没有
- MCP runtime transport 还没有 `sse/http/ws`
- 还没有 send-message/team/background agent

这些缺口的持续清单见：

- [docs/clart-code-sdk-completeness-review.md](clart-code-sdk-completeness-review.md)
