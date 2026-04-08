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

  test('agent loads skills and exposes skill tool to the model', () async {
    final tempDir = await Directory.systemTemp.createTemp('clart_sdk_skill_');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
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
                    'Review the requested scope carefully and return findings first.${args.trim().isEmpty ? '' : '\nScope: ${args.trim()}'}',
                  ),
                  ClartCodeSkillContentBlock.text(
                    'Turn=${context.turn};Model=${context.model}',
                  ),
                ],
              ),
              ClartCodeSkillDefinition(
                name: 'slash_only',
                description: 'Only for explicit slash-style user invocation.',
                disableModelInvocation: true,
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('slash-only prompt'),
                ],
              ),
            ],
          ),
          providerOverride: _ScriptedToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              final systemPrompt = request.messages
                  .where((message) => message.role == MessageRole.system)
                  .map((message) => message.text)
                  .join('\n');
              expect(systemPrompt, contains('Available skills:'));
              expect(systemPrompt, contains('review_local'));
              expect(systemPrompt, contains('focused review'));
              expect(systemPrompt, isNot(contains('slash_only')));

              return QueryResponse.success(
                output: jsonEncode({
                  'tool_calls': [
                    {
                      'id': 'call_skill_1',
                      'name': 'skill',
                      'input': {
                        'skill': 'review_local',
                        'args': 'lib/src/sdk',
                      },
                    },
                  ],
                }),
                modelUsed: 'skill-mock',
              );
            }

            final skillPayload = toolPayloads.single;
            expect(skillPayload['tool'], 'skill');
            expect(skillPayload['ok'], isTrue);
            expect(
              skillPayload['output'],
              contains('Review the requested scope carefully'),
            );
            expect(skillPayload['output'], contains('Turn=1;Model=skill-mock'));
            final metadata =
                Map<String, Object?>.from(skillPayload['metadata'] as Map);
            expect(metadata['skill'], 'review_local');
            expect(metadata['context'], 'inline');
            expect(metadata['allowed_tools'], ['read', 'grep']);

            return QueryResponse.success(
              output: 'skill applied: ${metadata['skill']}',
              modelUsed: 'skill-mock',
            );
          }),
        ),
      );

      await agent.prepare();
      expect(agent.availableSkills, ['review_local']);
      expect(agent.availableTools, contains('skill'));

      final result = await agent.prompt('review this SDK surface');

      expect(result.isError, isFalse);
      expect(result.text, 'skill applied: review_local');
      expect(
        result.messages.first.toolDefinitions?.map((tool) => tool.name),
        contains('skill'),
      );
      expect(
        result.messages
            .where((message) => message.type == 'tool_result')
            .single
            .toolResult
            ?.metadata?['skill'],
        'review_local',
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test(
      'active skill narrows tools and overrides model and effort for later turns',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_runtime_');

    try {
      final seenRequests = <QueryRequest>[];
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          effort: ClartCodeReasoningEffort.low,
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'review_local',
                description: 'Review code in a focused scope.',
                allowedTools: const ['read'],
                model: 'skill-model',
                effort: ClartCodeReasoningEffort.high,
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text(
                    'Review the requested scope carefully and only read files.',
                  ),
                ],
              ),
            ],
          ),
          hooks: ClartCodeAgentHooks(
            onModelTurnStart: (event) {
              lifecycle.add(
                'turn:${event.turn}:model=${event.model}:tools=${event.availableTools.join(',')}',
              );
            },
            onToolPermissionDecision: (event) {
              lifecycle.add(
                'permission:${event.context.turn}:${event.toolCall.name}:${event.decision.name}:${event.source.name}:${event.message}',
              );
            },
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (seenRequests.length == 1) {
              expect(request.effort, ClartCodeReasoningEffort.low);
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_runtime_1',
                    name: 'skill',
                    input: {'skill': 'review_local'},
                  ),
                ],
              );
            }

            if (toolPayloads.length == 1) {
              expect(request.model, 'skill-model');
              expect(request.effort, ClartCodeReasoningEffort.high);
              final toolNames =
                  request.toolDefinitions.map((tool) => tool.name).toList();
              expect(toolNames, containsAll(['skill', 'read']));
              expect(toolNames, isNot(contains('write')));
              final skillPayload = toolPayloads.single;
              expect(skillPayload['tool'], 'skill');
              expect(skillPayload['ok'], isTrue);
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_write_runtime_1',
                    name: 'write',
                    input: {
                      'path': 'blocked.txt',
                      'content': 'should not run',
                    },
                  ),
                ],
              );
            }

            expect(request.model, 'skill-model');
            expect(request.effort, ClartCodeReasoningEffort.high);
            final deniedPayload = toolPayloads.last;
            expect(deniedPayload['tool'], 'write');
            expect(deniedPayload['ok'], isFalse);
            expect(deniedPayload['error_code'], 'permission_denied');
            expect(
              deniedPayload['error_message'],
              contains('not allowed while skill "review_local" is active'),
            );
            final toolNames =
                request.toolDefinitions.map((tool) => tool.name).toList();
            expect(toolNames, containsAll(['skill', 'read']));
            expect(toolNames, isNot(contains('write')));

            return QueryResponse.success(
              output: 'final skill-constrained answer',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('review this codebase with the skill');

      expect(result.isError, isFalse);
      expect(result.text, 'final skill-constrained answer');
      expect(result.turns, 3);
      expect(seenRequests, hasLength(3));
      expect(
          lifecycle,
          contains(
              'turn:1:model=base-model:tools=edit,glob,grep,read,shell,skill,write'));
      expect(lifecycle, contains('turn:2:model=skill-model:tools=read,skill'));
      expect(lifecycle, contains('turn:3:model=skill-model:tools=read,skill'));
      expect(
        lifecycle.where((entry) => entry.contains('permission:2:write')).single,
        contains(
            ':skill:tool "write" is not allowed while skill "review_local" is active'),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('inline skill scope is limited to the current query', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_scope_');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'review_local',
                description: 'Review in read-only mode for one query.',
                allowedTools: const ['read'],
                model: 'skill-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text(
                    'Review carefully and stay read-only for this query only.',
                  ),
                ],
              ),
            ],
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            switch (seenRequests.length) {
              case 1:
                expect(request.model, 'base-model');
                expect(
                  request.toolDefinitions.map((tool) => tool.name),
                  containsAll(['skill', 'read', 'write']),
                );
                return QueryResponse.success(
                  output: '',
                  modelUsed: request.model,
                  toolCalls: const [
                    QueryToolCall(
                      id: 'call_skill_scope_1',
                      name: 'skill',
                      input: {'skill': 'review_local'},
                    ),
                  ],
                );
              case 2:
                expect(request.model, 'skill-model');
                expect(
                  request.toolDefinitions.map((tool) => tool.name),
                  containsAll(['skill', 'read']),
                );
                expect(
                  request.toolDefinitions.map((tool) => tool.name),
                  isNot(contains('write')),
                );
                final skillPayload = request.messages
                    .where((message) => message.role == MessageRole.tool)
                    .map((message) => _decodeToolPayload(message.text))
                    .last;
                final metadata =
                    Map<String, Object?>.from(skillPayload['metadata'] as Map);
                expect(metadata['runtime_scope'], 'current_query');
                expect(metadata['cleanup_boundary'], 'query_end');
                return QueryResponse.success(
                  output: 'first query complete',
                  modelUsed: request.model,
                );
              case 3:
                expect(request.model, 'base-model');
                expect(
                  request.toolDefinitions.map((tool) => tool.name),
                  containsAll(['skill', 'read', 'write']),
                );
                return QueryResponse.success(
                  output: '',
                  modelUsed: request.model,
                  toolCalls: const [
                    QueryToolCall(
                      id: 'call_write_scope_1',
                      name: 'write',
                      input: {
                        'path': 'scoped.txt',
                        'content': 'second query write',
                      },
                    ),
                  ],
                );
              case 4:
                expect(request.model, 'base-model');
                expect(
                  request.toolDefinitions.map((tool) => tool.name),
                  containsAll(['skill', 'read', 'write']),
                );
                final writePayload = request.messages
                    .where((message) => message.role == MessageRole.tool)
                    .map((message) => _decodeToolPayload(message.text))
                    .last;
                expect(writePayload['tool'], 'write');
                expect(writePayload['ok'], isTrue);
                return QueryResponse.success(
                  output: 'second query complete',
                  modelUsed: request.model,
                );
            }
            fail('unexpected request count: ${seenRequests.length}');
          }),
        ),
      );

      final first = await agent.prompt('activate the review skill');
      final second = await agent.prompt('write a file after the skill query');

      expect(first.isError, isFalse);
      expect(first.text, 'first query complete');
      expect(second.isError, isFalse);
      expect(second.text, 'second query complete');
      expect(seenRequests, hasLength(4));
      expect(
        File('${tempDir.path}/scoped.txt').readAsStringSync(),
        'second query write',
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('inline skill lifecycle hooks expose activation replacement and cleanup',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_hooks_');

    try {
      final seenRequests = <QueryRequest>[];
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'read_only',
                description: 'Only read files.',
                allowedTools: const ['read'],
                model: 'read-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Read only.'),
                ],
              ),
              ClartCodeSkillDefinition(
                name: 'shell_only',
                description: 'Only use shell.',
                allowedTools: const ['shell'],
                model: 'shell-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Shell only.'),
                ],
              ),
            ],
          ),
          hooks: ClartCodeAgentHooks(
            onSkillActivation: (event) {
              lifecycle.add(
                'start:${event.name}:${event.turn}:${event.model}:${(event.allowedTools ?? const []).join(',')}:${event.runtimeScope}:${event.cleanupBoundary}',
              );
            },
            onSkillEnd: (event) {
              lifecycle.add(
                'end:${event.name}:${event.reason}:${event.activatedTurn}->${event.endedTurn}:${event.model}:${(event.allowedTools ?? const []).join(',')}',
              );
            },
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (seenRequests.length == 1) {
              expect(request.model, 'base-model');
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_hook_1',
                    name: 'skill',
                    input: {'skill': 'read_only'},
                  ),
                ],
              );
            }

            if (seenRequests.length == 2) {
              expect(request.model, 'read-model');
              expect(toolPayloads.single['tool'], 'skill');
              expect(toolPayloads.single['ok'], isTrue);
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_hook_2',
                    name: 'skill',
                    input: {'skill': 'shell_only'},
                  ),
                ],
              );
            }

            expect(request.model, 'shell-model');
            expect(toolPayloads.last['tool'], 'skill');
            expect(toolPayloads.last['ok'], isTrue);
            return QueryResponse.success(
              output: 'hooked skill answer',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('exercise inline skill hooks');

      expect(result.isError, isFalse);
      expect(result.text, 'hooked skill answer');
      expect(seenRequests, hasLength(3));
      expect(lifecycle, [
        'start:read_only:1:read-model:read,skill:current_query:query_end',
        'end:read_only:replaced_by_skill:1->2:read-model:read,skill',
        'start:shell_only:2:shell-model:shell,skill:current_query:query_end',
        'end:shell_only:query_end:2->3:shell-model:shell,skill',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('active skill can disallow tools without collapsing the full tool set',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_disallow_');

    try {
      final seenRequests = <QueryRequest>[];
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'safe_edit',
                description: 'Keep investigation broad but block writes.',
                disallowedTools: const ['write'],
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text(
                    'Inspect broadly, but do not modify files.',
                  ),
                ],
              ),
            ],
          ),
          hooks: ClartCodeAgentHooks(
            onModelTurnStart: (event) {
              lifecycle.add(
                'turn:${event.turn}:model=${event.model}:tools=${event.availableTools.join(',')}',
              );
            },
            onToolPermissionDecision: (event) {
              lifecycle.add(
                'permission:${event.context.turn}:${event.toolCall.name}:${event.decision.name}:${event.source.name}:${event.message}',
              );
            },
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              expect(request.model, 'base-model');
              expect(
                request.toolDefinitions.map((tool) => tool.name),
                containsAll(['skill', 'read', 'write']),
              );
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_disallow_1',
                    name: 'skill',
                    input: {'skill': 'safe_edit'},
                  ),
                ],
              );
            }

            if (seenRequests.length == 2) {
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_write_disallow_1',
                    name: 'write',
                    input: {
                      'path': 'blocked.txt',
                      'content': 'should not run',
                    },
                  ),
                ],
              );
            }

            return QueryResponse.success(
              output: 'final safe-edit answer',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('investigate safely with the skill');

      expect(result.isError, isFalse);
      expect(result.text, 'final safe-edit answer');
      expect(result.turns, 3);
      expect(seenRequests, hasLength(3));
      expect(seenRequests.first.model, 'base-model');
      expect(
        seenRequests.first.toolDefinitions.map((tool) => tool.name),
        containsAll(['skill', 'read', 'write']),
      );
      expect(seenRequests[1].model, 'base-model');
      expect(
        seenRequests[1].toolDefinitions.map((tool) => tool.name),
        containsAll(['skill', 'read', 'shell']),
      );
      expect(
        seenRequests[1].toolDefinitions.map((tool) => tool.name),
        isNot(contains('write')),
      );
      expect(seenRequests[2].model, 'base-model');
      expect(
        seenRequests[2].toolDefinitions.map((tool) => tool.name),
        containsAll(['skill', 'read', 'shell']),
      );
      expect(
        seenRequests[2].toolDefinitions.map((tool) => tool.name),
        isNot(contains('write')),
      );
      final deniedPayload = seenRequests[2]
          .messages
          .where((message) => message.role == MessageRole.tool)
          .map((message) => _decodeToolPayload(message.text))
          .last;
      expect(deniedPayload['tool'], 'write');
      expect(deniedPayload['ok'], isFalse);
      expect(deniedPayload['error_code'], 'permission_denied');
      expect(
        deniedPayload['error_message'],
        contains('not allowed while skill "safe_edit" is active'),
      );
      expect(
        lifecycle,
        contains(
          'turn:2:model=base-model:tools=edit,glob,grep,read,shell,skill',
        ),
      );
      expect(
        lifecycle.where((entry) => entry.contains('permission:2:write')).single,
        contains(
          ':skill:tool "write" is not allowed while skill "safe_edit" is active',
        ),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('same-turn inline skill activation constrains later tool calls',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_same_turn_');

    try {
      final seenRequests = <QueryRequest>[];
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'review_local',
                description: 'Review code in a focused scope.',
                allowedTools: const ['read'],
                model: 'skill-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text(
                    'Review carefully and only read files.',
                  ),
                ],
              ),
            ],
          ),
          hooks: ClartCodeAgentHooks(
            onToolPermissionDecision: (event) {
              lifecycle.add(
                'permission:${event.context.turn}:${event.toolCall.name}:${event.decision.name}:${event.source.name}:${event.message}',
              );
            },
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            if (seenRequests.length == 1) {
              expect(request.model, 'base-model');
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_same_turn_1',
                    name: 'skill',
                    input: {'skill': 'review_local'},
                  ),
                  QueryToolCall(
                    id: 'call_write_same_turn_1',
                    name: 'write',
                    input: {
                      'path': 'blocked.txt',
                      'content': 'should not run',
                    },
                  ),
                ],
              );
            }

            expect(request.model, 'skill-model');
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            expect(toolPayloads, hasLength(2));
            expect(toolPayloads.first['tool'], 'skill');
            expect(toolPayloads.first['ok'], isTrue);
            expect(toolPayloads.last['tool'], 'write');
            expect(toolPayloads.last['ok'], isFalse);
            expect(toolPayloads.last['error_code'], 'permission_denied');
            expect(
              toolPayloads.last['error_message'],
              contains('not allowed while skill "review_local" is active'),
            );
            return QueryResponse.success(
              output: 'same-turn constrained answer',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('review this with a same-turn skill');

      expect(result.isError, isFalse);
      expect(result.text, 'same-turn constrained answer');
      expect(result.turns, 2);
      expect(seenRequests, hasLength(2));
      expect(
        lifecycle,
        contains(
          'permission:1:write:deny:skill:tool "write" is not allowed while skill "review_local" is active',
        ),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('later same-turn skill overrides earlier inline skill state', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_multi_same_');

    try {
      final seenRequests = <QueryRequest>[];
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'read_only',
                description: 'Only read files.',
                allowedTools: const ['read'],
                model: 'read-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Read only.'),
                ],
              ),
              ClartCodeSkillDefinition(
                name: 'shell_only',
                description: 'Only use shell.',
                allowedTools: const ['shell'],
                model: 'shell-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Shell only.'),
                ],
              ),
            ],
          ),
          hooks: ClartCodeAgentHooks(
            onToolPermissionDecision: (event) {
              lifecycle.add(
                'permission:${event.context.turn}:${event.toolCall.name}:${event.decision.name}:${event.source.name}:${event.message}',
              );
            },
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            if (seenRequests.length == 1) {
              expect(request.model, 'base-model');
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_multi_1',
                    name: 'skill',
                    input: {'skill': 'read_only'},
                  ),
                  QueryToolCall(
                    id: 'call_skill_multi_2',
                    name: 'skill',
                    input: {'skill': 'shell_only'},
                  ),
                  QueryToolCall(
                    id: 'call_read_multi_1',
                    name: 'read',
                    input: {'path': 'README.md'},
                  ),
                ],
              );
            }

            expect(request.model, 'shell-model');
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            expect(toolPayloads, hasLength(3));
            expect(toolPayloads[0]['tool'], 'skill');
            expect(toolPayloads[0]['ok'], isTrue);
            expect(
              Map<String, Object?>.from(
                  toolPayloads[0]['metadata'] as Map)['skill'],
              'read_only',
            );
            expect(toolPayloads[1]['tool'], 'skill');
            expect(toolPayloads[1]['ok'], isTrue);
            expect(
              Map<String, Object?>.from(
                  toolPayloads[1]['metadata'] as Map)['skill'],
              'shell_only',
            );
            expect(toolPayloads[2]['tool'], 'read');
            expect(toolPayloads[2]['ok'], isFalse);
            expect(toolPayloads[2]['error_code'], 'permission_denied');
            expect(
              toolPayloads[2]['error_message'],
              contains('not allowed while skill "shell_only" is active'),
            );
            return QueryResponse.success(
              output: 'later skill wins',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('switch skills in the same tool batch');

      expect(result.isError, isFalse);
      expect(result.text, 'later skill wins');
      expect(result.turns, 2);
      expect(seenRequests, hasLength(2));
      expect(
        lifecycle,
        contains(
          'permission:1:read:deny:skill:tool "read" is not allowed while skill "shell_only" is active',
        ),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test(
      'forked skill runs in isolated child agent and does not constrain parent',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_fork_');

    try {
      final seenRequests = <QueryRequest>[];
      final lifecycle = <String>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'main-model',
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'fork_review',
                description: 'Run a review in a child agent.',
                context: ClartCodeSkillExecutionContext.fork,
                allowedTools: const ['read'],
                model: 'child-skill-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text(
                    'Review the target in the child agent and report back.',
                  ),
                ],
              ),
            ],
          ),
          hooks: ClartCodeAgentHooks(
            onSkillActivation: (event) {
              lifecycle.add('start:${event.name}');
            },
            onSkillEnd: (event) {
              lifecycle.add('end:${event.name}:${event.reason}');
            },
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();

            if (request.model == 'child-skill-model') {
              expect(toolPayloads, isEmpty);
              expect(
                request.toolDefinitions.map((tool) => tool.name).toList(),
                ['read'],
              );
              return QueryResponse.success(
                output: 'fork child result',
                modelUsed: request.model,
              );
            }

            if (toolPayloads.isEmpty) {
              expect(request.model, 'main-model');
              expect(
                request.toolDefinitions.map((tool) => tool.name),
                containsAll(['skill', 'read', 'write']),
              );
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_fork_1',
                    name: 'skill',
                    input: {'skill': 'fork_review'},
                  ),
                ],
              );
            }

            final skillPayload = toolPayloads.single;
            expect(request.model, 'main-model');
            expect(skillPayload['tool'], 'skill');
            expect(skillPayload['ok'], isTrue);
            expect(skillPayload['output'], contains('fork child result'));
            final metadata =
                Map<String, Object?>.from(skillPayload['metadata'] as Map);
            expect(metadata['status'], 'forked');
            expect(metadata['subagent_turns'], 1);
            expect(metadata['subagent_model'], 'child-skill-model');
            expect(metadata['subagent_session_id'], isA<String>());
            final subagentMessages =
                (metadata['subagent_messages'] as List?) ?? const [];
            expect(subagentMessages, hasLength(4));
            expect((subagentMessages.first as Map)['type'], 'subagent');
            expect((subagentMessages.first as Map)['subtype'], 'start');
            expect((subagentMessages.last as Map)['type'], 'subagent');
            expect((subagentMessages.last as Map)['subtype'], 'end');
            expect(
              (subagentMessages.last as Map)['terminalSubtype'],
              'success',
            );
            final toolNames =
                request.toolDefinitions.map((tool) => tool.name).toList();
            expect(toolNames, containsAll(['skill', 'read', 'write']));

            return QueryResponse.success(
              output: 'main final after fork skill',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('use a forked review skill');

      expect(result.isError, isFalse);
      expect(result.text, 'main final after fork skill');
      expect(result.turns, 2);
      expect(seenRequests, hasLength(3));
      expect(lifecycle, isEmpty);
      expect(seenRequests[0].model, 'main-model');
      expect(seenRequests[1].model, 'child-skill-model');
      expect(seenRequests[2].model, 'main-model');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('forked skill child error is surfaced as a successful tool result',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_fork_error_');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'main-model',
          persistSession: false,
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'fork_review',
                description: 'Run a review in a child agent.',
                context: ClartCodeSkillExecutionContext.fork,
                model: 'child-skill-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text(
                    'Review the target in the child agent and report back.',
                  ),
                ],
              ),
            ],
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();

            if (request.model == 'child-skill-model') {
              return QueryResponse.failure(
                error: RuntimeError(
                  code: RuntimeErrorCode.providerFailure,
                  message: 'child provider exploded',
                  source: 'test',
                  retriable: false,
                ),
                output: '[ERROR] child provider exploded',
                modelUsed: request.model,
              );
            }

            if (toolPayloads.isEmpty) {
              expect(request.model, 'main-model');
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_fork_error_1',
                    name: 'skill',
                    input: {'skill': 'fork_review'},
                  ),
                ],
              );
            }

            final skillPayload = toolPayloads.single;
            expect(request.model, 'main-model');
            expect(skillPayload['tool'], 'skill');
            expect(skillPayload['ok'], isTrue);
            expect(
              skillPayload['output'],
              contains('[ERROR] child provider exploded'),
            );
            final metadata =
                Map<String, Object?>.from(skillPayload['metadata'] as Map);
            expect(metadata['status'], 'forked');
            expect(metadata['subagent_is_error'], isTrue);
            expect(metadata['subagent_error_code'], 'providerFailure');
            expect(
              metadata['subagent_error_message'],
              'child provider exploded',
            );
            final subagentMessages =
                (metadata['subagent_messages'] as List?) ?? const [];
            expect(subagentMessages, isNotEmpty);
            expect((subagentMessages.last as Map)['type'], 'subagent');
            expect((subagentMessages.last as Map)['subtype'], 'end');
            expect(
              (subagentMessages.last as Map)['terminalSubtype'],
              'error_during_execution',
            );

            return QueryResponse.success(
              output: 'main recovered after fork skill error',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('use a forked review skill');

      expect(result.isError, isFalse);
      expect(result.text, 'main recovered after fork skill error');
      expect(result.turns, 2);
      expect(seenRequests, hasLength(3));
      expect(seenRequests[0].model, 'main-model');
      expect(seenRequests[1].model, 'child-skill-model');
      expect(seenRequests[2].model, 'main-model');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('forked skill can reuse a named agent definition', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_named_agent_');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'main-model',
          persistSession: false,
          agents: const ClartCodeAgentsOptions(
            agents: [
              ClartCodeAgentDefinition(
                name: 'code-reviewer',
                description: 'Review code with a tight read-only scope.',
                prompt:
                    'Review the requested code carefully and return findings first.',
                allowedTools: ['read'],
                disallowedTools: ['write'],
                model: 'review-model',
                effort: ClartCodeReasoningEffort.medium,
              ),
            ],
          ),
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'fork_review',
                description: 'Run a review in a child agent.',
                context: ClartCodeSkillExecutionContext.fork,
                agent: 'code-reviewer',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text(
                    'Inspect lib/src/sdk and report the main risks.',
                  ),
                ],
              ),
            ],
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();

            if (request.model == 'review-model') {
              expect(request.effort, ClartCodeReasoningEffort.medium);
              final userPrompt = request.messages
                  .where((message) => message.role == MessageRole.user)
                  .map((message) => message.text)
                  .join('\n');
              expect(
                request.toolDefinitions.map((tool) => tool.name).toList(),
                ['read'],
              );
              expect(
                userPrompt,
                contains(
                  'Review the requested code carefully and return findings first.',
                ),
              );
              expect(
                userPrompt,
                contains('Inspect lib/src/sdk and report the main risks.'),
              );
              return QueryResponse.success(
                output: 'review child result',
                modelUsed: request.model,
              );
            }

            if (toolPayloads.isEmpty) {
              expect(request.model, 'main-model');
              expect(request.effort, isNull);
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_named_agent_1',
                    name: 'skill',
                    input: {'skill': 'fork_review'},
                  ),
                ],
              );
            }

            final skillPayload = toolPayloads.single;
            expect(skillPayload['tool'], 'skill');
            expect(skillPayload['ok'], isTrue);
            expect(skillPayload['output'], contains('review child result'));
            final metadata =
                Map<String, Object?>.from(skillPayload['metadata'] as Map);
            expect(metadata['status'], 'forked');
            expect(metadata['agent'], 'code-reviewer');
            expect(metadata['resolved_agent'], 'code-reviewer');
            expect(metadata['subagent_model'], 'review-model');
            return QueryResponse.success(
              output: 'main final after named-agent skill',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.prompt('use the review skill');

      expect(result.isError, isFalse);
      expect(result.text, 'main final after named-agent skill');
      expect(result.turns, 2);
      expect(seenRequests, hasLength(3));
      expect(seenRequests[0].model, 'main-model');
      expect(seenRequests[1].model, 'review-model');
      expect(seenRequests[2].model, 'main-model');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('agent can run one-shot subagent with isolated options', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_subagent_');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            expect(request.model, 'child-model');
            expect(
              request.toolDefinitions.map((tool) => tool.name).toList(),
              ['read'],
            );
            return QueryResponse.success(
              output: 'subagent answer',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.runSubagent(
        'inspect the target',
        options: const ClartCodeSubagentOptions(
          model: 'child-model',
          allowedTools: ['read'],
          promptPrefix: 'You are a focused reviewer.',
        ),
      );

      expect(result.isError, isFalse);
      expect(result.parentSessionId, agent.sessionId);
      expect(result.sessionId, isNot(agent.sessionId));
      expect(
          result.prompt, 'You are a focused reviewer.\n\ninspect the target');
      expect(result.text, 'subagent answer');
      expect(result.model, 'child-model');
      expect(result.transcriptMessages, hasLength(1));
      expect(result.transcriptMessages.single.kind,
          TranscriptMessageKind.subagent);
      expect(result.transcriptMessages.single.sessionId, result.sessionId);
      expect(
        result.transcriptMessages.single.parentSessionId,
        result.parentSessionId,
      );
      expect(
        result.transcriptMessages.single.text,
        contains('Subagent completed.'),
      );
      expect(
        result.transcriptMessages.single.text,
        contains('output:\nsubagent answer'),
      );
      expect(result.cascadedMessages, hasLength(4));
      expect(result.cascadedMessages.first.type, 'subagent');
      expect(result.cascadedMessages.first.subtype, 'start');
      expect(result.cascadedMessages.first.parentSessionId, agent.sessionId);
      expect(result.cascadedMessages.first.subagentName, isNull);
      expect(result.cascadedMessages.last.type, 'subagent');
      expect(result.cascadedMessages.last.subtype, 'end');
      expect(result.cascadedMessages.last.terminalSubtype, 'success');
      expect(result.cascadedMessages.last.parentSessionId, agent.sessionId);
      expect(seenRequests, hasLength(1));
      expect(agent.getMessages(), isEmpty);
      expect(agent.getTranscript(), hasLength(1));
      expect(agent.getTranscript().single.kind, TranscriptMessageKind.subagent);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('runSubagent can optionally expose child assistant deltas', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_subagent_delta_');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          providerOverride: _NativeToolLoopProvider((request) {
            expect(request.model, 'child-model');
            return QueryResponse.success(
              output: 'subagent delta answer',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final result = await agent.runSubagent(
        'inspect the target with deltas',
        options: const ClartCodeSubagentOptions(
          model: 'child-model',
          cascadeAssistantDeltas: true,
        ),
      );

      expect(result.isError, isFalse);
      expect(result.cascadedMessages.map((message) => message.type), [
        'subagent',
        'system',
        'assistant_delta',
        'assistant',
        'subagent',
      ]);
      expect(result.cascadedMessages[2].delta, 'subagent delta answer');
      expect(result.cascadedMessages[2].parentSessionId, agent.sessionId);
      expect(result.cascadedMessages.last.subtype, 'end');
      expect(result.cascadedMessages.last.terminalSubtype, 'success');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('runSubagent emits hooks and child hook events include parent session',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_subagent_hooks_');

    try {
      final lifecycle = <String>[];
      late ClartCodeAgent agent;
      agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          providerOverride: _NativeToolLoopProvider((request) {
            expect(request.model, 'child-model');
            expect(
              request.toolDefinitions.map((tool) => tool.name).toList(),
              ['read'],
            );
            return QueryResponse.success(
              output: 'subagent hook answer',
              modelUsed: request.model,
            );
          }),
          hooks: ClartCodeAgentHooks(
            onSubagentStart: (event) {
              lifecycle.add(
                'sub_start:${event.name}:${event.parentSessionId == agent.sessionId}',
              );
            },
            onSubagentEnd: (event) {
              lifecycle.add(
                'sub_end:${event.name}:${event.result.parentSessionId == agent.sessionId}:${event.result.isError}',
              );
            },
            onSessionStart: (event) {
              lifecycle.add(
                'session_start:${event.sessionId == agent.sessionId}:${event.parentSessionId == agent.sessionId}',
              );
            },
            onSessionEnd: (event) {
              lifecycle.add(
                'session_end:${event.sessionId == agent.sessionId}:${event.parentSessionId == agent.sessionId}:${event.result.isError}',
              );
            },
          ),
        ),
      );

      final result = await agent.runSubagent(
        'inspect hook target',
        options: const ClartCodeSubagentOptions(
          name: 'reviewer',
          model: 'child-model',
          allowedTools: ['read'],
          inheritHooks: true,
        ),
      );

      expect(result.isError, isFalse);
      expect(result.name, 'reviewer');
      expect(result.parentSessionId, agent.sessionId);
      expect(lifecycle, [
        'sub_start:reviewer:true',
        'session_start:false:true',
        'session_end:false:true:false',
        'sub_end:reviewer:true:false',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('parent stop cascades cancellation to active child agent', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_subagent_cancel_');

    try {
      final lifecycle = <String>[];
      final provider = _SubagentCancellationProvider();
      late ClartCodeAgent agent;
      agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          persistSession: false,
          agents: const ClartCodeAgentsOptions(
            agents: [
              ClartCodeAgentDefinition(
                name: 'code-reviewer',
                description: 'Review code in a child agent.',
                prompt: 'Review the delegated target.',
                allowedTools: ['read'],
                model: 'child-model',
              ),
            ],
          ),
          providerOverride: provider,
          hooks: ClartCodeAgentHooks(
            onSubagentStart: (event) {
              lifecycle.add('sub_start:${event.name}');
            },
            onSubagentEnd: (event) {
              lifecycle.add(
                'sub_end:${event.name}:${event.result.isError}:${event.reason}',
              );
            },
            onCancelledTerminal: (event) {
              lifecycle.add('cancelled:${event.reason}');
            },
          ),
        ),
      );

      final pending = agent.prompt('delegate and then stop');
      await provider.childStarted.future;
      await agent.stop(reason: 'parent_stop_subagent');
      final result = await pending;

      expect(provider.cancelCalled, isTrue);
      expect(result.isError, isTrue);
      expect(result.error?.code, RuntimeErrorCode.cancelled);
      expect(lifecycle, [
        'sub_start:code-reviewer',
        'sub_end:code-reviewer:true:parent_stop_subagent',
        'cancelled:parent_stop_subagent',
      ]);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('agent loads named agents and executes agent tool via child agent',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_named_agent_');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          agents: const ClartCodeAgentsOptions(
            agents: [
              ClartCodeAgentDefinition(
                name: 'code-reviewer',
                description: 'Review code with a tight read-only scope.',
                prompt:
                    'Review the requested code carefully and return findings first.',
                allowedTools: ['read'],
                model: 'review-model',
              ),
            ],
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();

            if (request.model == 'review-model') {
              final systemPrompt = request.messages
                  .where((message) => message.role == MessageRole.system)
                  .map((message) => message.text)
                  .join('\n');
              final userPrompt = request.messages
                  .where((message) => message.role == MessageRole.user)
                  .map((message) => message.text)
                  .join('\n');
              expect(systemPrompt, isNot(contains('Available agents:')));
              expect(
                request.toolDefinitions.map((tool) => tool.name).toList(),
                ['read'],
              );
              expect(
                userPrompt,
                contains(
                    'Review the requested code carefully and return findings first.'),
              );
              expect(userPrompt, contains('inspect lib/src/sdk'));
              return QueryResponse.success(
                output: 'review child result',
                modelUsed: request.model,
              );
            }

            if (toolPayloads.isEmpty) {
              final systemPrompt = request.messages
                  .where((message) => message.role == MessageRole.system)
                  .map((message) => message.text)
                  .join('\n');
              expect(systemPrompt, contains('Available agents:'));
              expect(systemPrompt, contains('code-reviewer'));
              expect(systemPrompt, contains('tight read-only scope'));
              expect(
                request.toolDefinitions.map((tool) => tool.name),
                containsAll(['agent', 'read', 'write']),
              );
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_agent_1',
                    name: 'agent',
                    input: {
                      'agent': 'code-reviewer',
                      'prompt': 'inspect lib/src/sdk',
                    },
                  ),
                ],
              );
            }

            final agentPayload = toolPayloads.single;
            expect(request.model, 'parent-model');
            expect(agentPayload['tool'], 'agent');
            expect(agentPayload['ok'], isTrue);
            expect(agentPayload['output'], contains('review child result'));
            final metadata =
                Map<String, Object?>.from(agentPayload['metadata'] as Map);
            expect(metadata['agent'], 'code-reviewer');
            expect(metadata['allowed_tools'], ['read']);
            expect(metadata['subagent_turns'], 1);
            expect(metadata['subagent_model'], 'review-model');
            expect(metadata['subagent_session_id'], isA<String>());
            final subagentMessages =
                (metadata['subagent_messages'] as List?) ?? const [];
            expect(subagentMessages, hasLength(4));
            expect((subagentMessages.first as Map)['type'], 'subagent');
            expect((subagentMessages.first as Map)['subtype'], 'start');
            expect((subagentMessages.last as Map)['type'], 'subagent');
            expect((subagentMessages.last as Map)['subtype'], 'end');
            expect(
              (subagentMessages.last as Map)['terminalSubtype'],
              'success',
            );
            final toolNames =
                request.toolDefinitions.map((tool) => tool.name).toList();
            expect(toolNames, containsAll(['agent', 'read', 'write']));

            return QueryResponse.success(
              output: 'main final after agent tool',
              modelUsed: request.model,
            );
          }),
        ),
      );

      await agent.prepare();
      expect(agent.availableAgents, ['code-reviewer']);
      expect(agent.availableTools, contains('agent'));

      final result = await agent.prompt('delegate a focused code review');

      expect(result.isError, isFalse);
      expect(result.text, 'main final after agent tool');
      expect(result.turns, 2);
      expect(seenRequests, hasLength(3));
      expect(seenRequests[0].model, 'parent-model');
      expect(seenRequests[1].model, 'review-model');
      expect(seenRequests[2].model, 'parent-model');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('query live-merges child events before parent tool result', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_live_subagent_');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          agents: const ClartCodeAgentsOptions(
            agents: [
              ClartCodeAgentDefinition(
                name: 'code-reviewer',
                description: 'Review code with a tight read-only scope.',
                prompt: 'Review the delegated target carefully.',
                allowedTools: ['read'],
                model: 'child-model',
                cascadeAssistantDeltas: true,
              ),
            ],
          ),
          providerOverride: _StreamingNativeToolLoopProvider((request) async* {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();

            if (request.model == 'parent-model' && toolPayloads.isEmpty) {
              yield ProviderStreamEvent.done(
                output: '',
                model: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_agent_stream_1',
                    name: 'agent',
                    input: {
                      'agent': 'code-reviewer',
                      'prompt': 'inspect lib/src/sdk',
                    },
                  ),
                ],
              );
              return;
            }

            if (request.model == 'child-model') {
              yield ProviderStreamEvent.textDelta(
                delta: 'child delta that should stay private',
                model: request.model,
              );
              yield ProviderStreamEvent.done(
                output: 'child merged answer',
                model: request.model,
              );
              return;
            }

            expect(request.model, 'parent-model');
            expect(toolPayloads, hasLength(1));
            expect(toolPayloads.single['tool'], 'agent');
            yield ProviderStreamEvent.done(
              output: 'main final after child merge',
              model: request.model,
            );
          }),
        ),
      );

      final messages =
          await agent.query('delegate a focused code review').toList();
      expect(messages.map((message) => message.type), [
        'system',
        'tool_call',
        'subagent',
        'system',
        'assistant_delta',
        'assistant',
        'subagent',
        'tool_result',
        'assistant',
        'result',
      ]);

      final childMessages = messages
          .where((message) => message.parentSessionId == agent.sessionId)
          .toList();
      expect(childMessages.map((message) => message.type), [
        'subagent',
        'system',
        'assistant_delta',
        'assistant',
        'subagent',
      ]);
      expect(childMessages.first.subtype, 'start');
      expect(childMessages.first.subagentName, 'code-reviewer');
      expect(childMessages[1].subtype, 'init');
      expect(
        childMessages[2].delta,
        'child delta that should stay private',
      );
      expect(childMessages[3].text, 'child merged answer');
      expect(childMessages[4].subtype, 'end');
      expect(childMessages[4].terminalSubtype, 'success');

      final childResultIndex = messages.indexOf(childMessages.last);
      final parentToolResultIndex =
          messages.indexWhere((message) => message.type == 'tool_result');
      expect(childResultIndex, lessThan(parentToolResultIndex));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('agent loads named agents from directories', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_agent_dir_');
    final agentsDir = Directory('${tempDir.path}/agents');
    await agentsDir.create(recursive: true);
    await File('${agentsDir.path}/code-reviewer.md').writeAsString('''
---
name: code-reviewer
description: Review SDK code from a local agents directory.
tools: [read]
model: review-model
---
# Code Reviewer

Review the requested SDK scope and return findings first.
''');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          agents: ClartCodeAgentsOptions(
            directories: [agentsDir.path],
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();

            if (request.model == 'review-model') {
              final userPrompt = request.messages
                  .where((message) => message.role == MessageRole.user)
                  .map((message) => message.text)
                  .join('\n');
              expect(
                request.toolDefinitions.map((tool) => tool.name).toList(),
                ['read'],
              );
              expect(userPrompt, contains('Base directory for this agent'));
              expect(userPrompt, contains('Review the requested SDK scope'));
              return QueryResponse.success(
                output: 'directory agent result',
                modelUsed: request.model,
              );
            }

            if (toolPayloads.isEmpty) {
              expect(
                request.toolDefinitions.map((tool) => tool.name),
                containsAll(['agent', 'read', 'write']),
              );
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_agent_dir_1',
                    name: 'agent',
                    input: {
                      'agent': 'code-reviewer',
                      'prompt': 'inspect lib/src/sdk',
                    },
                  ),
                ],
              );
            }

            final agentPayload = toolPayloads.single;
            expect(agentPayload['tool'], 'agent');
            expect(agentPayload['ok'], isTrue);
            expect(agentPayload['output'], contains('directory agent result'));
            return QueryResponse.success(
              output: 'final after directory agent',
              modelUsed: request.model,
            );
          }),
        ),
      );

      await agent.prepare();
      expect(agent.availableAgents, ['code-reviewer']);
      expect(agent.availableTools, contains('agent'));

      final result = await agent.prompt('delegate from local agent dir');

      expect(result.isError, isFalse);
      expect(result.text, 'final after directory agent');
      expect(seenRequests, hasLength(3));
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

  test('prompt injects in-process SDK MCP tools into agent runtime', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_mcp_sdk_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          mcp: ClartCodeMcpOptions(
            sdkServers: [
              createSdkMcpServer(
                name: 'local',
                version: '1.2.3',
                tools: [_SdkEchoTool()],
              ),
            ],
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
                      'id': 'call_mcp_sdk_1',
                      'name': 'local/echo_local',
                      'input': {'message': 'hello sdk mcp'},
                    },
                  ],
                }),
                modelUsed: 'mcp-sdk-mock',
              );
            }

            return QueryResponse.success(
              output: 'mcp sdk final: ${toolPayloads.single['output']}',
              modelUsed: 'mcp-sdk-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('use local sdk mcp tool');

      expect(result.isError, isFalse);
      expect(result.text, 'mcp sdk final: sdk:hello sdk mcp');
      expect(agent.mcpConnections, hasLength(1));
      expect(agent.mcpConnections.single.name, 'local');
      expect(
        agent.mcpConnections.single.config.transportType,
        McpTransportType.sdk,
      );
      expect(agent.mcpConnections.single.serverInfo?.version, '1.2.3');
      expect(agent.availableTools, contains('local/echo_local'));
      expect(agent.availableTools, isNot(contains('mcp_list_resources')));

      final toolResultMessage = agent.getTranscript().lastWhere(
          (message) => message.kind == TranscriptMessageKind.toolResult);
      final toolPayload = _decodeToolPayload(toolResultMessage.text);
      final metadata =
          Map<String, Object?>.from(toolPayload['metadata'] as Map);
      expect(metadata['origin'], 'sdk');
      expect(metadata['serverName'], 'local');
      expect(metadata['toolName'], 'echo_local');
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

  test('agent registers custom tools built with tool helper DSL', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_custom_tool_dsl_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          tools: [
            tool(
              name: 'echo_tool_dsl',
              title: 'Echo Tool DSL',
              description: 'Uppercases text through helper DSL.',
              inputSchema: const {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'},
                },
                'required': ['text'],
              },
              annotations: const {
                'origin': 'dsl',
              },
              executionHint: ToolExecutionHint.parallelSafe,
              run: (invocation) => ToolExecutionResult.success(
                tool: 'echo_tool_dsl',
                output:
                    (invocation.input['text'] as String? ?? '').toUpperCase(),
              ),
            ),
          ],
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
                      'id': 'call_custom_dsl_1',
                      'name': 'echo_tool_dsl',
                      'input': {'text': 'hello dsl'},
                    },
                  ],
                }),
                modelUsed: 'tool-mock',
              );
            }

            return QueryResponse.success(
              output: 'dsl=${toolPayloads.single['output']}',
              modelUsed: 'tool-mock',
            );
          }),
        ),
      );

      final result = await agent.prompt('use tool helper');

      expect(result.isError, false);
      expect(result.text, 'dsl=HELLO DSL');
      final definition = agent.toolDefinitions.firstWhere(
        (tool) => tool.name == 'echo_tool_dsl',
      );
      expect(definition.title, 'Echo Tool DSL');
      expect(definition.annotations, {'origin': 'dsl'});
      expect(definition.executionHint, ToolExecutionHint.parallelSafe.name);
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

  test('query stream surfaces active inline skill cancellation before result',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_stream_cancel_');

    try {
      final provider = _SkillCancelableProvider();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          persistSession: false,
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'read_only',
                description: 'Only read files.',
                allowedTools: const ['read'],
                model: 'skill-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Read only.'),
                ],
              ),
            ],
          ),
          providerOverride: provider,
        ),
      );

      final pending = agent.query('cancel with active skill').toList();
      await provider.secondTurnStarted.future;
      await agent.stop(reason: 'skill_cancel');
      final messages = await pending;

      expect(provider.cancelCalled, isTrue);
      expect(messages.map((message) => message.type), [
        'system',
        'tool_call',
        'tool_result',
        'skill',
        'result',
      ]);
      final skillMessage =
          messages.firstWhere((message) => message.type == 'skill');
      expect(skillMessage.subtype, 'end');
      expect(skillMessage.terminalSubtype, 'cancelled');
      expect(skillMessage.skillName, 'read_only');
      expect(skillMessage.turn, 2);
      expect(skillMessage.isError, isTrue);
      expect(skillMessage.text, contains('STOPPED'));
      expect(skillMessage.error?.code, RuntimeErrorCode.cancelled);
      expect(messages.last.type, 'result');
      expect(messages.last.subtype, 'error_stopped');
      expect(
        messages.indexOf(skillMessage),
        lessThan(messages.indexOf(messages.last)),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('query stream surfaces active inline skill error before result',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_stream_error_');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          persistSession: false,
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'read_only',
                description: 'Only read files.',
                allowedTools: const ['read'],
                model: 'skill-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Read only.'),
                ],
              ),
            ],
          ),
          providerOverride: _SkillErrorProvider(),
        ),
      );

      final messages = await agent.query('error with active skill').toList();

      expect(messages.map((message) => message.type), [
        'system',
        'tool_call',
        'tool_result',
        'skill',
        'result',
      ]);
      final skillMessage =
          messages.firstWhere((message) => message.type == 'skill');
      expect(skillMessage.subtype, 'end');
      expect(skillMessage.terminalSubtype, 'error');
      expect(skillMessage.skillName, 'read_only');
      expect(skillMessage.turn, 2);
      expect(skillMessage.isError, isTrue);
      expect(skillMessage.text, contains('provider exploded'));
      expect(skillMessage.error?.code, RuntimeErrorCode.providerFailure);
      expect(messages.last.type, 'result');
      expect(messages.last.subtype, 'error_during_execution');
      expect(
        messages.indexOf(skillMessage),
        lessThan(messages.indexOf(messages.last)),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test(
      'query stream keeps inline skill replacement and query-end cleanup on hooks only',
      () async {
    final tempDir =
        await Directory.systemTemp.createTemp('clart_sdk_skill_stream_scope_');

    try {
      final seenRequests = <QueryRequest>[];
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'base-model',
          persistSession: false,
          skills: ClartCodeSkillsOptions(
            includeBundledSkills: false,
            skills: [
              ClartCodeSkillDefinition(
                name: 'read_only',
                description: 'Only read files.',
                allowedTools: const ['read'],
                model: 'read-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Read only.'),
                ],
              ),
              ClartCodeSkillDefinition(
                name: 'shell_only',
                description: 'Only use shell.',
                allowedTools: const ['shell'],
                model: 'shell-model',
                getPrompt: (args, context) async => const [
                  ClartCodeSkillContentBlock.text('Shell only.'),
                ],
              ),
            ],
          ),
          providerOverride: _NativeToolLoopProvider((request) {
            seenRequests.add(request);
            if (seenRequests.length == 1) {
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_stream_1',
                    name: 'skill',
                    input: {'skill': 'read_only'},
                  ),
                ],
              );
            }

            if (seenRequests.length == 2) {
              return QueryResponse.success(
                output: '',
                modelUsed: request.model,
                toolCalls: const [
                  QueryToolCall(
                    id: 'call_skill_stream_2',
                    name: 'skill',
                    input: {'skill': 'shell_only'},
                  ),
                ],
              );
            }

            return QueryResponse.success(
              output: 'skill stream remains quiet',
              modelUsed: request.model,
            );
          }),
        ),
      );

      final messages =
          await agent.query('keep normal skill lifecycle off stream').toList();

      expect(seenRequests, hasLength(3));
      expect(messages.map((message) => message.type), [
        'system',
        'tool_call',
        'tool_result',
        'tool_call',
        'tool_result',
        'assistant_delta',
        'assistant',
        'result',
      ]);
      expect(
        messages.where((message) => message.type == 'skill'),
        isEmpty,
      );
      expect(messages.last.subtype, 'success');
      expect(messages.last.text, 'skill stream remains quiet');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('per-call request surface reaches provider and can suppress deltas',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_request_surface_',
    );

    try {
      final provider = _RequestSurfaceCapturingProvider();
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: provider,
          persistSession: false,
          systemPrompt: 'agent system',
          appendSystemPrompt: 'agent append',
          maxTokens: 64,
          includePartialMessages: true,
        ),
      );

      final messages = await agent
          .query(
            'return structured output',
            effort: ClartCodeReasoningEffort.high,
            request: const ClartCodeRequestOptions(
              systemPrompt: 'per-call system',
              appendSystemPrompt: 'per-call append',
              maxTokens: 128,
              maxBudgetUsd: 1.5,
              thinking: ClartCodeThinkingConfig.enabled(budgetTokens: 32),
              jsonSchema: ClartCodeJsonSchema(
                name: 'reply_schema',
                schema: {
                  'type': 'object',
                  'properties': {
                    'answer': {'type': 'string'},
                  },
                  'required': ['answer'],
                },
              ),
              outputFormat: ClartCodeOutputFormat.jsonObject(),
              includePartialMessages: false,
              includeObservabilityMessages: true,
            ),
          )
          .toList();

      expect(
        messages.where((message) => message.type == 'assistant_delta'),
        isEmpty,
      );

      final request = provider.lastRequest;
      expect(request, isNotNull);
      expect(request!.effort, ClartCodeReasoningEffort.high);
      expect(request.systemPrompt, 'per-call system');
      expect(request.appendSystemPrompt, 'per-call append');
      expect(request.maxTokens, 128);
      expect(request.maxBudgetUsd, 1.5);
      expect(request.thinking?.isEnabled, isTrue);
      expect(request.thinking?.budgetTokens, 32);
      expect(request.jsonSchema?.name, 'reply_schema');
      expect(request.outputFormat?.type, ClartCodeOutputFormatType.jsonObject);
      expect(request.includePartialMessages, isFalse);
      expect(request.includeObservabilityMessages, isTrue);
      expect(messages.last.text, '{"answer":"captured"}');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('maxBudgetUsd stops query once cumulative cost exceeds budget',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_budget_enforcement_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _BudgetSurfaceProvider(),
          persistSession: false,
        ),
      );

      final result = await agent.prompt(
        'stay within budget',
        request: const ClartCodeRequestOptions(maxBudgetUsd: 0.20),
      );

      expect(result.isError, isTrue);
      expect(result.error?.code, RuntimeErrorCode.budgetExceeded);
      expect(result.messages.last.subtype, 'error_budget_exceeded');
      expect(result.costUsd, 0.30);
      expect(result.modelUsage, hasLength(1));
      expect(result.modelUsage!.single.costUsd, 0.30);
      expect(result.text, contains('maxBudgetUsd'));
      expect(result.text, contains('Last model output'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('query can opt into observability messages', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_observability_surface_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _ObservabilitySurfaceProvider(),
          persistSession: false,
        ),
      );

      final messages = await agent
          .query(
            'show observability',
            request: const ClartCodeRequestOptions(
              includeObservabilityMessages: true,
            ),
          )
          .toList();

      expect(messages.map((message) => message.type), [
        'system',
        'system',
        'rate_limit_event',
        'stream_event',
        'assistant_delta',
        'assistant',
        'result',
      ]);
      expect(messages[1].subtype, 'status');
      expect(messages[1].status, 'running_model');
      expect(messages[2].rateLimitInfo?.provider, 'test');
      expect(messages[2].rateLimitInfo?.status, 'ok');
      expect(messages[3].event?['type'], 'response.output_text.delta');
      expect(messages[3].event?['delta'], 'obs');
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test(
      'native tool continuation emits status and compact boundary observability messages',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_compact_boundary_',
    );
    final file = File('${tempDir.path}/native_observability.txt');
    await file.writeAsString('native observability body');

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _NativeToolLoopProvider((request) {
            final toolPayloads = request.messages
                .where((message) => message.role == MessageRole.tool)
                .map((message) => _decodeToolPayload(message.text))
                .toList();
            if (toolPayloads.isEmpty) {
              return QueryResponse.success(
                output: '',
                modelUsed: 'native-observability-model',
                providerStateToken: 'resp_compact_1',
                toolCalls: [
                  QueryToolCall(
                    id: 'call_read_compact_1',
                    name: 'read',
                    input: {'path': file.path},
                  ),
                ],
              );
            }

            return QueryResponse.success(
              output: 'native observability final',
              modelUsed: 'native-observability-model',
              providerStateToken: 'resp_compact_2',
            );
          }),
          persistSession: false,
        ),
      );

      final messages = await agent
          .query(
            'show compact boundary',
            request: const ClartCodeRequestOptions(
              includeObservabilityMessages: true,
            ),
          )
          .toList();

      expect(messages.map((message) => message.type), [
        'system',
        'system',
        'system',
        'system',
        'tool_call',
        'system',
        'tool_result',
        'system',
        'assistant_delta',
        'assistant',
        'result',
      ]);
      expect(messages[1].subtype, 'status');
      expect(messages[1].status, 'running_model');
      expect(messages[1].turn, 1);
      expect(messages[2].subtype, 'status');
      expect(messages[2].status, 'compacting');
      expect(messages[3].subtype, 'compact_boundary');
      expect(messages[3].compactMetadata?['reason'], 'provider_state_token');
      expect(messages[3].compactMetadata?['next_turn'], 2);
      expect(messages[3].compactMetadata?['tool_call_count'], 1);
      expect(messages[3].compactMetadata?['provider_state_token'],
          'resp_compact_1');
      expect(messages[5].subtype, 'status');
      expect(messages[5].status, 'running_tools');
      expect(messages[7].subtype, 'status');
      expect(messages[7].status, 'running_model');
      expect(messages[7].turn, 2);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('prompt result exposes usage cost and model usage observability',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_usage_surface_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          providerOverride: _UsageSurfaceProvider(),
          persistSession: false,
        ),
      );

      final result = await agent.prompt('measure usage');

      expect(result.isError, isFalse);
      expect(result.usage?.inputTokens, 7);
      expect(result.usage?.outputTokens, 5);
      expect(result.usage?.totalTokens, 12);
      expect(result.costUsd, 0.25);
      expect(result.modelUsage, hasLength(1));
      expect(result.modelUsage!.single.model, 'usage-surface-model');
      expect(result.modelUsage!.single.usage?.totalTokens, 12);
      expect(result.modelUsage!.single.costUsd, 0.25);
      expect(result.messages.last.usage?.totalTokens, 12);
      expect(result.messages.last.costUsd, 0.25);
      expect(result.messages.last.modelUsage, hasLength(1));
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

