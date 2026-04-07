import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../core/app_config.dart';
import '../core/conversation_session.dart';
import '../core/models.dart';
import '../core/process_user_input.dart';
import '../core/prompt_submitter.dart';
import '../core/query_engine.dart';
import '../core/runtime_error.dart';
import '../core/transcript.dart';
import '../mcp/mcp_manager.dart';
import '../mcp/mcp_types.dart';
import '../providers/llm_provider.dart';
import '../providers/provider_strategy.dart';
import '../runtime/app_runtime.dart';
import '../tools/mcp_tools.dart';
import '../tools/tool_executor.dart';
import '../tools/tool_models.dart';
import '../tools/tool_permissions.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_scheduler.dart';
import 'sdk_models.dart';
import 'session_store.dart';

class ClartCodeAgent {
  ClartCodeAgent([
    ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  ])  : _options = options,
        _cwd = options.cwd ?? Directory.current.path,
        _sessionStore = ClartCodeSessionStore(cwd: options.cwd) {
    _config = AppConfig(
      provider: options.provider,
      model: options.model,
      claudeApiKey: options.claudeApiKey,
      claudeBaseUrl: options.claudeBaseUrl,
      openAiApiKey: options.openAiApiKey,
      openAiBaseUrl: options.openAiBaseUrl,
    );
    _sessionId = options.resumeSessionId ??
        options.sessionId ??
        _sessionStore.createSessionId();
    _restoreConversation();
    _rebuildRuntime();
    _persistSession();
  }

  final ClartCodeAgentOptions _options;
  final String _cwd;
  final ClartCodeSessionStore _sessionStore;
  final UserInputProcessor _inputProcessor = const UserInputProcessor();

  late AppConfig _config;
  late String _sessionId;
  late String _createdAt;
  late ConversationSession _conversation;
  late AppRuntime _runtime;
  late QueryEngine _engine;
  String? _sessionTitle;
  List<String> _sessionTags = const [];
  bool _queryInProgress = false;
  bool _stopRequested = false;
  bool _stopNotified = false;
  String? _stopReason;
  String? _activeModel;
  QueryCancellationController? _activeCancellationController;
  McpManager? _mcpManager;
  bool _runtimePrepared = false;
  final Queue<_QueuedAgentRun> _pendingRuns = Queue<_QueuedAgentRun>();
  bool _drainingRuns = false;

  int _toolCallCounter = 0;

  String get sessionId => _sessionId;

  String get cwd => _cwd;

  ProviderKind get provider => _config.provider;

  String? get model => _config.model;

  String? get sessionTitle => _sessionTitle;

  List<String> get sessionTags => List<String>.unmodifiable(_sessionTags);

  bool get isRunning => _queryInProgress;

  int get queuedInputCount => _pendingRuns.length;

  List<ChatMessage> getMessages() => _conversation.history;

  List<TranscriptMessage> getTranscript() => _conversation.transcript;

  ClartCodeSessionSnapshot snapshot() => _buildSessionSnapshot();

  List<String> get availableTools =>
      toolDefinitions.map((tool) => tool.name).toList(growable: false);

  List<ClartCodeToolDefinition> get toolDefinitions {
    final definitions = _runtime.toolExecutor.registry.all
        .map(ClartCodeToolDefinition.fromTool)
        .toList();
    definitions.sort((left, right) => left.name.compareTo(right.name));
    return List<ClartCodeToolDefinition>.unmodifiable(definitions);
  }

  List<McpConnection> get mcpConnections {
    final manager = _mcpManager;
    if (manager == null) {
      return const [];
    }
    final connections = manager.getAllConnections().toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    return List<McpConnection>.unmodifiable(connections);
  }

  List<McpConnection> get failedMcpConnections => mcpConnections
      .where((connection) => connection.status == McpServerStatus.failed)
      .toList(growable: false);

  Future<void> prepare() async {
    await _ensureRuntimeReady();
  }

  void clear() {
    _conversation.clear();
    _persistSession();
  }

  void setModel(String? nextModel) {
    _config = _config.copyWith(model: nextModel);
    _rebuildRuntime();
    _persistSession();
  }

