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

    // Group invocations by execution hint for concurrent scheduling
    final parallelSafeGroup = <(ToolInvocation, Tool)>[];
    final serialOnlyGroup = <(ToolInvocation, Tool)>[];

    // First pass: validate permissions and group by execution hint
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

      if (tool.executionHint == ToolExecutionHint.parallelSafe) {
        parallelSafeGroup.add((invocation, tool));
      } else {
        serialOnlyGroup.add((invocation, tool));
      }
    }

    // Execute parallel-safe tools concurrently
    if (parallelSafeGroup.isNotEmpty) {
      final parallelResults = await Future.wait(
        parallelSafeGroup.map((pair) => _executeToolSafely(pair.$2, pair.$1)),
      );
      results.addAll(parallelResults);
    }

    // Execute serial-only tools sequentially
    for (final (invocation, tool) in serialOnlyGroup) {
      results.add(await _executeToolSafely(tool, invocation));
    }

    return results;
  }

  Future<ToolExecutionResult> _executeToolSafely(
    Tool tool,
    ToolInvocation invocation,
  ) async {
    try {
      return await tool.run(invocation);
    } catch (error) {
      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'tool_runtime_error',
        errorMessage: '$error',
      );
    }
  }
}