class _StreamingNativeToolLoopProvider extends NativeToolCallingLlmProvider {
  _StreamingNativeToolLoopProvider(this._handler);

  final Stream<ProviderStreamEvent> Function(QueryRequest request) _handler;

  @override
  Future<QueryResponse> run(QueryRequest request) {
    throw UnimplementedError();
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) => _handler(request);
}

class _SubagentCancellationProvider extends LlmProvider {
  final Completer<void> childStarted = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();
  bool cancelCalled = false;

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

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    if (request.model == 'parent-model') {
      yield ProviderStreamEvent.done(
        output: jsonEncode({
          'tool_calls': [
            {
              'id': 'call_agent_cancel_1',
              'name': 'agent',
              'input': {
                'agent': 'code-reviewer',
                'prompt': 'inspect cancellation target',
              },
            },
          ],
        }),
        model: request.model,
      );
      return;
    }

    if (request.model == 'child-model') {
      if (!childStarted.isCompleted) {
        childStarted.complete();
      }
      await _cancelled.future;
      return;
    }

    throw StateError('unexpected model: ${request.model}');
  }
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

class _SdkEchoTool implements Tool {
  @override
  String get name => 'echo_local';

  @override
  String? get title => null;

  @override
  String get description => 'Echo through in-process SDK MCP.';