  ClartCodeSessionSnapshot renameSession(String title) {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError.value(
          title, 'title', 'session title cannot be empty');
    }
    _sessionTitle = normalizedTitle;
    _persistSession();
    return _buildSessionSnapshot();
  }

  ClartCodeSessionSnapshot setSessionTags(List<String> tags) {
    _sessionTags = _normalizeTags(tags);
    _persistSession();
    return _buildSessionSnapshot();
  }

  ClartCodeSessionSnapshot addSessionTag(String tag) {
    final normalizedTag = tag.trim();
    if (normalizedTag.isEmpty) {
      throw ArgumentError.value(tag, 'tag', 'session tag cannot be empty');
    }
    return setSessionTags([..._sessionTags, normalizedTag]);
  }

  ClartCodeSessionSnapshot removeSessionTag(String tag) {
    final normalizedTag = tag.trim();
    if (normalizedTag.isEmpty) {
      return _buildSessionSnapshot();
    }
    return setSessionTags(
      _sessionTags.where((item) => item != normalizedTag).toList(),
    );
  }

  ClartCodeSessionSnapshot forkSession({
    String? title,
    List<String>? tags,
  }) {
    final forked = _sessionStore.fork(
      _sessionId,
      title: title,
      tags: tags,
    );
    if (forked == null) {
      final current = _buildSessionSnapshot();
      _sessionStore.save(current);
      final recreated = _sessionStore.fork(
        _sessionId,
        title: title,
        tags: tags,
      );
      if (recreated != null) {
        return recreated;
      }
      throw StateError('failed to fork session $_sessionId');
    }
    return forked;
  }

  Future<void> stop({String reason = 'manual_stop'}) async {
    if (!_queryInProgress || _stopRequested) {
      return;
    }
    _stopRequested = true;
    _stopReason = reason;
    _activeCancellationController?.cancel(reason);
    if (_stopNotified) {
      return;
    }
    _stopNotified = true;
    await _options.hooks.onStop?.call(
      ClartCodeStopEvent(
        sessionId: _sessionId,
        cwd: _cwd,
        provider: _config.provider,
        model: _activeModel ?? _config.model,
        reason: reason,
      ),
    );
  }

  Future<void> interrupt({String reason = 'manual_interrupt'}) async {
    await stop(reason: reason);
  }

  Future<int> clearQueuedInputs({
    String reason = 'queued inputs cleared',
  }) async {
    if (_pendingRuns.isEmpty) {
      return 0;
    }

    final cancelledRuns = _pendingRuns.toList(growable: false);
    _pendingRuns.clear();
    for (final run in cancelledRuns) {
      await _emitQueuedCancellation(
        run,
        reason: reason,
      );
    }
    return cancelledRuns.length;
  }

  Future<void> close() async {
    await clearQueuedInputs(reason: 'agent closed');
    _persistSession();
    await _mcpManager?.disconnectAll();
  }

  Stream<ClartCodeSdkMessage> query(
    String prompt, {
    String? model,
    QueryCancellationSignal? cancellationSignal,
  }) async* {
    final run = _QueuedAgentRun(
      prompt: prompt,
      model: model,
      cancellationSignal: cancellationSignal,
    );
    if (cancellationSignal?.isCancelled ?? false) {
      await _emitQueuedCancellation(
        run,
        reason: cancellationSignal?.reason ?? 'request cancelled',
      );
    } else {
      _enqueueRun(run);
    }
    yield* run.controller.stream;
  }

  Stream<ClartCodeSdkMessage> _executeQuery(
    String prompt, {
    String? model,
    QueryCancellationSignal? cancellationSignal,
  }) async* {
    final watch = Stopwatch()..start();
    try {
      await _ensureRuntimeReady();
    } catch (error) {
      final runtimeError = RuntimeError(
        code: RuntimeErrorCode.providerFailure,
        message: 'failed to initialize SDK runtime: $error',
        source: 'sdk_agent',
        retriable: false,
      );
      yield ClartCodeSdkMessage.result(
        sessionId: _sessionId,
        subtype: 'error_runtime_init',
        text: '[ERROR] ${runtimeError.message}',
        isError: true,
        model: model ?? _config.model,
        turns: 0,
        error: runtimeError,
        durationMs: watch.elapsedMilliseconds,
      );
      return;
    }
    final submitter = PromptSubmitter(conversation: _conversation);
    final submission = submitter.submit(prompt, model: model ?? _config.model);
    final processed = _inputProcessor.process(submission);
    final definitions = toolDefinitions;
    final providerToolDefinitions = _providerToolDefinitions(definitions);
    final normalizedMaxTurns = _options.maxTurns < 1 ? 1 : _options.maxTurns;

    yield ClartCodeSdkMessage.systemInit(
      sessionId: _sessionId,
      cwd: _cwd,
      model: model ?? _config.model,
      tools: availableTools,
      toolDefinitions: definitions,
    );

    if (!processed.isQuery) {
      final error = RuntimeError(
        code: RuntimeErrorCode.invalidInput,
        message: processed.status ?? 'Only plain prompts are supported.',
        source: 'sdk_agent',
        retriable: false,
      );
      final output = processed.errorText ?? error.message;
      _conversation.appendTranscriptMessages(
        processed.transcriptMessages.isEmpty
            ? [TranscriptMessage.system(output)]
            : processed.transcriptMessages,
      );
      _persistSession();
      yield ClartCodeSdkMessage.result(
        sessionId: _sessionId,
        subtype: 'error_invalid_input',
        text: output,
        isError: true,
        model: model ?? _config.model,
        turns: 0,
        error: error,
        durationMs: watch.elapsedMilliseconds,
      );
      return;
    }

    final userPrompt = processed.submission.raw;
    final selectedModel = model ?? _config.model;
    _queryInProgress = true;
    _stopRequested = cancellationSignal?.isCancelled ?? false;
    _stopNotified = false;
    _stopReason = _stopRequested
        ? cancellationSignal?.reason ?? 'request cancelled'
        : null;
    _activeModel = selectedModel;
    StreamSubscription<void>? externalCancellationSub;
    if (cancellationSignal != null) {
      externalCancellationSub = cancellationSignal.onCancel.listen((_) {
        unawaited(
          stop(
            reason: cancellationSignal.reason ?? 'request cancelled',
          ),
        );
      });
    }
    final workingMessages = List<ChatMessage>.from(processed.request!.messages);
    var pendingProviderMessages = List<ChatMessage>.from(workingMessages);
    String? providerStateToken;
    _conversation.appendTranscriptMessages(processed.transcriptMessages);
    _conversation.appendHistoryMessages([
      ChatMessage(role: MessageRole.user, text: userPrompt),
    ]);
    _persistSession();
    await _options.hooks.onSessionStart?.call(
      ClartCodeSessionStartEvent(
        sessionId: _sessionId,
        cwd: _cwd,
        provider: _config.provider,
        prompt: userPrompt,
        model: selectedModel,
        availableTools: availableTools,
        toolDefinitions: definitions,
      ),
    );

    var modelUsed = selectedModel;
    var completedTurns = 0;
    try {
      for (var turn = 1; turn <= normalizedMaxTurns; turn++) {
        if (_stopRequested) {
          final stoppedResult = await _finishWithError(
            watch: watch,
            prompt: userPrompt,
            modelUsed: modelUsed,
            turns: completedTurns,
            subtype: 'error_stopped',
            error: _stoppedError(),
          );
          yield stoppedResult;
          return;
        }

        completedTurns = turn;
        await _options.hooks.onModelTurnStart?.call(
          ClartCodeModelTurnStartEvent(
            sessionId: _sessionId,
            cwd: _cwd,
            provider: _config.provider,
            prompt: userPrompt,
            turn: turn,
            model: modelUsed,
            availableTools: availableTools,
          ),
        );
        final request = _buildToolLoopRequest(
          messages: providerStateToken == null
              ? workingMessages
              : pendingProviderMessages,
          model: selectedModel,
          toolDefinitions: definitions,
          providerToolDefinitions: providerToolDefinitions,
          providerStateToken: providerStateToken,
          cancellationSignal: (_activeCancellationController =
                  QueryCancellationController())
              .signal,
        );
        final turnWatch = Stopwatch()..start();
        final turnResult = await _runProviderTurn(request: request, turn: turn);
        turnWatch.stop();
        _activeCancellationController?.close();
        _activeCancellationController = null;
        if (turnResult.providerStateToken != null &&
            turnResult.providerStateToken!.isNotEmpty) {
          providerStateToken = turnResult.providerStateToken;
        }

        if (turnResult.modelUsed != null && turnResult.modelUsed!.isNotEmpty) {
          modelUsed = turnResult.modelUsed;
          _activeModel = modelUsed;
        }
        final toolCalls = turnResult.toolCalls.isNotEmpty
            ? _sdkToolCallsFromProviderToolCalls(turnResult.toolCalls)
            : _parseToolCalls(turnResult.rawOutput);

        await _options.hooks.onModelTurnEnd?.call(
          ClartCodeModelTurnEndEvent(
            sessionId: _sessionId,
            cwd: _cwd,
            provider: _config.provider,
            prompt: userPrompt,
            turn: turn,
            model: modelUsed,
            rawOutput: turnResult.rawOutput,
            output: turnResult.output,
            toolCalls: toolCalls,
            durationMs: turnWatch.elapsedMilliseconds,
            error: turnResult.error,
          ),
        );

        for (final delta in turnResult.deltas) {
          yield ClartCodeSdkMessage.assistantDelta(
            sessionId: _sessionId,
            delta: delta,
            model: modelUsed,
            turn: turn,
          );
        }

        if (turnResult.error != null) {
          final terminal = await _finishWithError(
            watch: watch,
            prompt: userPrompt,
            modelUsed: modelUsed,
            turns: completedTurns,
            subtype: turnResult.error!.code == RuntimeErrorCode.cancelled
                ? 'error_stopped'
                : 'error_during_execution',
            error: turnResult.error!,
            terminalOutput: turnResult.output,
          );
          yield terminal;
          return;
        }

        final output = turnResult.output;
        if (toolCalls.isEmpty) {
          _conversation.appendHistoryMessages([
            ChatMessage(role: MessageRole.assistant, text: output),
          ]);
          _conversation.appendTranscriptMessages([
            TranscriptMessage.assistant(output),
          ]);
          _persistSession();
          watch.stop();
          yield ClartCodeSdkMessage.assistant(
            sessionId: _sessionId,
            text: output,
            model: modelUsed,
            turn: turn,
          );
          final promptResult = ClartCodePromptResult(
            sessionId: _sessionId,
            text: output,
            turns: completedTurns,
            isError: false,
            messages: const [],
            model: modelUsed,
            durationMs: watch.elapsedMilliseconds,
          );
          await _options.hooks.onSessionEnd?.call(
            ClartCodeSessionEndEvent(
              sessionId: _sessionId,
              cwd: _cwd,
              provider: _config.provider,
              prompt: userPrompt,
              model: modelUsed,
              result: promptResult,
            ),
          );
          yield ClartCodeSdkMessage.result(
            sessionId: _sessionId,
            subtype: 'success',
            text: output,
            isError: false,
            model: modelUsed,
            turns: completedTurns,
            durationMs: watch.elapsedMilliseconds,
          );
          return;
        }

        final assistantToolMessage = ChatMessage(
          role: MessageRole.assistant,
          text: turnResult.toolCalls.isNotEmpty
              ? _buildAssistantToolCallPayload(
                  toolCalls,
                  text: turnResult.rawOutput,
                )
              : turnResult.rawOutput,
        );
        workingMessages.add(assistantToolMessage);
        _conversation.appendHistoryMessages([assistantToolMessage]);
        pendingProviderMessages = const [];

        for (final toolCall in toolCalls) {
          yield ClartCodeSdkMessage.toolCall(
            sessionId: _sessionId,
            toolCall: toolCall,
            model: modelUsed,
            turn: turn,
          );
        }

        final invocationMap = Map<ToolInvocation, ClartCodeToolCall>.identity();
        final invocations = toolCalls.map((toolCall) {
          final invocation = ToolInvocation(
            id: toolCall.id,
            name: toolCall.name,
            input: toolCall.input,
          );
          invocationMap[invocation] = toolCall;
          return invocation;
        }).toList(growable: false);
        final needsPermissionResolver = _options.canUseTool != null ||
            invocations.any(
              (invocation) => _runtime.toolExecutor.permissionPolicy.shouldAsk(
                invocation.name,
              ),
            );
        final executionResults = await _runtime.toolExecutor.executeBatch(
          invocations,
          permissionResolver: !needsPermissionResolver
              ? null
              : (invocation) async {
                  final toolCall = invocationMap[invocation] ??
                      toolCalls.firstWhere(
                        (candidate) => candidate.id == invocation.id,
                      );
                  final context = _toolContext(turn: turn, model: modelUsed);
                  final permissionOutcome =
                      await _options.resolveToolPermission?.call(
                    toolCall,
                    context,
                  );
                  if (permissionOutcome != null) {
                    await _options.hooks.onToolPermissionDecision?.call(
                      ClartCodeToolPermissionEvent(
                        context: context,
                        toolCall: toolCall,
                        decision: permissionOutcome.decision,
                        source:
                            ClartCodeToolPermissionSource.resolveToolPermission,
                        message: permissionOutcome.message,
                        updatedInput: permissionOutcome.updatedInput,
                      ),
                    );
                    return permissionOutcome.isAllowed
                        ? ToolPermissionResolution.allow(
                            invocation: permissionOutcome.updatedInput == null
                                ? invocation
                                : invocation.copyWith(
                                    input: permissionOutcome.updatedInput,
                                  ),
                            message: permissionOutcome.message,
                          )
                        : ToolPermissionResolution.deny(
                            message: permissionOutcome.message,
                          );
                  }

                  final allowed = await _options.canUseTool?.call(
                        toolCall,
                        context,
                      ) ??
                      true;
                  if (_options.canUseTool != null) {
                    await _options.hooks.onToolPermissionDecision?.call(
                      ClartCodeToolPermissionEvent(
                        context: context,
                        toolCall: toolCall,
                        decision: allowed
                            ? ClartCodeToolPermissionDecision.allow
                            : ClartCodeToolPermissionDecision.deny,
                        source: ClartCodeToolPermissionSource.canUseTool,
                      ),
                    );
                  }
                  return allowed
                      ? ToolPermissionResolution.allow(invocation: invocation)
                      : ToolPermissionResolution.deny();
                },
          hooks: ToolExecutionHooks(
            beforeExecute: (invocation) async {
              final toolCall = invocationMap[invocation] ??
                  toolCalls.firstWhere(
                    (candidate) => candidate.id == invocation.id,
                  );
              await _options.hooks.onPreToolUse?.call(
                ClartCodeToolEvent(
                  context: _toolContext(turn: turn, model: modelUsed),
                  toolCall: toolCall,
                ),
              );
            },
          ),
        );

        for (var index = 0; index < executionResults.length; index++) {
          final toolCall = toolCalls[index];
          final result = executionResults[index];
          final sdkResult = ClartCodeToolResult(
            callId: toolCall.id,
            tool: result.tool,
            ok: result.ok,
            output: result.output,
            errorCode: result.errorCode,
            errorMessage: result.errorMessage,
            metadata: result.metadata,
          );
          final toolEvent = ClartCodeToolResultEvent(
            context: _toolContext(turn: turn, model: modelUsed),
            toolCall: toolCall,
            toolResult: sdkResult,
          );
          if (sdkResult.ok) {
            await _options.hooks.onPostToolUse?.call(toolEvent);
          } else {
            await _options.hooks.onPostToolUseFailure?.call(toolEvent);
          }
          final toolMessage = ChatMessage(
            role: MessageRole.tool,
            text: _buildToolResultPayload(toolCall, sdkResult),
          );
          workingMessages.add(toolMessage);
          pendingProviderMessages = [...pendingProviderMessages, toolMessage];
          _conversation.appendHistoryMessages([toolMessage]);
          _conversation.appendTranscriptMessages([
            TranscriptMessage.toolResult(toolMessage.text),
          ]);
          yield ClartCodeSdkMessage.toolResult(
            sessionId: _sessionId,
            toolResult: sdkResult,
            model: modelUsed,
            turn: turn,
          );
        }

        _persistSession();
      }

      final terminal = await _finishWithError(
        watch: watch,
        prompt: userPrompt,
        modelUsed: modelUsed,
        turns: completedTurns,
        subtype: 'error_max_turns_reached',
        error: RuntimeError(
          code: RuntimeErrorCode.unknown,
          message:
              'agent reached max turns ($normalizedMaxTurns) before producing a final assistant response',
          source: 'sdk_agent',
          retriable: false,
        ),
      );
      yield terminal;
    } finally {
      await externalCancellationSub?.cancel();
      _activeCancellationController?.close();
      _activeCancellationController = null;
      _queryInProgress = false;
      _activeModel = null;
      _stopReason = null;
    }
  }

  Future<ClartCodePromptResult> prompt(
    String prompt, {
    String? model,
    QueryCancellationSignal? cancellationSignal,
  }) async {
    final messages = <ClartCodeSdkMessage>[];
    await for (final message in query(
      prompt,
      model: model,
      cancellationSignal: cancellationSignal,
    )) {
      messages.add(message);
    }

    final result = messages.lastWhere(
      (message) => message.type == 'result',
      orElse: () => ClartCodeSdkMessage.result(
        sessionId: _sessionId,
        subtype: 'error_missing_result',
        text: 'Prompt completed without a terminal result.',
        isError: true,
      ),
    );

    return ClartCodePromptResult(
      sessionId: _sessionId,
      text: result.text ?? '',
      turns: result.turns ?? 1,
      isError: result.isError ?? false,
      messages: List<ClartCodeSdkMessage>.unmodifiable(messages),
      model: result.model,
      error: result.error,
      durationMs: result.durationMs,
    );
  }

  void _enqueueRun(_QueuedAgentRun run) {
    _pendingRuns.addLast(run);
    run.attachQueueCancellation(() async {
      await _cancelQueuedRun(
        run,
        reason: run.cancellationSignal?.reason ?? 'request cancelled',
      );
    });
    unawaited(_drainQueuedRuns());
  }

  Future<void> _drainQueuedRuns() async {
    if (_drainingRuns) {
      return;
    }
    _drainingRuns = true;
    try {
      while (_pendingRuns.isNotEmpty) {
        final run = _pendingRuns.removeFirst();
        run.markStarted();
        try {
          await run.controller.addStream(
            _executeQuery(
              run.prompt,
              model: run.model,
              cancellationSignal: run.cancellationSignal,
            ),
          );
        } finally {
          await run.close();
        }
      }
    } finally {
      _drainingRuns = false;
    }
  }

  Future<void> _cancelQueuedRun(
    _QueuedAgentRun run, {
    required String reason,
  }) async {
    if (!_pendingRuns.remove(run)) {
      return;
    }
    await _emitQueuedCancellation(run, reason: reason);
  }

  Future<void> _emitQueuedCancellation(
    _QueuedAgentRun run, {
    required String reason,
  }) async {
    final error = _buildCancelledRuntimeError(reason);
    final output = '[STOPPED] request cancelled before execution';
    final result = ClartCodePromptResult(
      sessionId: _sessionId,
      text: output,
      turns: 0,
      isError: true,
      messages: const [],
      model: run.model ?? _config.model,
      error: error,
      durationMs: 0,
    );
    await _options.hooks.onCancelledTerminal?.call(
      ClartCodeCancelledTerminalEvent(
        sessionId: _sessionId,
        cwd: _cwd,
        provider: _config.provider,
        prompt: run.prompt,
        model: run.model ?? _config.model,
        result: result,
        reason: reason,
      ),
    );
    run.controller.add(
      ClartCodeSdkMessage.result(
        sessionId: _sessionId,
        subtype: 'error_stopped',
        text: output,
        isError: true,
        model: run.model ?? _config.model,
        turns: 0,
        error: error,
        durationMs: 0,
      ),
    );
    await run.close();
  }

  void _restoreConversation() {
    final existing = _options.resumeSessionId == null
        ? null
        : _sessionStore.load(_options.resumeSessionId!);
    if (existing == null) {
      _createdAt = DateTime.now().toUtc().toIso8601String();
      _sessionTitle = null;
      _sessionTags = const [];
      _conversation = ConversationSession();
      return;
    }

    _createdAt = existing.createdAt;
    _sessionTitle = existing.title;
    _sessionTags = List<String>.from(existing.tags);
    _config = _config.copyWith(model: existing.model);
    _conversation = ConversationSession(
      initialMessages: existing.history,
      initialTranscript: existing.transcript,
    );
  }

  void _rebuildRuntime() {
    final baseExecutor =
        _options.toolExecutor ?? ToolExecutor.minimal(cwd: _cwd);
    final mergedExecutor = _options.tools == null || _options.tools!.isEmpty
        ? baseExecutor
        : baseExecutor.withAdditionalTools(_options.tools!);
    final toolExecutor = mergedExecutor.copyWith(
      registry: ToolRegistry(tools: _filterTools(mergedExecutor.registry.all)),
      permissionPolicy: _buildPermissionPolicy(),
    );
    _runtime = AppRuntime(
      provider: _options.providerOverride ??
          providerStrategyFor(_config.provider).build(_config),
      telemetry: _options.telemetry,
      securityGuard: _options.securityGuard,
      toolExecutor: toolExecutor,
    );
    _engine = QueryEngine(_runtime);
    _runtimePrepared = false;
  }

  ToolPermissionPolicy _buildPermissionPolicy() {
    final basePolicy = _options.permissionPolicy;
    if (_options.permissionMode == null) {
      return basePolicy;
    }
    return basePolicy.copyWith(defaultMode: _options.permissionMode);
  }

  List<Tool> _filterTools(Iterable<Tool> tools) {
    return tools
        .where((tool) => _isToolEnabled(tool.name))
        .toList(growable: false);
  }

  bool _isToolEnabled(String toolName) {
    final allowed = _options.allowedTools
        ?.map((tool) => tool.trim())
        .where((tool) => tool.isNotEmpty)
        .toSet();
    final disallowed = _options.disallowedTools
        ?.map((tool) => tool.trim())
        .where((tool) => tool.isNotEmpty)
        .toSet();

    if (allowed != null && !allowed.contains(toolName)) {
      return false;
    }
    if (disallowed != null && disallowed.contains(toolName)) {
      return false;
    }
    return true;
  }

  Future<void> _ensureRuntimeReady() async {
    if (_runtimePrepared) {
      return;
    }
    if (_options.mcp != null) {
      await _ensureMcpToolsLoaded(_options.mcp!);
    }
    _runtimePrepared = true;
  }

  Future<void> _ensureMcpToolsLoaded(ClartCodeMcpOptions options) async {
    final manager = _mcpManager ??
        _options.mcpManagerOverride ??
        McpManager(
          registryPath: options.registryPath ?? '$_cwd/.clart/mcp_servers.json',
        );
    _mcpManager = manager;

    await _connectMcpServers(manager, options);
    final mcpTools = await buildMcpTools(
      manager: manager,
      includeResourceTools: options.includeResourceTools,
    );
    for (final tool in mcpTools) {
      if (!_isToolEnabled(tool.name)) {
        continue;
      }
      if (_runtime.toolExecutor.registry.lookup(tool.name) != null) {
        continue;
      }
      _runtime.toolExecutor.registry.register(tool);
    }
  }

  Future<void> _connectMcpServers(
    McpManager manager,
    ClartCodeMcpOptions options,
  ) async {
    final selectedServers = options.serverNames
        ?.map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    if (selectedServers == null || selectedServers.isEmpty) {
      await manager.connectAll();
      return;
    }

    final registry = await manager.loadRegistry();
    for (final serverName in selectedServers) {
      final config = registry[serverName];
      if (config == null) {
        throw ArgumentError('unknown MCP server: $serverName');
      }
      await manager.connect(config);
    }
  }

  QueryRequest _buildToolLoopRequest({
    required List<ChatMessage> messages,
    required String? model,
    required List<ClartCodeToolDefinition> toolDefinitions,
    required List<QueryToolDefinition> providerToolDefinitions,
    required String? providerStateToken,
    required QueryCancellationSignal? cancellationSignal,
  }) {
    final useNativeToolCalling = _runtime.provider.supportsNativeToolCalling;
    return QueryRequest(
      messages: [
        if (toolDefinitions.isNotEmpty && !useNativeToolCalling)
          ChatMessage(
            role: MessageRole.system,
            text: _buildToolProtocolPrompt(toolDefinitions),
          ),
        ...messages,
      ],
      maxTurns: _options.maxTurns,
      model: model,
      toolDefinitions:
          useNativeToolCalling ? providerToolDefinitions : const [],
      providerStateToken: useNativeToolCalling ? providerStateToken : null,
      cancellationSignal: cancellationSignal,
    );
  }

  List<QueryToolDefinition> _providerToolDefinitions(
    List<ClartCodeToolDefinition> toolDefinitions,
  ) {
    return toolDefinitions
        .map(
          (tool) => QueryToolDefinition(
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
          ),
        )
        .toList(growable: false);
  }

  String _buildToolProtocolPrompt(
    List<ClartCodeToolDefinition> toolDefinitions,
  ) {
    final buffer = StringBuffer()
      ..writeln('You may use tools when needed.')
      ..writeln(
        'If a tool is needed, respond with JSON only and no extra text.',
      )
      ..writeln('Use this exact envelope:')
      ..writeln(
        '{"tool_calls":[{"id":"call_1","name":"tool_name","input":{"key":"value"}}]}',
      )
      ..writeln('If no tool is needed, answer normally.')
      ..writeln(
        'After tool results arrive in later [tool] messages, either answer normally or emit another tool_calls JSON block.',
      )
      ..writeln('Available tools:');

    for (final tool in toolDefinitions) {
      buffer.writeln('- ${tool.name}: ${tool.description}');
      if (tool.inputSchema != null) {
        buffer.writeln('  schema: ${jsonEncode(tool.inputSchema)}');
      }
    }
    return buffer.toString().trimRight();
  }

  Future<_ProviderTurnResult> _runProviderTurn({
    required QueryRequest request,
    required int turn,
  }) async {
    final deltas = <String>[];
    final outputBuffer = StringBuffer();
    var toolCalls = const <QueryToolCall>[];
    RuntimeError? terminalError;
    String? terminalOutput;
    String? modelUsed = request.model;
    String? providerStateToken;

    await for (final event in _engine.runStream(request)) {
      if (_stopRequested) {
        terminalError = _stoppedError();
        terminalOutput = '[STOPPED] request cancelled';
        break;
      }

      if (event.model != null && event.model!.isNotEmpty) {
        modelUsed = event.model;
      }

      switch (event.type) {
        case ProviderStreamEventType.textDelta:
          final delta = event.delta ?? '';
          if (delta.isEmpty) {
            continue;
          }
          deltas.add(delta);
          outputBuffer.write(delta);
          break;
        case ProviderStreamEventType.done:
          terminalOutput = event.output ?? outputBuffer.toString();
          toolCalls = event.toolCalls;
          providerStateToken = event.providerStateToken;
          break;
        case ProviderStreamEventType.error:
          terminalError = event.error;
          terminalOutput = event.output ?? outputBuffer.toString();
          toolCalls = event.toolCalls;
          providerStateToken = event.providerStateToken;
          break;
      }
    }

    final rawOutput = terminalOutput ?? outputBuffer.toString();
    return _ProviderTurnResult(
      turn: turn,
      deltas: deltas,
      rawOutput: rawOutput,
      output: _normalizeSuccessOutput(rawOutput),
      modelUsed: modelUsed,
      error: terminalError,
      toolCalls: toolCalls,
      providerStateToken: providerStateToken,
    );
  }

  List<ClartCodeToolCall> _sdkToolCallsFromProviderToolCalls(
    List<QueryToolCall> toolCalls,
  ) {
    return toolCalls
        .map(
          (toolCall) => ClartCodeToolCall(
            id: toolCall.id,
            name: toolCall.name,
            input: Map<String, Object?>.unmodifiable(toolCall.input),
          ),
        )
        .toList(growable: false);
  }

  List<ClartCodeToolCall> _parseToolCalls(String rawOutput) {
    final trimmed = rawOutput.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final candidates = <String>[trimmed];
    final fencedMatches = RegExp(r'```(?:json)?\s*([\s\S]*?)```')
        .allMatches(trimmed)
        .map((match) => match.group(1)?.trim())
        .whereType<String>();
    candidates.addAll(fencedMatches);

    for (final candidate in candidates) {
      final parsed = _tryDecodeJson(candidate);
      if (parsed == null) {
        continue;
      }
      final toolCalls = _toolCallsFromJson(parsed);
      if (toolCalls.isNotEmpty) {
        return toolCalls;
      }
    }

    return const [];
  }

  Object? _tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  List<ClartCodeToolCall> _toolCallsFromJson(Object parsed) {
    if (parsed is List) {
      return parsed
          .whereType<Map>()
          .map((item) => _toolCallFromMap(Map<String, Object?>.from(item)))
          .whereType<ClartCodeToolCall>()
          .toList(growable: false);
    }

    if (parsed is! Map) {
      return const [];
    }

    final map = Map<String, Object?>.from(parsed);
    final toolCalls = map['tool_calls'];
    if (toolCalls is List) {
      return toolCalls
          .whereType<Map>()
          .map((item) => _toolCallFromMap(Map<String, Object?>.from(item)))
          .whereType<ClartCodeToolCall>()
          .toList(growable: false);
    }

    final singleCall = _toolCallFromMap(map);
    if (singleCall != null) {
      return [singleCall];
    }

    return const [];
  }

  ClartCodeToolCall? _toolCallFromMap(Map<String, Object?> map) {
    final name = map['name'] as String?;
    if (name == null || name.trim().isEmpty) {
      return null;
    }

    final rawInput = map['input'];
    final input = rawInput is Map<String, Object?>
        ? rawInput
        : rawInput is Map
            ? Map<String, Object?>.from(rawInput)
            : const <String, Object?>{};
    final rawId = map['id'] as String?;
    final callId = rawId == null || rawId.trim().isEmpty
        ? 'call_${++_toolCallCounter}'
        : rawId.trim();

    return ClartCodeToolCall(
      id: callId,
      name: name.trim(),
      input: Map<String, Object?>.unmodifiable(input),
    );
  }

  String _buildToolResultPayload(
    ClartCodeToolCall toolCall,
    ClartCodeToolResult result,
  ) {
    return jsonEncode({
      'tool_call_id': toolCall.id,
      'tool': result.tool,
      'input': toolCall.input,
      'ok': result.ok,
      'output': result.output,
      'error_code': result.errorCode,
      'error_message': result.errorMessage,
      if (result.metadata != null) 'metadata': result.metadata,
    });
  }

  String _buildAssistantToolCallPayload(
    List<ClartCodeToolCall> toolCalls, {
    String? text,
  }) {
    return jsonEncode({
      if (text != null && text.trim().isNotEmpty) 'text': text,
      'tool_calls': toolCalls.map((toolCall) => toolCall.toJson()).toList(),
    });
  }

  void _persistSession() {
    if (!_options.persistSession) {
      return;
    }

    final snapshot = _buildSessionSnapshot();
    _sessionTitle = snapshot.title;
    _sessionTags = List<String>.from(snapshot.tags);
    _sessionStore.save(snapshot);
  }

  ClartCodeSessionSnapshot _buildSessionSnapshot() {
    return ClartCodeSessionSnapshot.build(
      id: _sessionId,
      provider: _config.provider.name,
      model: _config.model,
      history: _conversation.history,
      transcript: _conversation.transcript,
      createdAt: _createdAt,
      title: _sessionTitle,
      tags: _sessionTags,
    );
  }

  List<String> _normalizeTags(List<String> tags) {
    final normalized = <String>{};
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isNotEmpty) {
        normalized.add(trimmed);
      }
    }
    final ordered = normalized.toList()..sort();
    return List<String>.unmodifiable(ordered);
  }

  String _normalizeFailureOutput(
    RuntimeError error,
    String? terminalOutput,
  ) {
    final output = terminalOutput?.trim() ?? '';
    if (output.isNotEmpty) {
      return output;
    }
    return '[ERROR] ${error.message}';
  }

  String _normalizeSuccessOutput(String rawOutput) {
    final normalized = rawOutput.trim();
    return normalized.isEmpty ? '[empty-output]' : normalized;
  }

  ClartCodeToolContext _toolContext({
    required int turn,
    required String? model,
  }) {
    return ClartCodeToolContext(
      sessionId: _sessionId,
      cwd: _cwd,
      provider: _config.provider,
      turn: turn,
      model: model,
    );
  }

  RuntimeError _stoppedError() {
    return _buildCancelledRuntimeError(_stopReason);
  }

  RuntimeError _buildCancelledRuntimeError(String? reason) {
    final normalizedReason = reason?.trim();
    final message = normalizedReason == null ||
            normalizedReason.isEmpty ||
            normalizedReason == 'manual_stop' ||
            normalizedReason == 'manual_interrupt' ||
            normalizedReason == 'request cancelled'
        ? 'request cancelled by user'
        : 'request cancelled: $normalizedReason';
    return RuntimeError(
      code: RuntimeErrorCode.cancelled,
      message: message,
      source: 'sdk_agent',
      retriable: false,
    );
  }

  Future<ClartCodeSdkMessage> _finishWithError({
    required Stopwatch watch,
    required String prompt,
    required String? modelUsed,
    required int turns,
    required String subtype,
    required RuntimeError error,
    String? terminalOutput,
  }) async {
    final output = _normalizeFailureOutput(error, terminalOutput);
    _conversation.appendTranscriptMessages([
      TranscriptMessage.system(output),
    ]);
    _persistSession();
    watch.stop();
    final result = ClartCodePromptResult(
      sessionId: _sessionId,
      text: output,
      turns: turns,
      isError: true,
      messages: const [],
      model: modelUsed,
      error: error,
      durationMs: watch.elapsedMilliseconds,
    );
    if (error.code == RuntimeErrorCode.cancelled) {
      await _options.hooks.onCancelledTerminal?.call(
        ClartCodeCancelledTerminalEvent(
          sessionId: _sessionId,
          cwd: _cwd,
          provider: _config.provider,
          prompt: prompt,
          model: modelUsed,
          result: result,
          reason: _stopReason ?? 'request cancelled',
        ),
      );
    }
    await _options.hooks.onSessionEnd?.call(
      ClartCodeSessionEndEvent(
        sessionId: _sessionId,
        cwd: _cwd,
        provider: _config.provider,
        prompt: prompt,
        model: modelUsed,
        result: result,
      ),
    );
    return ClartCodeSdkMessage.result(
      sessionId: _sessionId,
      subtype: subtype,
      text: output,
      isError: true,
      model: modelUsed,
      turns: turns,
      error: error,
      durationMs: watch.elapsedMilliseconds,
    );
  }
}

