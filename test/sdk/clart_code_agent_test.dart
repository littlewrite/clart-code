import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('query emits init delta assistant and result for local provider',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_query_');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
        ),
      );

      final messages = await agent.query('hello sdk').toList();
      expect(messages.map((message) => message.type), [
        'system',
        'assistant_delta',
        'assistant',
        'result',
      ]);
      expect(messages.first.subtype, 'init');
      expect(messages[1].delta, 'echo: hello sdk');
      expect(messages[2].text, 'echo: hello sdk');
      expect(messages[3].subtype, 'success');
      expect(messages[3].isError, false);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prompt persists session and can resume prior history', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_session_');

    try {
      final firstAgent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
        ),
      );
      final firstResult = await firstAgent.prompt('first prompt');
      expect(firstResult.isError, false);
      expect(firstAgent.getMessages(), hasLength(2));

      final resumedAgent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          resumeSessionId: firstAgent.sessionId,
        ),
      );
      expect(resumedAgent.getMessages(), hasLength(2));

      final secondResult = await resumedAgent.prompt('second prompt');
      expect(secondResult.isError, false);
      expect(resumedAgent.getMessages(), hasLength(4));

      final store = ClartCodeSessionStore(cwd: tempDir.path);
      final persisted = store.load(firstAgent.sessionId);
      expect(persisted, isNotNull);
      expect(persisted!.history, hasLength(4));
      expect(
        persisted.history.map((message) => message.text).toList(),
        containsAll(['first prompt', 'echo: first prompt', 'second prompt']),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prompt executes read tool loop and persists tool history', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_read_');
    final file = File('${tempDir.path}/note.txt');
    await file.writeAsString('sdk read body');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_read_1',
                      'name': 'read',
                      'input': {'path': file.path},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            return QueryResponse.success(
              output: 'final: ${toolPayloads.single['output']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('read that file');

      expect(result.isError, false);
      expect(result.turns, 2);
      expect(result.text, 'final: sdk read body');
      expect(result.messages.map((message) => message.type), [
        'system',
        'assistant_delta',
        'tool_call',
        'tool_result',
        'assistant_delta',
        'assistant',
        'result',
      ]);
      expect(result.messages[2].toolCall?.name, 'read');
      expect(result.messages[3].toolResult?.ok, true);
      expect(
        agent
            .getTranscript()
            .where(
                (message) => message.kind == TranscriptMessageKind.toolResult)
            .length,
        1,
      );
      expect(
        agent.getMessages().map((message) => message.role).toList(),
        [
          MessageRole.user,
          MessageRole.assistant,
          MessageRole.tool,
          MessageRole.assistant,
        ],
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prompt executes batched write and shell tools', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_batch_');
    final file = File('${tempDir.path}/written.txt');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_write_1',
                      'name': 'write',
                      'input': {
                        'path': file.path,
                        'content': 'hello from sdk',
                      },
                    },
                    {
                      'id': 'call_shell_1',
                      'name': 'shell',
                      'input': {'command': 'pwd'},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            final writePayload = toolPayloads.firstWhere(
              (payload) => payload['tool'] == 'write',
            );
            final shellPayload = toolPayloads.firstWhere(
              (payload) => payload['tool'] == 'shell',
            );
            return QueryResponse.success(
              output:
                  'write=${writePayload['ok']} shell=${shellPayload['ok']} shell_output=${shellPayload['output']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('write a file and check shell');

      expect(result.isError, false);
      expect(result.turns, 2);
      expect(await file.readAsString(), 'hello from sdk');
      expect(
        result.messages
            .where((message) => message.type == 'tool_result')
            .length,
        2,
      );
      final canonicalTempDir =
          Directory(tempDir.path).resolveSymbolicLinksSync();
      expect(result.text, contains('write=true'));
      expect(result.text, contains('shell=true'));
      expect(result.text, contains('shell_output=$canonicalTempDir'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prompt executes edit glob and grep tools', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_builtin_batch_',
    );
    final note = File('${tempDir.path}/note.txt');
    await note.writeAsString('alpha beta gamma');
    await Directory('${tempDir.path}/nested').create(recursive: true);
    await File('${tempDir.path}/nested/one.txt').writeAsString('first');
    await File('${tempDir.path}/nested/two.md').writeAsString('second');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_edit_1',
                      'name': 'edit',
                      'input': {
                        'path': 'note.txt',
                        'oldText': 'beta',
                        'newText': 'BETA',
                      },
                    },
                    {
                      'id': 'call_glob_1',
                      'name': 'glob',
                      'input': {'pattern': '**/*.txt'},
                    },
                    {
                      'id': 'call_grep_1',
                      'name': 'grep',
                      'input': {
                        'pattern': 'BETA',
                        'path': 'note.txt',
                      },
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            final editPayload = toolPayloads.firstWhere(
              (payload) => payload['tool'] == 'edit',
            );
            final globPayload = toolPayloads.firstWhere(
              (payload) => payload['tool'] == 'glob',
            );
            final grepPayload = toolPayloads.firstWhere(
              (payload) => payload['tool'] == 'grep',
            );
            return QueryResponse.success(
              output:
                  'edit=${editPayload['ok']} glob=${globPayload['output']} grep=${grepPayload['output']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('update and search');

      expect(result.isError, false);
      expect(await note.readAsString(), 'alpha BETA gamma');
      expect(result.text, contains('edit=true'));
      expect(result.text, contains('nested/one.txt'));
      expect(result.text, contains('note.txt:1:alpha BETA gamma'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('permissionMode deny surfaces denied tool result back to model',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_deny_');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          allowedTools: const ['shell'],
          permissionMode: ToolPermissionMode.deny,
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_shell_1',
                      'name': 'shell',
                      'input': {'command': 'pwd'},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            final payload = toolPayloads.single;
            return QueryResponse.success(
              output:
                  'handled=${payload['ok']} code=${payload['error_code']} message=${payload['error_message']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      expect(agent.availableTools, ['shell']);

      final result = await agent.prompt('try shell');

      expect(result.isError, false);
      expect(result.turns, 2);
      expect(result.text, contains('handled=false'));
      expect(result.text, contains('code=permission_denied'));
      final toolResultMessage = result.messages.firstWhere(
        (message) => message.type == 'tool_result',
      );
      expect(toolResultMessage.toolResult?.ok, false);
      expect(toolResultMessage.toolResult?.errorCode, 'permission_denied');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('permissionMode ask uses canUseTool and lifecycle hooks', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_ask_');
    final file = File('${tempDir.path}/hook.txt');
    await file.writeAsString('hook body');

    try {
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          allowedTools: const ['read'],
          permissionMode: ToolPermissionMode.ask,
          canUseTool: (toolCall, context) {
            lifecycle.add('can:${context.turn}:${toolCall.name}');
            return true;
          },
          hooks: ClartCodeAgentHooks(
            onSessionStart: (event) {
              lifecycle.add('session_start:${event.prompt}');
            },
            onPreToolUse: (event) {
              lifecycle.add('pre:${event.context.turn}:${event.toolCall.name}');
            },
            onPostToolUse: (event) {
              lifecycle.add(
                'post:${event.context.turn}:${event.toolCall.name}:${event.toolResult.ok}',
              );
            },
            onSessionEnd: (event) {
              lifecycle.add('session_end:${event.result.isError}');
            },
          ),
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_read_ask_1',
                      'name': 'read',
                      'input': {'path': file.path},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            return QueryResponse.success(
              output: 'allowed=${toolPayloads.single['ok']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('use ask mode');

      expect(result.isError, false);
      expect(result.text, 'allowed=true');
      expect(lifecycle, [
        'session_start:use ask mode',
        'can:1:read',
        'pre:1:read',
        'post:1:read:true',
        'session_end:false',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('canUseTool rejection surfaces failure hook for ask mode', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_ask_no_');

    try {
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          allowedTools: const ['shell'],
          permissionMode: ToolPermissionMode.ask,
          canUseTool: (toolCall, context) {
            lifecycle.add('can:${context.turn}:${toolCall.name}');
            return false;
          },
          hooks: ClartCodeAgentHooks(
            onPostToolUseFailure: (event) {
              lifecycle.add(
                'fail:${event.context.turn}:${event.toolCall.name}:${event.toolResult.errorCode}',
              );
            },
          ),
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_shell_ask_1',
                      'name': 'shell',
                      'input': {'command': 'pwd'},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            final payload = toolPayloads.single;
            return QueryResponse.success(
              output: 'handled=${payload['ok']} code=${payload['error_code']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('ask before shell');

      expect(result.isError, false);
      expect(result.text, 'handled=false code=permission_denied');
      expect(lifecycle, [
        'can:1:shell',
        'fail:1:shell:permission_denied',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('model turn hooks and permission decision hooks expose turn lifecycle',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_turn_hooks_');
    final file = File('${tempDir.path}/turn.txt');
    await file.writeAsString('turn body');

    try {
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          allowedTools: const ['read'],
          permissionMode: ToolPermissionMode.ask,
          canUseTool: (toolCall, context) {
            lifecycle.add('can:${context.turn}:${toolCall.name}');
            return true;
          },
          hooks: ClartCodeAgentHooks(
            onModelTurnStart: (event) {
              lifecycle.add(
                'turn_start:${event.turn}:${event.availableTools.contains('read')}',
              );
            },
            onModelTurnEnd: (event) {
              lifecycle.add(
                'turn_end:${event.turn}:${event.toolCalls.length}:${event.error == null}:${event.output}',
              );
            },
            onToolPermissionDecision: (event) {
              lifecycle.add(
                'permission:${event.context.turn}:${event.toolCall.name}:${event.decision.name}:${event.source.name}',
              );
            },
            onSessionEnd: (event) {
              lifecycle.add('session_end:${event.result.isError}');
            },
          ),
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_turn_read_1',
                      'name': 'read',
                      'input': {'path': file.path},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            return QueryResponse.success(
              output: 'final turn answer',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('exercise turn hooks');

      expect(result.isError, false);
      expect(result.text, 'final turn answer');
      expect(lifecycle, [
        'turn_start:1:true',
        'turn_end:1:1:true:{"tool_calls":[{"id":"call_turn_read_1","name":"read","input":{"path":"${file.path}"}}]}',
        'can:1:read',
        'permission:1:read:allow:canUseTool',
        'turn_start:2:true',
        'turn_end:2:0:true:final turn answer',
        'session_end:false',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prompt prefers provider-native tool calls when provider supports it',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_native_tool_');
    final file = File('${tempDir.path}/native.txt');
    await file.writeAsString('native body');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();

            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: '',
                modelUsed: 'native-mock',
                providerStateToken: 'resp_native_1',
                toolCalls: [
                  QueryToolCall(
                    id: 'call_read_native_1',
                    name: 'read',
                    input: {'path': file.path},
                  ),
                ],
              );
            }

            return QueryResponse.success(
              output: 'native final: ${toolPayloads.single['output']}',
              modelUsed: 'native-mock',
              providerStateToken: 'resp_native_2',
            );
          }),
        ),
      );

      final result = await agent.prompt('read this natively');

      expect(result.isError, false);
      expect(result.turns, 2);
      expect(result.text, 'native final: native body');
      expect(result.messages.map((message) => message.type), [
        'system',
        'tool_call',
        'tool_result',
        'assistant_delta',
        'assistant',
        'result',
      ]);
      expect(seenRequests, hasLength(2));
      expect(seenRequests.first.toolDefinitions, isNotEmpty);
      expect(
          seenRequests.first.messages
              .where((m) => m.role == MessageRole.system),
          isEmpty);
      expect(seenRequests[1].providerStateToken, 'resp_native_1');
      expect(
        seenRequests[1].messages.map((message) => message.role).toList(),
        [MessageRole.tool],
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prompt injects MCP tools into SDK agent runtime', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_mcp_');

    try {
      final manager = _FakeMcpManager();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          mcp: const ClartCodeMcpOptions(),
          mcpManagerOverride: manager,
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_mcp_1',
                      'name': 'demo/read_remote',
                      'input': {'path': '/remote/demo.txt'},
                    },
                  ],
                }),
                modelUsed: 'mcp-mock',
              );
            }

            return QueryResponse.success(
              output: 'mcp final: ${toolPayloads.single['output']}',
              modelUsed: 'mcp-mock',
            );
          }),
        ),
      );

      await agent.prepare();
      final result = await agent.prompt('use mcp tool');

      expect(result.isError, false);
      expect(result.text, 'mcp final: remote body');
      expect(manager.connectAllCalls, 1);
      expect(agent.mcpConnections, hasLength(1));
      expect(agent.failedMcpConnections, isEmpty);
      expect(agent.availableTools, contains('demo/read_remote'));
      expect(agent.availableTools, contains('mcp_list_resources'));
      expect(agent.availableTools, contains('mcp_read_resource'));
      expect(result.messages.first.tools, contains('demo/read_remote'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('agent transcript preserves MCP tool isError metadata', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_mcp_tool_error_',
    );

    try {
      final manager = _FakeMcpManager(
        onCallTool: (name, arguments) async => {
          'isError': true,
          'content': [
            {'type': 'text', 'text': 'remote denied'},
          ],
        },
      );
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          mcp: const ClartCodeMcpOptions(),
          mcpManagerOverride: manager,
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_mcp_error_1',
                      'name': 'demo/read_remote',
                      'input': {'path': '/remote/demo.txt'},
                    },
                  ],
                }),
                modelUsed: 'mcp-mock',
              );
            }

            final payload = toolPayloads.single;
            final metadata = Map<String, Object?>.from(
              payload['metadata'] as Map,
            );
            final content = (metadata['content'] as List).first as Map;
            return QueryResponse.success(
              output:
                  'ok=${payload['ok']} code=${payload['error_code']} server=${metadata['serverName']} tool=${metadata['toolName']} text=${content['text']}',
              modelUsed: 'mcp-mock',
            );
          }),
        ),
      );

      await agent.prepare();
      final result = await agent.prompt('use failing mcp tool');

      expect(result.isError, false);
      expect(result.text, contains('ok=false'));
      expect(result.text, contains('code=mcp_tool_error'));
      expect(result.text, contains('server=demo'));
      expect(result.text, contains('tool=read_remote'));
      expect(result.text, contains('text=remote denied'));
      final toolResultMessage = result.messages.firstWhere(
        (message) => message.type == 'tool_result',
      );
      expect(toolResultMessage.toolResult?.ok, isFalse);
      expect(toolResultMessage.toolResult?.errorCode, 'mcp_tool_error');
      expect(toolResultMessage.toolResult?.metadata?['serverName'], 'demo');
      expect(
          toolResultMessage.toolResult?.metadata?['toolName'], 'read_remote');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('agent transcript preserves MCP resource failure metadata', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_mcp_resource_error_',
    );

    try {
      final manager = _FakeMcpManager(
        onReadResource: (uri) async {
          throw McpOperationException.resourceNotFound(
            serverName: 'demo',
            resourceUri: 'docs/missing.md',
            rpcCode: -32010,
            rpcMessage: 'Resource not found',
          );
        },
      );
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          mcp: const ClartCodeMcpOptions(),
          mcpManagerOverride: manager,
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_mcp_resource_error_1',
                      'name': 'mcp_read_resource',
                      'input': {'uri': 'demo://docs/missing.md'},
                    },
                  ],
                }),
                modelUsed: 'mcp-mock',
              );
            }

            final payload = toolPayloads.single;
            final metadata = Map<String, Object?>.from(
              payload['metadata'] as Map,
            );
            return QueryResponse.success(
              output:
                  'ok=${payload['ok']} code=${payload['error_code']} uri=${metadata['resourceUri']} rpc=${metadata['rpcCode']}',
              modelUsed: 'mcp-mock',
            );
          }),
        ),
      );

      await agent.prepare();
      final result = await agent.prompt('read missing mcp resource');

      expect(result.isError, false);
      expect(result.text, contains('ok=false'));
      expect(result.text, contains('code=resource_not_found'));
      expect(result.text, contains('uri=docs/missing.md'));
      expect(result.text, contains('rpc=-32010'));
      final toolResultMessage = result.messages.firstWhere(
        (message) => message.type == 'tool_result',
      );
      expect(toolResultMessage.toolResult?.ok, isFalse);
      expect(toolResultMessage.toolResult?.errorCode, 'resource_not_found');
      expect(
        toolResultMessage.toolResult?.metadata?['resourceUri'],
        'docs/missing.md',
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('agent registers custom tools directly from options.tools', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_custom_tools_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          tools: const [_CustomEchoTool()],
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_custom_1',
                      'name': 'custom_echo',
                      'input': {'text': 'hello tool'},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            return QueryResponse.success(
              output: 'custom=${toolPayloads.single['output']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('use custom tool');

      expect(result.isError, false);
      expect(result.text, 'custom=HELLO TOOL');
      expect(agent.availableTools, contains('custom_echo'));
      final definition = agent.toolDefinitions.firstWhere(
        (tool) => tool.name == 'custom_echo',
      );
      expect(definition.title, 'Custom Echo');
      expect(definition.annotations, {'category': 'test'});
      expect(definition.inputSchema?['type'], 'object');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('resolveToolPermission can rewrite input before tool execution',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_permission_rewrite_',
    );

    try {
      final decisions = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          allowedTools: const ['shell'],
          permissionMode: ToolPermissionMode.ask,
          resolveToolPermission: (toolCall, context) {
            expect(context.turn, 1);
            expect(toolCall.name, 'shell');
            return ClartCodeToolPermissionOutcome.allow(
              updatedInput: {'command': 'echo rewritten'},
            );
          },
          hooks: ClartCodeAgentHooks(
            onToolPermissionDecision: (event) {
              decisions.add(
                'decision:${event.decision.name}:${event.source.name}:${event.updatedInput?['command']}',
              );
            },
          ),
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_shell_rewrite_1',
                      'name': 'shell',
                      'input': {'command': 'echo original'},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            final payload = toolPayloads.single;
            return QueryResponse.success(
              output: 'output=${payload['output']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('rewrite shell input');

      expect(result.isError, false);
      expect(result.text, contains('rewritten'));
      expect(result.text, isNot(contains('echo original')));
      expect(
        decisions,
        ['decision:allow:resolveToolPermission:echo rewritten'],
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('resolveToolPermission denial message flows into tool result', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_permission_deny_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          allowedTools: const ['shell'],
          permissionMode: ToolPermissionMode.ask,
          resolveToolPermission: (toolCall, context) {
            expect(context.turn, 1);
            expect(toolCall.name, 'shell');
            return ClartCodeToolPermissionOutcome.deny(
              message: 'shell rejected by custom resolver',
            );
          },
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_shell_reject_1',
                      'name': 'shell',
                      'input': {'command': 'pwd'},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            final payload = toolPayloads.single;
            return QueryResponse.success(
              output:
                  'handled=${payload['ok']} message=${payload['error_message']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('deny shell');

      expect(result.isError, false);
      expect(result.text, contains('handled=false'));
      expect(result.text, contains('shell rejected by custom resolver'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('concurrent prompt calls are serialized through session queue',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_queue_serial_');

    try {
      final provider = _QueuedPromptProvider();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: provider,
          persistSession: false,
        ),
      );

      final firstPending = agent.prompt('first queued prompt');
      await provider.firstStarted.future;
      final secondPending = agent.prompt('second queued prompt');
      await Future<void>.delayed(Duration.zero);

      expect(agent.isRunning, isTrue);
      expect(agent.queuedInputCount, 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.seenPrompts, ['first queued prompt']);

      provider.releaseFirst.complete();
      final firstResult = await firstPending;
      await provider.secondStarted.future;
      final secondResult = await secondPending;

      expect(firstResult.isError, isFalse);
      expect(firstResult.text, 'reply:first queued prompt');
      expect(secondResult.isError, isFalse);
      expect(secondResult.text, 'reply:second queued prompt');
      expect(provider.seenPrompts, [
        'first queued prompt',
        'second queued prompt',
      ]);
      expect(agent.queuedInputCount, 0);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('clearQueuedInputs cancels pending prompts without touching active run',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_queue_clear_');

    try {
      final provider = _QueuedPromptProvider();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: provider,
          persistSession: false,
        ),
      );

      final firstPending = agent.prompt('active prompt');
      await provider.firstStarted.future;
      final secondPending = agent.prompt('queued prompt 1');
      final thirdPending = agent.prompt('queued prompt 2');
      await Future<void>.delayed(Duration.zero);

      expect(agent.queuedInputCount, 2);
      final cleared = await agent.clearQueuedInputs(reason: 'clear_queue');
      final secondResult = await secondPending;
      final thirdResult = await thirdPending;

      expect(cleared, 2);
      expect(secondResult.isError, isTrue);
      expect(secondResult.error?.code, RuntimeErrorCode.cancelled);
      expect(secondResult.turns, 0);
      expect(thirdResult.isError, isTrue);
      expect(thirdResult.error?.code, RuntimeErrorCode.cancelled);
      expect(provider.seenPrompts, ['active prompt']);
      expect(agent.queuedInputCount, 0);

      provider.releaseFirst.complete();
      final firstResult = await firstPending;
      expect(firstResult.isError, isFalse);
      expect(firstResult.text, 'reply:active prompt');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prepare exposes unsupported MCP transports without injecting tools',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_mcp_unsupported_',
    );
    final registryFile = File('${tempDir.path}/.clart/mcp_servers.json');
    await registryFile.parent.create(recursive: true);
    await registryFile.writeAsString(jsonEncode({
      'mcpServers': {
        'remote': {
          'type': 'http',
          'url': 'https://example.com/mcp',
        },
      },
    }));

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          mcp: const ClartCodeMcpOptions(),
        ),
      );

      await agent.prepare();

      expect(agent.mcpConnections, hasLength(1));
      expect(agent.mcpConnections.single.name, 'remote');
      expect(agent.mcpConnections.single.status, McpServerStatus.failed);
      expect(
        agent.mcpConnections.single.error,
        contains('current Dart runtime supports: stdio'),
      );
      expect(agent.failedMcpConnections, hasLength(1));
      expect(agent.availableTools, isNot(contains('mcp_list_resources')));
      expect(
        agent.availableTools.where((tool) => tool.startsWith('remote/')),
        isEmpty,
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('stop requests provider cancellation', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_stop_');

    try {
      final provider = _CancelableProvider();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: provider,
          persistSession: false,
        ),
      );

      final pending = agent.prompt('wait for cancel');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await agent.stop();
      final result = await pending;

      expect(provider.cancelCalled, isTrue);
      expect(result.isError, isTrue);
      expect(result.error?.code, RuntimeErrorCode.cancelled);
      expect(result.text, contains('STOPPED'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('interrupt cancels active prompt and automatically runs queued prompt',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_interrupt_queue_');

    try {
      final provider = _QueuedPromptProvider();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: provider,
          persistSession: false,
        ),
      );

      final firstPending = agent.prompt('interrupt me');
      await provider.firstStarted.future;
      final secondPending = agent.prompt('run after interrupt');
      await Future<void>.delayed(Duration.zero);

      expect(agent.queuedInputCount, 1);
      await agent.interrupt(reason: 'switch_to_next');

      final firstResult = await firstPending;
      await provider.secondStarted.future;
      final secondResult = await secondPending;

      expect(provider.cancelCalled, isTrue);
      expect(firstResult.isError, isTrue);
      expect(firstResult.error?.code, RuntimeErrorCode.cancelled);
      expect(secondResult.isError, isFalse);
      expect(secondResult.text, 'reply:run after interrupt');
      expect(provider.seenPrompts, [
        'interrupt me',
        'run after interrupt',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('cancelled terminal hook receives stop reason', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_stop_hooks_');

    try {
      final lifecycle = <String>[];
      final provider = _CancelableProvider();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: provider,
          persistSession: false,
          hooks: ClartCodeAgentHooks(
            onStop: (event) {
              lifecycle.add('stop:${event.reason}');
            },
            onCancelledTerminal: (event) {
              lifecycle.add(
                'cancelled:${event.reason}:${event.result.error?.code.name}:${event.result.text.contains('[STOPPED]')}',
              );
            },
            onSessionEnd: (event) {
              lifecycle.add('session_end:${event.result.error?.code.name}');
            },
          ),
        ),
      );

      final pending = agent.prompt('wait for cancel hook');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await agent.stop(reason: 'hook_stop');
      final result = await pending;

      expect(result.isError, isTrue);
      expect(result.error?.code, RuntimeErrorCode.cancelled);
      expect(lifecycle, [
        'stop:hook_stop',
        'cancelled:hook_stop:cancelled:true',
        'session_end:cancelled',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });
}

Map<String, Object?> _decodeToolPayload(String raw) {
  return Map<String, Object?>.from(jsonDecode(raw) as Map);
}

class _ScriptedToolLoopProvider extends LlmProvider {
  _ScriptedToolLoopProvider(this._handler);

  final QueryResponse Function(QueryRequest request) _handler;

  @override
  Future<QueryResponse> run(QueryRequest request) async => _handler(request);
}

class _NativeToolLoopProvider extends NativeToolCallingLlmProvider {
  _NativeToolLoopProvider(this._handler);

  final QueryResponse Function(QueryRequest request) _handler;

  @override
  Future<QueryResponse> run(QueryRequest request) async => _handler(request);
}

class _FakeMcpManager extends McpManager {
  _FakeMcpManager({
    this.onCallTool,
    this.onReadResource,
  }) : super(registryPath: '/tmp/fake_mcp_registry.json');

  int connectAllCalls = 0;
  List<McpConnection> _connections = const [];
  final FutureOr<Map<String, Object?>> Function(
    String name,
    Map<String, Object?>? arguments,
  )? onCallTool;
  final FutureOr<McpResourceContent> Function(String uri)? onReadResource;

  @override
  Future<List<McpConnection>> connectAll() async {
    connectAllCalls += 1;
    _connections = [
      McpConnection(
        name: 'demo',
        status: McpServerStatus.connected,
        config: const McpStdioServerConfig(
          name: 'demo',
          command: 'node',
        ),
        capabilities: const McpServerCapabilities(
          tools: true,
          resources: true,
        ),
        serverInfo: const McpServerInfo(name: 'demo-server', version: '1.0.0'),
      ),
    ];
    return _connections;
  }

  @override
  List<McpConnection> getAllConnections() => _connections;

  @override
  Future<List<McpTool>> listAllTools() async {
    return const [
      McpTool(
        name: 'demo/read_remote',
        description: 'Read a remote file from MCP.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
      ),
    ];
  }

  @override
  Future<Map<String, Object?>> callTool({
    required String name,
    Map<String, Object?>? arguments,
  }) async {
    if (onCallTool != null) {
      return await onCallTool!(name, arguments);
    }
    return {
      'content': [
        {'type': 'text', 'text': 'remote body'},
      ],
    };
  }

  @override
  Future<McpResourceContent> readResource(String uri) async {
    if (onReadResource != null) {
      return await onReadResource!(uri);
    }
    return const McpResourceContent(
      uri: 'docs://guide.md',
      mimeType: 'text/plain',
      text: 'resource body',
    );
  }
}

class _CancelableProvider extends LlmProvider {
  final Completer<void> _cancelled = Completer<void>();
  bool cancelCalled = false;

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    await _cancelled.future;
    throw StateError('cancelled');
  }

  @override
  Future<void> cancelActiveRequest() async {
    cancelCalled = true;
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  @override
  Future<QueryResponse> run(QueryRequest request) {
    throw UnimplementedError();
  }
}

class _QueuedPromptProvider extends LlmProvider {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> secondStarted = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  final List<String> seenPrompts = <String>[];
  Completer<void>? _activeCancellation;
  bool cancelCalled = false;

  @override
  Future<void> cancelActiveRequest() async {
    cancelCalled = true;
    if (_activeCancellation != null && !_activeCancellation!.isCompleted) {
      _activeCancellation!.complete();
    }
  }

  @override
  Future<QueryResponse> run(QueryRequest request) {
    throw UnimplementedError();
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    final prompt = request.messages.last.text;
    seenPrompts.add(prompt);

    if (seenPrompts.length == 1) {
      if (!firstStarted.isCompleted) {
        firstStarted.complete();
      }
      _activeCancellation = Completer<void>();
      await Future.any([
        releaseFirst.future,
        _activeCancellation!.future,
      ]);
      if (_activeCancellation!.isCompleted && !releaseFirst.isCompleted) {
        return;
      }
    } else if (seenPrompts.length == 2 && !secondStarted.isCompleted) {
      secondStarted.complete();
    }

    yield ProviderStreamEvent.done(output: 'reply:$prompt');
  }
}

class _CustomEchoTool implements Tool {
  const _CustomEchoTool();

  @override
  String get name => 'custom_echo';

  @override
  String? get title => 'Custom Echo';

  @override
  String get description => 'Uppercases input text for SDK tool registration.';

  @override
  Map<String, Object?>? get annotations => const {
        'category': 'test',
      };

  @override
  Map<String, Object?>? get inputSchema => const {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
      };

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    final text = invocation.input['text'] as String? ?? '';
    return ToolExecutionResult.success(
      tool: name,
      output: text.toUpperCase(),
    );
  }
}
