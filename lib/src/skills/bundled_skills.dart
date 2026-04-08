import 'skill_models.dart';
import 'skill_registry.dart';

void initBundledSkills(ClartCodeSkillRegistry registry) {
  _registerIfMissing(
    registry,
    ClartCodeSkillDefinition(
      name: 'review',
      description:
          'Review code for bugs, regressions, and missing tests. Return findings before summary.',
      whenToUse:
          'Use when the user asks for a review, code review, or risk assessment.',
      argumentHint: '[scope or files]',
      getPrompt: (args, context) async {
        final scope = args.trim();
        final buffer = StringBuffer()
          ..writeln(
            'Review the relevant code with a bug-finding mindset. Focus on correctness risks, behavioural regressions, and missing tests.',
          )
          ..writeln(
            'Report findings first, ordered by severity, with concrete file references when possible.',
          )
          ..writeln(
            'Keep the summary brief and only after the findings list.',
          );
        if (scope.isNotEmpty) {
          buffer
            ..writeln()
            ..writeln('Requested scope: $scope');
        }
        return [ClartCodeSkillContentBlock.text(buffer.toString().trimRight())];
      },
    ),
  );
  _registerIfMissing(
    registry,
    ClartCodeSkillDefinition(
      name: 'debug',
      description:
          'Debug a failing behaviour by reproducing it, narrowing causes, fixing the issue, and verifying the result.',
      whenToUse:
          'Use when the user reports a bug, failure, crash, or unexpected behaviour.',
      argumentHint: '[symptoms]',
      getPrompt: (args, context) async {
        final symptoms = args.trim();
        final buffer = StringBuffer()
          ..writeln(
            'Debug the issue methodically: reproduce the behaviour, form concrete hypotheses, inspect the smallest relevant surface, implement the minimal fix, and verify it.',
          )
          ..writeln(
            'Prefer evidence from tests, logs, and code paths over speculation.',
          );
        if (symptoms.isNotEmpty) {
          buffer
            ..writeln()
            ..writeln('Reported symptoms: $symptoms');
        }
        return [ClartCodeSkillContentBlock.text(buffer.toString().trimRight())];
      },
    ),
  );
  _registerIfMissing(
    registry,
    ClartCodeSkillDefinition(
      name: 'simplify',
      description:
          'Simplify code or design while preserving behaviour and keeping the implementation readable.',
      whenToUse:
          'Use when the user asks to simplify, reduce complexity, or refactor for clarity.',
      argumentHint: '[target]',
      getPrompt: (args, context) async {
        final target = args.trim();
        final buffer = StringBuffer()
          ..writeln(
            'Simplify the solution while preserving behaviour. Remove unnecessary branching, duplication, and indirection.',
          )
          ..writeln(
            'Prefer smaller, easier-to-explain changes over broad rewrites.',
          );
        if (target.isNotEmpty) {
          buffer
            ..writeln()
            ..writeln('Simplification target: $target');
        }
        return [ClartCodeSkillContentBlock.text(buffer.toString().trimRight())];
      },
    ),
  );
}

void _registerIfMissing(
  ClartCodeSkillRegistry registry,
  ClartCodeSkillDefinition skill,
) {
  if (registry.has(skill.name)) {
    return;
  }
  registry.register(skill);
}