@Deprecated('Use ClartCodeAgent instead.')
typedef ClatCodeAgent = ClartCodeAgent;

class _ProviderTurnResult {
  const _ProviderTurnResult({
    required this.turn,
    required this.deltas,
    required this.rawOutput,
    required this.output,
    required this.toolCalls,
    this.modelUsed,
    this.error,
    this.providerStateToken,
  });

  final int turn;
  final List<String> deltas;
  final String rawOutput;
  final String output;
  final List<QueryToolCall> toolCalls;
  final String? modelUsed;
  final RuntimeError? error;
  final String? providerStateToken;
}

class _QueuedAgentRun {
  _QueuedAgentRun({
    required this.prompt,
    required this.model,
    required this.cancellationSignal,
  });

  final String prompt;
  final String? model;
  final QueryCancellationSignal? cancellationSignal;
  final StreamController<ClartCodeSdkMessage> controller =
      StreamController<ClartCodeSdkMessage>();

  StreamSubscription<void>? _queueCancellationSub;
  bool _started = false;

  void attachQueueCancellation(Future<void> Function() onCancel) {
    final signal = cancellationSignal;
    if (signal == null) {
      return;
    }
    _queueCancellationSub = signal.onCancel.listen((_) {
      if (_started) {
        return;
      }
      unawaited(onCancel());
    });
  }

  void markStarted() {
    _started = true;
    unawaited(_queueCancellationSub?.cancel());
    _queueCancellationSub = null;
  }

  Future<void> close() async {
    await _queueCancellationSub?.cancel();
    _queueCancellationSub = null;
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}
