import 'builtin_tools.dart';
import 'tool_models.dart';
import 'tool_permissions.dart';
import 'tool_registry.dart';
import 'tool_scheduler.dart';

class ToolExecutor {
  ToolExecutor({
    required this.registry,
    this.scheduler = const ToolScheduler(),
    this.permissionPolicy = const ToolPermissionPolicy(),
  });

  final ToolRegistry registry;
  final ToolScheduler scheduler;
  final ToolPermissionPolicy permissionPolicy;

  factory ToolExecutor.fromTools(
    Iterable<Tool> tools, {
    ToolScheduler scheduler = const ToolScheduler(),
    ToolPermissionPolicy permissionPolicy = const ToolPermissionPolicy(),
  }) {
    return ToolExecutor(
      registry: ToolRegistry(tools: tools.toList(growable: false)),
      scheduler: scheduler,
      permissionPolicy: permissionPolicy,
    );
  }

  factory ToolExecutor.minimal({
    ToolPermissionPolicy permissionPolicy = const ToolPermissionPolicy(),
  }) {
    return ToolExecutor.fromTools(
      [ReadTool(), WriteTool(), ShellStubTool()],
      permissionPolicy: permissionPolicy,
    );
  }

  ToolExecutor copyWith({
    ToolRegistry? registry,
    ToolScheduler? scheduler,
    ToolPermissionPolicy? permissionPolicy,
  }) {
    return ToolExecutor(
      registry: registry ?? this.registry,
      scheduler: scheduler ?? this.scheduler,
      permissionPolicy: permissionPolicy ?? this.permissionPolicy,
    );
  }

  ToolExecutor withAdditionalTools(Iterable<Tool> tools) {
    return copyWith(
      registry: registry.merged(tools),
    );
  }

  Future<List<ToolExecutionResult>> executeBatch(
    List<ToolInvocation> invocations, {
    ToolPermissionResolver? permissionResolver,
    ToolExecutionHooks hooks = const ToolExecutionHooks(),
  }) {
    return scheduler.runBatch(
      invocations: invocations,
      registry: registry,
      permissionPolicy: permissionPolicy,
      permissionResolver: permissionResolver,
      hooks: hooks,
    );
  }
}