  @override
  Map<String, Object?>? get inputSchema => null;

  @override
  Map<String, Object?>? get annotations => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    return ToolExecutionResult.success(
      tool: name,
      output: 'sdk:${invocation.input['message']}',
    ).copyWith(
      metadata: const {'origin': 'sdk'},
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

class _SkillCancelableProvider extends LlmProvider {
  final Completer<void> secondTurnStarted = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();
  int _requestCount = 0;
  bool cancelCalled = false;

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

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    _requestCount += 1;
    if (_requestCount == 1) {
      yield ProviderStreamEvent.done(
        output: '',
        model: request.model,
        toolCalls: const [
          QueryToolCall(
            id: 'call_skill_stream_cancel_1',
            name: 'skill',
            input: {'skill': 'read_only'},
          ),
        ],
      );
      return;
    }

    if (!secondTurnStarted.isCompleted) {
      secondTurnStarted.complete();
    }
    await _cancelled.future;
    throw StateError('cancelled');
  }
}

class _SkillErrorProvider extends LlmProvider {
  int _requestCount = 0;

  @override
  Future<QueryResponse> run(QueryRequest request) {
    throw UnimplementedError();
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    _requestCount += 1;
    if (_requestCount == 1) {
      yield ProviderStreamEvent.done(
        output: '',
        model: request.model,
        toolCalls: const [
          QueryToolCall(
            id: 'call_skill_stream_error_1',
            name: 'skill',
            input: {'skill': 'read_only'},
          ),
        ],
      );
      return;
    }

    yield ProviderStreamEvent.error(
      error: RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message: 'provider exploded',
        source: 'test_provider',
        retriable: false,
      ),
      output: '[ERROR] provider exploded',
      model: request.model,
    );
  }
}

