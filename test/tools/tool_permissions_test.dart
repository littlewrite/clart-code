import 'package:clart_code/src/tools/tool_permissions.dart';
import 'package:test/test.dart';

void main() {
  group('ToolPermissionPolicy - Fine-grained Control', () {
    test('default allow mode permits all tools', () {
      final policy = const ToolPermissionPolicy(
        defaultMode: ToolPermissionMode.allow,
      );

      expect(policy.canExecute('read'), true);
      expect(policy.canExecute('write'), true);
      expect(policy.canExecute('shell'), true);
    });

    test('default deny mode blocks all tools', () {
      final policy = const ToolPermissionPolicy(
        defaultMode: ToolPermissionMode.deny,
      );

      expect(policy.canExecute('read'), false);
      expect(policy.canExecute('write'), false);
      expect(policy.canExecute('shell'), false);
    });

    test('tool-specific rules override default mode', () {
      final readRule = ToolPermissionRule(
        toolName: 'read',
        mode: ToolPermissionMode.allow,
      );
      final writeRule = ToolPermissionRule(
        toolName: 'write',
        mode: ToolPermissionMode.deny,
      );

      final policy = ToolPermissionPolicy(
        defaultMode: ToolPermissionMode.deny,
        rules: {'read': readRule, 'write': writeRule},
      );

      expect(policy.canExecute('read'), true);
      expect(policy.canExecute('write'), false);
      expect(policy.canExecute('shell'), false);
    });

    test('shouldAsk() identifies ask mode tools', () {
      final askRule = ToolPermissionRule(
        toolName: 'shell',
        mode: ToolPermissionMode.ask,
      );

      final policy = ToolPermissionPolicy(
        defaultMode: ToolPermissionMode.allow,
        rules: {'shell': askRule},
      );

      expect(policy.shouldAsk('shell'), true);
      expect(policy.shouldAsk('read'), false);
    });

    test('withRule() adds or updates a rule', () {
      var policy = const ToolPermissionPolicy();
      final rule = ToolPermissionRule(
        toolName: 'shell',
        mode: ToolPermissionMode.deny,
      );

      policy = policy.withRule(rule);

      expect(policy.canExecute('shell'), false);
      expect(policy.canExecute('read'), true);
    });

    test('withoutRule() removes a rule', () {
      final rule = ToolPermissionRule(
        toolName: 'shell',
        mode: ToolPermissionMode.deny,
      );

      var policy = ToolPermissionPolicy(
        defaultMode: ToolPermissionMode.allow,
        rules: {'shell': rule},
      );

      policy = policy.withoutRule('shell');

      expect(policy.canExecute('shell'), true);
    });

    test('JSON serialization preserves policy state', () {
      final rule = ToolPermissionRule(
        toolName: 'shell',
        mode: ToolPermissionMode.ask,
        description: 'Ask before executing shell commands',
      );

      final policy = ToolPermissionPolicy(
        defaultMode: ToolPermissionMode.allow,
        rules: {'shell': rule},
      );

      final json = policy.toJson();
      final restored = ToolPermissionPolicy.fromJson(json);

      expect(restored.defaultMode, ToolPermissionMode.allow);
      expect(restored.canExecute('shell'), false);
      expect(restored.shouldAsk('shell'), true);
    });
  });
}
