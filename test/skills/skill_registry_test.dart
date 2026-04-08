import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('skill registry', () {
    test('looks up skills by name and alias and filters user invocable', () {
      final registry = ClartCodeSkillRegistry(
        skills: [
          ClartCodeSkillDefinition(
            name: 'review',
            description: 'Review code.',
            aliases: const ['scan'],
            getPrompt: (args, context) async =>
                const [ClartCodeSkillContentBlock.text('review prompt')],
          ),
          ClartCodeSkillDefinition(
            name: 'hidden',
            description: 'Hidden skill.',
            userInvocable: false,
            getPrompt: (args, context) async =>
                const [ClartCodeSkillContentBlock.text('hidden prompt')],
          ),
          ClartCodeSkillDefinition(
            name: 'slash_only',
            description: 'Visible to users but not models.',
            disableModelInvocation: true,
            getPrompt: (args, context) async =>
                const [ClartCodeSkillContentBlock.text('slash prompt')],
          ),
        ],
      );

      expect(registry.lookup('review')?.name, 'review');
      expect(registry.lookup('scan')?.name, 'review');
      expect(registry.lookup('/review')?.name, 'review');
      expect(
        registry.userInvocable.map((skill) => skill.name),
        ['review', 'slash_only'],
      );
      expect(registry.modelInvocable.map((skill) => skill.name), ['review']);
    });
  });

  group('loadSkillsDir', () {
    test('loads SKILL.md with frontmatter and base directory prompt', () async {
      final tempDir = await Directory.systemTemp.createTemp('clart_skill_dir_');
      final skillDir = Directory('${tempDir.path}/review_local');
      await skillDir.create(recursive: true);
      final skillFile = File('${skillDir.path}/SKILL.md');
      await skillFile.writeAsString('''
---
name: review_local
description: Review code in a local directory.
aliases: [scan, audit]
when_to_use: Use when the user asks for a code review.
argument_hint: [scope]
allowed_tools: [read, grep]
disallowed_tools: [write]
agent: code-reviewer
model: local-skill
effort: high
disable-model-invocation: true
context: fork
cascade_assistant_deltas: true
user_invocable: true
---
# Review Local

Inspect the requested code and return findings first.
''');

      try {
        final skills = await loadSkillsDir(tempDir.path);

        expect(skills, hasLength(1));
        final skill = skills.single;
        expect(skill.name, 'review_local');
        expect(skill.description, 'Review code in a local directory.');
        expect(skill.aliases, ['audit', 'scan']);
        expect(skill.whenToUse, 'Use when the user asks for a code review.');
        expect(skill.argumentHint, '[scope]');
        expect(skill.allowedTools, ['grep', 'read']);
        expect(skill.disallowedTools, ['write']);
        expect(skill.agent, 'code-reviewer');
        expect(skill.model, 'local-skill');
        expect(skill.effort, ClartCodeReasoningEffort.high);
        expect(skill.disableModelInvocation, isTrue);
        expect(skill.context, ClartCodeSkillExecutionContext.fork);
        expect(skill.cascadeAssistantDeltas, isTrue);
        expect(skill.runtimeScope, 'forked_subagent');
        expect(skill.cleanupBoundary, 'subagent_end');

        final prompt = await skill.getPrompt(
          'lib/src',
          ClartCodeSkillContext(cwd: tempDir.path),
        );
        expect(prompt.single.text, contains('Base directory for this skill'));
        expect(prompt.single.text, contains('Arguments: lib/src'));
        expect(
          prompt.single.text,
          contains('Inspect the requested code and return findings first.'),
        );
        final summary = skill.toSummaryJson();
        expect(summary['agent'], 'code-reviewer');
        expect(summary['effort'], 'high');
        expect(summary['disableModelInvocation'], isTrue);
        expect(summary['runtimeScope'], 'forked_subagent');
        expect(summary['cleanupBoundary'], 'subagent_end');
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
