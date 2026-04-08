import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('agent registry', () {
    test('looks up named agents by name', () {
      final registry = ClartCodeAgentRegistry(
        agents: const [
          ClartCodeAgentDefinition(
            name: 'code-reviewer',
            description: 'Review code.',
            prompt: 'Review the requested code carefully.',
          ),
        ],
      );

      expect(registry.lookup('code-reviewer')?.name, 'code-reviewer');
      expect(registry.has('code-reviewer'), isTrue);
      expect(registry.has('missing'), isFalse);
    });
  });

  group('loadAgentsDir', () {
    test('loads markdown agents with frontmatter and base directory prompt',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('clart_agent_dir_');
      final agentsDir = Directory('${tempDir.path}/reviewers');
      await agentsDir.create(recursive: true);
      final agentFile = File('${agentsDir.path}/code-reviewer.md');
      await agentFile.writeAsString('''
---
name: code-reviewer
description: Focused code reviewer for SDK changes.
tools: [read, grep]
disallowed_tools: [write]
model: review-model
effort: medium
inherit_mcp: false
cascade_assistant_deltas: true
---
# Code Reviewer

Inspect the requested code and return findings first.
''');

      try {
        final agents = await loadAgentsDir(tempDir.path);

        expect(agents, hasLength(1));
        final agent = agents.single;
        expect(agent.name, 'code-reviewer');
        expect(agent.description, 'Focused code reviewer for SDK changes.');
        expect(agent.allowedTools, ['grep', 'read']);
        expect(agent.disallowedTools, ['write']);
        expect(agent.model, 'review-model');
        expect(agent.effort, ClartCodeReasoningEffort.medium);
        expect(agent.inheritMcp, isFalse);
        expect(agent.cascadeAssistantDeltas, isTrue);
        expect(agent.prompt, contains('Base directory for this agent'));
        expect(
          agent.prompt,
          contains('Inspect the requested code and return findings first.'),
        );
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
