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

  factory ToolExecutor.minimal({
    ToolPermissionPolicy permissionPolicy = const ToolPermissionPolicy(),
  }) {
    return ToolExecutor(
      registry: ToolRegistry(
        tools: [ReadTool(), WriteTool(), ShellStubTool()],
      ),
      permissionPolicy: permissionPolicy,
    );
  }

  ToolExecutor copyWith({
    ToolPermissionPolicy? permissionPolicy,
  }) {
    return ToolExecutor(
      registry: registry,
      scheduler: scheduler,
      permissionPolicy: permissionPolicy ?? this.permissionPolicy,
    );
  }

  Future<List<ToolExecutionResult>> executeBatch(
    List<ToolInvocation> invocations,
  ) {
    return scheduler.runBatch(
      invocations: invocations,
      registry: registry,
      permissionPolicy: permissionPolicy,
    );
  }
}