class _RequestSurfaceCapturingProvider extends NativeToolCallingLlmProvider {
  QueryRequest? lastRequest;

  @override
  Future<QueryResponse> run(QueryRequest request) async {
    lastRequest = request;
    return QueryResponse.success(
      output: '{"answer":"captured"}',
      modelUsed: request.model ?? 'request-surface-model',
    );
  }
}

class _BudgetSurfaceProvider extends NativeToolCallingLlmProvider {
  int _turn = 0;

  @override
  Future<QueryResponse> run(QueryRequest request) async {
    _turn += 1;
    if (_turn == 1) {
      return QueryResponse.success(
        output: '',
        modelUsed: 'budget-model',
        toolCalls: const [
          QueryToolCall(
            id: 'call_budget_1',
            name: 'read',
            input: {'path': 'README.md'},
          ),
        ],
        costUsd: 0.30,
      );
    }

    return QueryResponse.success(
      output: 'should not reach second turn',
      modelUsed: 'budget-model',
      costUsd: 0.01,
    );
  }
}

class _ObservabilitySurfaceProvider extends LlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) {
    throw UnimplementedError();
  }

  @override
  Stream<ProviderStreamEvent> stream(QueryRequest request) async* {
    if (request.includeObservabilityMessages) {
      yield ProviderStreamEvent.rateLimit(
        rateLimitInfo: const QueryRateLimitInfo(
          provider: 'test',
          status: 'ok',
          requestsRemaining: '9',
        ),
        model: 'observability-model',
      );
      yield ProviderStreamEvent.streamEvent(
        event: const {
          'type': 'response.output_text.delta',
          'delta': 'obs',
        },
        model: 'observability-model',
      );
    }
    yield ProviderStreamEvent.textDelta(
      delta: 'visible',
      model: 'observability-model',
    );
    yield ProviderStreamEvent.done(
      output: 'visible',
      model: 'observability-model',
    );
  }
}

class _UsageSurfaceProvider extends NativeToolCallingLlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    return QueryResponse.success(
      output: 'usage aware',
      modelUsed: 'usage-surface-model',
      usage: const QueryUsage(
        inputTokens: 7,
        outputTokens: 5,
        totalTokens: 12,
      ),
      costUsd: 0.25,
    );
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
