import 'tool_models.dart';
import 'tool_permissions.dart';
import 'tool_registry.dart';

/// Schedules and executes tool invocations with parallel/serial batching.
///
/// Groups parallel-safe tools for concurrent execution while preserving order
/// and executing serial-only tools sequentially.
class ToolScheduler {
  const ToolScheduler();

  /// Executes a batch of tool invocations with optimal concurrency.
  ///
  /// Tools marked as [ToolExecutionHint.parallelSafe] are executed concurrently
  /// in batches, while [ToolExecutionHint.serialOnly] tools run sequentially.
  /// Permission checks are applied before execution.
  ///
  /// Returns results in the same order as the input invocations.
  Future<List<ToolExecutionResult>> runBatch({
    required List<ToolInvocation> invocations,
    required ToolRegistry registry,
    required ToolPermissionPolicy permissionPolicy,
  }) async {
    final results = List<ToolExecutionResult?>.filled(invocations.length, null);
    final parallelSafeBatch =
        <({int index, ToolInvocation invocation, Tool tool})>[];

    Future<void> flushParallelSafeBatch() async {
      if (parallelSafeBatch.isEmpty) {
        return;
      }

      final pendingBatch = List.of(parallelSafeBatch);
      parallelSafeBatch.clear();
      final batchResults = await Future.wait(
        pendingBatch.map(
          (item) => _executeToolSafely(item.tool, item.invocation),
        ),
      );
      for (var i = 0; i < pendingBatch.length; i++) {
        results[pendingBatch[i].index] = batchResults[i];
      }
    }

    for (var index = 0; index < invocations.length; index++) {
      final invocation = invocations[index];
      if (!permissionPolicy.canExecute(invocation.name)) {
        await flushParallelSafeBatch();
        results[index] = ToolExecutionResult.failure(
          tool: invocation.name,
          errorCode: 'permission_denied',
          errorMessage: 'tool execution is denied by current policy',
        );
        continue;
      }

      final tool = registry.lookup(invocation.name);
      if (tool == null) {
        await flushParallelSafeBatch();
        results[index] = ToolExecutionResult.failure(
          tool: invocation.name,
          errorCode: 'tool_not_found',
          errorMessage: 'unknown tool: ${invocation.name}',
        );
        continue;
      }

      if (tool.executionHint == ToolExecutionHint.parallelSafe) {
        parallelSafeBatch.add(
          (index: index, invocation: invocation, tool: tool),
        );
        continue;
      }

      await flushParallelSafeBatch();
      results[index] = await _executeToolSafely(tool, invocation);
    }

    await flushParallelSafeBatch();

    return results.map((result) => result!).toList(growable: false);
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
