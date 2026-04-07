import 'tool_models.dart';
import 'tool_permissions.dart';
import 'tool_registry.dart';

enum ToolPermissionDecision { allow, deny }

typedef ToolPermissionResolver = Future<ToolPermissionDecision> Function(
    ToolInvocation invocation);

typedef ToolExecutionHook = Future<void> Function(ToolInvocation invocation);

typedef ToolExecutionResultHook = Future<void> Function(
  ToolInvocation invocation,
  ToolExecutionResult result,
);

class ToolExecutionHooks {
  const ToolExecutionHooks({
    this.beforeExecute,
    this.afterExecute,
  });

  final ToolExecutionHook? beforeExecute;
  final ToolExecutionResultHook? afterExecute;
}

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
    ToolPermissionResolver? permissionResolver,
    ToolExecutionHooks hooks = const ToolExecutionHooks(),
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
          (item) => _executeToolSafely(
            item.tool,
            item.invocation,
            hooks: hooks,
          ),
        ),
      );
      for (var i = 0; i < pendingBatch.length; i++) {
        results[pendingBatch[i].index] = batchResults[i];
      }
    }

    for (var index = 0; index < invocations.length; index++) {
      final invocation = invocations[index];
      final permissionFailure = await _resolvePermissionFailure(
        invocation: invocation,
        permissionPolicy: permissionPolicy,
        permissionResolver: permissionResolver,
      );
      if (permissionFailure != null) {
        await flushParallelSafeBatch();
        results[index] = permissionFailure;
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
      results[index] = await _executeToolSafely(
        tool,
        invocation,
        hooks: hooks,
      );
    }

    await flushParallelSafeBatch();

    return results.map((result) => result!).toList(growable: false);
  }

  Future<ToolExecutionResult> _executeToolSafely(
    Tool tool,
    ToolInvocation invocation, {
    ToolExecutionHooks hooks = const ToolExecutionHooks(),
  }) async {
    try {
      if (hooks.beforeExecute != null) {
        await hooks.beforeExecute!(invocation);
      }
      final result = await tool.run(invocation);
      if (hooks.afterExecute != null) {
        await hooks.afterExecute!(invocation, result);
      }
      return result;
    } catch (error) {
      final result = ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'tool_runtime_error',
        errorMessage: '$error',
      );
      if (hooks.afterExecute != null) {
        await hooks.afterExecute!(invocation, result);
      }
      return result;
    }
  }

  Future<ToolExecutionResult?> _resolvePermissionFailure({
    required ToolInvocation invocation,
    required ToolPermissionPolicy permissionPolicy,
    required ToolPermissionResolver? permissionResolver,
  }) async {
    if (permissionPolicy.canExecute(invocation.name)) {
      if (permissionResolver == null) {
        return null;
      }

      final decision = await permissionResolver(invocation);
      if (decision == ToolPermissionDecision.allow) {
        return null;
      }

      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'permission_denied',
        errorMessage: 'tool execution was rejected by permission resolver',
      );
    }

    if (!permissionPolicy.shouldAsk(invocation.name)) {
      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'permission_denied',
        errorMessage: 'tool execution is denied by current policy',
      );
    }

    if (permissionResolver == null) {
      return ToolExecutionResult.failure(
        tool: invocation.name,
        errorCode: 'permission_prompt_unavailable',
        errorMessage:
            'tool execution requires approval but no resolver is available',
      );
    }

    final decision = await permissionResolver(invocation);
    if (decision == ToolPermissionDecision.allow) {
      return null;
    }

    return ToolExecutionResult.failure(
      tool: invocation.name,
      errorCode: 'permission_denied',
      errorMessage: 'tool execution was rejected by permission resolver',
    );
  }
}
