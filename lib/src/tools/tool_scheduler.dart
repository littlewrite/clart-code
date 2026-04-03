import 'tool_models.dart';
import 'tool_permissions.dart';
import 'tool_registry.dart';

class ToolScheduler {
  const ToolScheduler();

  Future<List<ToolExecutionResult>> runBatch({
    required List<ToolInvocation> invocations,
    required ToolRegistry registry,
    required ToolPermissionPolicy permissionPolicy,
  }) async {
    final results = <ToolExecutionResult>[];

    // Iteration 4 baseline:
    // keep deterministic serial execution while preserving executionHint
    // metadata on each tool for a future parallel scheduler.
    for (final invocation in invocations) {
      if (!permissionPolicy.canExecute(invocation.name)) {
        results.add(
          ToolExecutionResult.failure(
            tool: invocation.name,
            errorCode: 'permission_denied',
            errorMessage: 'tool execution is denied by current policy',
          ),
        );
        continue;
      }

      final tool = registry.lookup(invocation.name);
      if (tool == null) {
        results.add(
          ToolExecutionResult.failure(
            tool: invocation.name,
            errorCode: 'tool_not_found',
            errorMessage: 'unknown tool: ${invocation.name}',
          ),
        );
        continue;
      }

      try {
        results.add(await tool.run(invocation));
      } catch (error) {
        results.add(
          ToolExecutionResult.failure(
            tool: invocation.name,
            errorCode: 'tool_runtime_error',
            errorMessage: '$error',
          ),
        );
      }
    }

    return results;
  }
}
