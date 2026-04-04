import 'package:clart_code/src/tools/tool_models.dart';
import 'package:clart_code/src/tools/tool_permissions.dart';
import 'package:clart_code/src/tools/tool_registry.dart';
import 'package:clart_code/src/tools/tool_scheduler.dart';
import 'package:test/test.dart';

void main() {
  group('ToolScheduler - Concurrent Execution', () {
    late ToolScheduler scheduler;
    late ToolRegistry registry;

    setUp(() {
      scheduler = const ToolScheduler();
      registry = ToolRegistry(
        tools: [
          _MockParallelTool('parallel1'),
          _MockParallelTool('parallel2'),
          _MockSerialTool('serial1'),
        ],
      );
    });

    test('executes parallel-safe tools concurrently', () async {
      final invocations = [
        ToolInvocation(name: 'parallel1'),
        ToolInvocation(name: 'parallel2'),
      ];

      final results = await scheduler.runBatch(
        invocations: invocations,
        registry: registry,
        permissionPolicy: const ToolPermissionPolicy(),
      );

      expect(results.length, 2);
      expect(results.every((r) => r.ok), true);
    });

    test('executes serial-only tools sequentially', () async {
      final invocations = [
        ToolInvocation(name: 'serial1'),
      ];

      final results = await scheduler.runBatch(
        invocations: invocations,
        registry: registry,
        permissionPolicy: const ToolPermissionPolicy(),
      );

      expect(results.length, 1);
      expect(results.first.ok, true);
    });

    test('handles permission denial', () async {
      final policy = _DenyAllPolicy();
      final invocations = [
        ToolInvocation(name: 'parallel1'),
      ];

      final results = await scheduler.runBatch(
        invocations: invocations,
        registry: registry,
        permissionPolicy: policy,
      );

      expect(results.length, 1);
      expect(results.first.ok, false);
      expect(results.first.errorCode, 'permission_denied');
    });

    test('handles tool not found', () async {
      final invocations = [
        ToolInvocation(name: 'nonexistent'),
      ];

      final results = await scheduler.runBatch(
        invocations: invocations,
        registry: registry,
        permissionPolicy: const ToolPermissionPolicy(),
      );

      expect(results.length, 1);
      expect(results.first.ok, false);
      expect(results.first.errorCode, 'tool_not_found');
    });

    test('handles tool runtime error', () async {
      final registry = ToolRegistry(
        tools: [_FailingTool()],
      );
      final invocations = [
        ToolInvocation(name: 'failing'),
      ];

      final results = await scheduler.runBatch(
        invocations: invocations,
        registry: registry,
        permissionPolicy: const ToolPermissionPolicy(),
      );

      expect(results.length, 1);
      expect(results.first.ok, false);
      expect(results.first.errorCode, 'tool_runtime_error');
    });
  });
}

class _MockParallelTool extends Tool {
  _MockParallelTool(this._name);

  final String _name;

  @override
  String get name => _name;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    await Future.delayed(Duration(milliseconds: 10));
    return ToolExecutionResult.success(
      tool: name,
      output: 'parallel result',
    );
  }
}

class _MockSerialTool extends Tool {
  _MockSerialTool(this._name);

  final String _name;

  @override
  String get name => _name;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.serialOnly;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    return ToolExecutionResult.success(
      tool: name,
      output: 'serial result',
    );
  }
}

class _FailingTool extends Tool {
  @override
  String get name => 'failing';

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    throw Exception('Tool execution failed');
  }
}

class _DenyAllPolicy implements ToolPermissionPolicy {
  const _DenyAllPolicy();

  @override
  ToolPermissionMode get defaultMode => ToolPermissionMode.deny;

  @override
  Map<String, ToolPermissionRule> get rules => {};

  @override
  bool canExecute(String toolName) => false;

  @override
  bool shouldAsk(String toolName) => false;

  @override
  ToolPermissionPolicy copyWith({
    ToolPermissionMode? defaultMode,
    Map<String, ToolPermissionRule>? rules,
  }) =>
      this;

  @override
  ToolPermissionPolicy withRule(ToolPermissionRule rule) => this;

  @override
  ToolPermissionPolicy withoutRule(String toolName) => this;

  @override
  Map<String, Object?> toJson() => {};
}
