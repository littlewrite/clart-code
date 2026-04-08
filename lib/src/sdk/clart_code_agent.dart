import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../agents/agent_registry.dart';
import '../agents/load_agents_dir.dart';
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
import '../skills/bundled_skills.dart';
import '../skills/load_skills_dir.dart';
import '../skills/skill_models.dart';
import '../skills/skill_registry.dart';
import '../tools/agent_tool.dart';
import '../tools/mcp_tools.dart';
import '../tools/skill_tool.dart';
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
  ClartCodeReasoningEffort? _activeEffort;
  QueryCancellationController? _activeCancellationController;
  final Set<QueryCancellationController>
      _activeSubagentCancellationControllers = <QueryCancellationController>{};
  McpManager? _mcpManager;
  ClartCodeAgentRegistry? _agentRegistry;
  ClartCodeSkillRegistry? _skillRegistry;
  String? _parentSessionId;
  bool _runtimePrepared = false;
  final Queue<_QueuedAgentRun> _pendingRuns = Queue<_QueuedAgentRun>();
  bool _drainingRuns = false;
  StreamController<ClartCodeSdkMessage>? _activeQueryMessageController;
  int? _activeSkillToolTurn;

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

  List<String> get availableSkills =>
      skillDefinitions.map((skill) => skill.name).toList(growable: false);

  List<String> get availableAgents =>
      agentDefinitions.map((agent) => agent.name).toList(growable: false);

  List<ClartCodeToolDefinition> get toolDefinitions {
    final definitions = _runtime.toolExecutor.registry.all
        .map(ClartCodeToolDefinition.fromTool)
        .toList();
    definitions.sort((left, right) => left.name.compareTo(right.name));
    return List<ClartCodeToolDefinition>.unmodifiable(definitions);
  }

  List<ClartCodeSkillDefinition> get skillDefinitions {
    final definitions = _skillRegistry?.modelInvocable.toList() ?? const [];
    definitions.sort((left, right) => left.name.compareTo(right.name));
    return List<ClartCodeSkillDefinition>.unmodifiable(definitions);
  }

  List<ClartCodeAgentDefinition> get agentDefinitions {
    final definitions =
        (_agentRegistry?.all.toList() ?? _normalizedAgentDefinitions());
    definitions.sort((left, right) => left.name.compareTo(right.name));
    return List<ClartCodeAgentDefinition>.unmodifiable(definitions);
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
    if ((!_queryInProgress && _activeSubagentCancellationControllers.isEmpty) ||
        _stopRequested) {
      return;
    }
    _stopRequested = true;
    _stopReason = reason;
    _activeCancellationController?.cancel(reason);
    for (final controller
        in _activeSubagentCancellationControllers.toList(growable: false)) {
      controller.cancel(reason);
    }
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
        parentSessionId: _parentSessionId,
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
    ClartCodeReasoningEffort? effort,
    ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
    QueryCancellationSignal? cancellationSignal,
  }) async* {
    final run = _QueuedAgentRun(
      prompt: prompt,
      model: model,
      request: effort == null ? request : request.copyWith(effort: effort),
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
    ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
    QueryCancellationSignal? cancellationSignal,
  }) {
    final controller = StreamController<ClartCodeSdkMessage>();
    unawaited(() async {
      _activeQueryMessageController = controller;
      try {
        await _executeQueryInto(
          controller,
          prompt,
          model: model,
          request: request,
          cancellationSignal: cancellationSignal,
        );
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      } finally {
        if (identical(_activeQueryMessageController, controller)) {
          _activeQueryMessageController = null;
        }
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }());
    return controller.stream;
  }

  Future<void> _executeQueryInto(
    StreamController<ClartCodeSdkMessage> controller,
    String prompt, {
    String? model,
    ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
    QueryCancellationSignal? cancellationSignal,
  }) async {
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
      _emitToController(
        controller,
        ClartCodeSdkMessage.result(
          sessionId: _sessionId,
          subtype: 'error_runtime_init',
          text: '[ERROR] ${runtimeError.message}',
          isError: true,
          model: model ?? _config.model,
          turns: 0,
          error: runtimeError,
          durationMs: watch.elapsedMilliseconds,
        ),
      );
      return;
    }
    final submitter = PromptSubmitter(conversation: _conversation);
    final submission = submitter.submit(prompt, model: model ?? _config.model);
    final processed = _inputProcessor.process(submission);
    final definitions = toolDefinitions;
    final normalizedMaxTurns = _options.maxTurns < 1 ? 1 : _options.maxTurns;

    _emitToController(
      controller,
      ClartCodeSdkMessage.systemInit(
        sessionId: _sessionId,
        cwd: _cwd,
        model: model ?? _config.model,
        tools: availableTools,
        toolDefinitions: definitions,
      ),
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
      _emitToController(
        controller,
        ClartCodeSdkMessage.result(
          sessionId: _sessionId,
          subtype: 'error_invalid_input',
          text: output,
          isError: true,
          model: model ?? _config.model,
          turns: 0,
          error: error,
          durationMs: watch.elapsedMilliseconds,
        ),
      );
      return;
    }

    final userPrompt = processed.submission.raw;
    final selectedModel = model ?? _config.model;
    final selectedEffort = request.effort ?? _options.effort;
    final selectedSystemPrompt = _normalizedPromptText(request.systemPrompt) ??
        _normalizedPromptText(_options.systemPrompt);
    final selectedAppendSystemPrompt =
        _normalizedPromptText(request.appendSystemPrompt) ??
            _normalizedPromptText(_options.appendSystemPrompt);
    final selectedMaxTokens = request.maxTokens ?? _options.maxTokens;
    final selectedMaxBudgetUsd = request.maxBudgetUsd ?? _options.maxBudgetUsd;
    final selectedThinking = request.thinking ?? _options.thinking;
    final selectedJsonSchema = request.jsonSchema ?? _options.jsonSchema;
    final selectedOutputFormat = request.outputFormat ?? _options.outputFormat;
    final includePartialMessages =
        request.includePartialMessages ?? _options.includePartialMessages;
    final includeObservabilityMessages = request.includeObservabilityMessages ??
        _options.includeObservabilityMessages;
    _queryInProgress = true;
    _stopRequested = cancellationSignal?.isCancelled ?? false;
    _stopNotified = false;
    _stopReason = _stopRequested
        ? cancellationSignal?.reason ?? 'request cancelled'
        : null;
    _activeModel = selectedModel;
    _activeEffort = selectedEffort;
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
        parentSessionId: _parentSessionId,
      ),
    );

    var modelUsed = selectedModel;
    QueryUsage? cumulativeUsage;
    double? cumulativeCostUsd;
    final modelUsageByModel = <String, QueryModelUsage>{};
    _ActiveSkillState? activeSkill;
    var completedTurns = 0;
    Future<void> endActiveSkill({
      required String reason,
      required int endedTurn,
      required String? model,
      RuntimeError? error,
      String? text,
      int? durationMs,
    }) async {
      final current = activeSkill;
      if (current == null) {
        return;
      }
      activeSkill = null;
      if (_shouldEmitSkillTerminalMessage(reason)) {
        _emitToController(
          controller,
          _buildSkillTerminalMessage(
            activeSkill: current,
            reason: reason,
            endedTurn: endedTurn,
            model: model,
            error: error,
            text: text,
            durationMs: durationMs,
          ),
        );
      }
      await _emitSkillEndHook(
        prompt: userPrompt,
        activeSkill: current,
        model: model,
        effort: _skillRuntimeEffort(
          currentEffort: selectedEffort,
          activeSkill: current,
        ),
        endedTurn: endedTurn,
        reason: reason,
      );
    }

    try {
      for (var turn = 1; turn <= normalizedMaxTurns; turn++) {
        if (_stopRequested) {
          await endActiveSkill(
            reason: 'cancelled',
            endedTurn: completedTurns,
            model: modelUsed,
            error: _stoppedError(),
            text: '[STOPPED] request cancelled',
            durationMs: watch.elapsedMilliseconds,
          );
          final stoppedResult = await _finishWithError(
            watch: watch,
            prompt: userPrompt,
            modelUsed: modelUsed,
            turns: completedTurns,
            subtype: 'error_stopped',
            error: _stoppedError(),
            usage: cumulativeUsage,
            costUsd: cumulativeCostUsd,
            modelUsage: _modelUsageListFromMap(modelUsageByModel),
          );
          _emitToController(controller, stoppedResult);
          return;
        }

        completedTurns = turn;
        final effectiveToolDefinitions = _effectiveToolDefinitions(
          definitions,
          activeSkill,
        );
        final effectiveProviderToolDefinitions =
            _providerToolDefinitions(effectiveToolDefinitions);
        final effectiveTurnModel = _effectiveTurnModel(
          selectedModel,
          activeSkill,
        );
        final effectiveTurnEffort = _effectiveTurnEffort(
          selectedEffort,
          activeSkill,
        );
        _activeModel = effectiveTurnModel;
        _activeEffort = effectiveTurnEffort;
        _maybeEmitStatusMessage(
          controller,
          enabled: includeObservabilityMessages,
          status: 'running_model',
          model: effectiveTurnModel,
          turn: turn,
        );
        await _options.hooks.onModelTurnStart?.call(
          ClartCodeModelTurnStartEvent(
            sessionId: _sessionId,
            cwd: _cwd,
            provider: _config.provider,
            prompt: userPrompt,
            turn: turn,
            model: effectiveTurnModel,
            availableTools: effectiveToolDefinitions
                .map((tool) => tool.name)
                .toList(growable: false),
            parentSessionId: _parentSessionId,
          ),
        );
        final request = _buildToolLoopRequest(
          messages: providerStateToken == null
              ? workingMessages
              : pendingProviderMessages,
          model: effectiveTurnModel,
          systemPrompt: selectedSystemPrompt,
          appendSystemPrompt: selectedAppendSystemPrompt,
          maxTokens: selectedMaxTokens,
          maxBudgetUsd: selectedMaxBudgetUsd,
          thinking: selectedThinking,
          jsonSchema: selectedJsonSchema,
          outputFormat: selectedOutputFormat,
          includePartialMessages: includePartialMessages,
          includeObservabilityMessages: includeObservabilityMessages,
          toolDefinitions: effectiveToolDefinitions,
          providerToolDefinitions: effectiveProviderToolDefinitions,
          effort: effectiveTurnEffort,
          providerStateToken: providerStateToken,
          cancellationSignal: (_activeCancellationController =
                  QueryCancellationController())
              .signal,
        );
        final turnWatch = Stopwatch()..start();
        final previousProviderStateToken = providerStateToken;
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
        cumulativeUsage = QueryUsage.combine([
          cumulativeUsage,
          turnResult.usage,
        ]);
        cumulativeCostUsd = _sumNullableDouble(
          cumulativeCostUsd,
          turnResult.costUsd,
        );
        _recordModelUsage(
          modelUsageByModel,
          model: modelUsed,
          usage: turnResult.usage,
          costUsd: turnResult.costUsd,
        );

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
            usage: turnResult.usage,
            costUsd: turnResult.costUsd,
            parentSessionId: _parentSessionId,
          ),
        );

        if (includeObservabilityMessages) {
          for (final event in turnResult.observabilityEvents) {
            switch (event.type) {
              case ProviderStreamEventType.streamEvent:
                final payload = event.event;
                if (payload == null || payload.isEmpty) {
                  continue;
                }
                _emitToController(
                  controller,
                  ClartCodeSdkMessage.streamEvent(
                    sessionId: _sessionId,
                    event: payload,
                    model: event.model ?? modelUsed,
                    turn: turn,
                  ),
                );
                break;
              case ProviderStreamEventType.rateLimit:
                final info = event.rateLimitInfo;
                if (info == null) {
                  continue;
                }
                _emitToController(
                  controller,
                  ClartCodeSdkMessage.rateLimitEvent(
                    sessionId: _sessionId,
                    rateLimitInfo: info,
                    model: event.model ?? modelUsed,
                    turn: turn,
                  ),
                );
                break;
              case ProviderStreamEventType.textDelta:
              case ProviderStreamEventType.done:
              case ProviderStreamEventType.error:
                break;
            }
          }
        }

        if (includePartialMessages) {
          for (final delta in turnResult.deltas) {
            _emitToController(
              controller,
              ClartCodeSdkMessage.assistantDelta(
                sessionId: _sessionId,
                delta: delta,
                model: modelUsed,
                turn: turn,
              ),
            );
          }
        }

        if (turnResult.error != null) {
          await endActiveSkill(
            reason: turnResult.error!.code == RuntimeErrorCode.cancelled
                ? 'cancelled'
                : 'error',
            endedTurn: turn,
            model: modelUsed,
            error: turnResult.error!,
            text: turnResult.output,
            durationMs: watch.elapsedMilliseconds,
          );
          final terminal = await _finishWithError(
            watch: watch,
            prompt: userPrompt,
            modelUsed: modelUsed,
            turns: completedTurns,
            subtype: turnResult.error!.code == RuntimeErrorCode.cancelled
                ? 'error_stopped'
                : 'error_during_execution',
            error: turnResult.error!,
            usage: cumulativeUsage,
            costUsd: cumulativeCostUsd,
            modelUsage: _modelUsageListFromMap(modelUsageByModel),
            terminalOutput: turnResult.output,
          );
          _emitToController(controller, terminal);
          return;
        }

        final budgetError = _budgetExceededError(
          maxBudgetUsd: selectedMaxBudgetUsd,
          costUsd: cumulativeCostUsd,
        );
        if (budgetError != null) {
          await endActiveSkill(
            reason: 'error',
            endedTurn: turn,
            model: modelUsed,
            error: budgetError,
            text: _formatBudgetExceededOutput(
              error: budgetError,
              terminalOutput: turnResult.output,
            ),
            durationMs: watch.elapsedMilliseconds,
          );
          final terminal = await _finishWithError(
            watch: watch,
            prompt: userPrompt,
            modelUsed: modelUsed,
            turns: completedTurns,
            subtype: 'error_budget_exceeded',
            error: budgetError,
            usage: cumulativeUsage,
            costUsd: cumulativeCostUsd,
            modelUsage: _modelUsageListFromMap(modelUsageByModel),
            terminalOutput: _formatBudgetExceededOutput(
              error: budgetError,
              terminalOutput: turnResult.output,
            ),
          );
          _emitToController(controller, terminal);
          return;
        }

        final output = turnResult.output;
        final shouldEmitCompactBoundary = includeObservabilityMessages &&
            toolCalls.isNotEmpty &&
            _providerStateTokenChanged(
              previous: previousProviderStateToken,
              next: turnResult.providerStateToken,
            );
        if (shouldEmitCompactBoundary) {
          _maybeEmitStatusMessage(
            controller,
            enabled: true,
            status: 'compacting',
            model: modelUsed,
            turn: turn,
          );
          _emitToController(
            controller,
            ClartCodeSdkMessage.compactBoundary(
              sessionId: _sessionId,
              compactMetadata: _buildCompactBoundaryMetadata(
                turn: turn,
                toolCalls: toolCalls,
                previousProviderStateToken: previousProviderStateToken,
                nextProviderStateToken: turnResult.providerStateToken,
              ),
              model: modelUsed,
              turn: turn,
            ),
          );
        }
        if (toolCalls.isEmpty) {
          _conversation.appendHistoryMessages([
            ChatMessage(role: MessageRole.assistant, text: output),
          ]);
          _conversation.appendTranscriptMessages([
            TranscriptMessage.assistant(output),
          ]);
          _persistSession();
          watch.stop();
          await endActiveSkill(
            reason: 'query_end',
            endedTurn: turn,
            model: modelUsed,
          );
          _emitToController(
            controller,
            ClartCodeSdkMessage.assistant(
              sessionId: _sessionId,
              text: output,
              model: modelUsed,
              turn: turn,
            ),
          );
          final promptResult = ClartCodePromptResult(
            sessionId: _sessionId,
            text: output,
            turns: completedTurns,
            isError: false,
            messages: const [],
            model: modelUsed,
            durationMs: watch.elapsedMilliseconds,
            usage: cumulativeUsage,
            costUsd: cumulativeCostUsd,
            modelUsage: _modelUsageListFromMap(modelUsageByModel),
          );
          await _options.hooks.onSessionEnd?.call(
            ClartCodeSessionEndEvent(
              sessionId: _sessionId,
              cwd: _cwd,
              provider: _config.provider,
              prompt: userPrompt,
              model: modelUsed,
              result: promptResult,
              parentSessionId: _parentSessionId,
            ),
          );
          _emitToController(
            controller,
            ClartCodeSdkMessage.result(
              sessionId: _sessionId,
              subtype: 'success',
              text: output,
              isError: false,
              model: modelUsed,
              turns: completedTurns,
              durationMs: watch.elapsedMilliseconds,
              usage: cumulativeUsage,
              costUsd: cumulativeCostUsd,
              modelUsage: _modelUsageListFromMap(modelUsageByModel),
            ),
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
          _emitToController(
            controller,
            ClartCodeSdkMessage.toolCall(
              sessionId: _sessionId,
              toolCall: toolCall,
              model: modelUsed,
              turn: turn,
            ),
          );
        }
        _maybeEmitStatusMessage(
          controller,
          enabled: includeObservabilityMessages,
          status: 'running_tools',
          model: modelUsed,
          turn: turn,
        );

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
        final hasActiveSkillRestriction = (activeSkill?.allowedTools != null &&
                activeSkill!.allowedTools!.isNotEmpty) ||
            (activeSkill?.disallowedTools != null &&
                activeSkill!.disallowedTools!.isNotEmpty);
        final mayActivateSkillWithinBatch = invocations.any(
          (invocation) => invocation.name == 'skill',
        );
        final needsPermissionResolver = hasActiveSkillRestriction ||
            mayActivateSkillWithinBatch ||
            _options.canUseTool != null ||
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
                  final skillRestriction = await _resolveSkillRestriction(
                    activeSkill: activeSkill,
                    toolCall: toolCall,
                    context: context,
                  );
                  if (skillRestriction != null) {
                    return skillRestriction;
                  }
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
              _activeSkillToolTurn = turn;
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
            afterExecute: (invocation, result) async {
              try {
                final nextSkill = _skillStateFromToolResult(
                  result,
                  turn: turn,
                );
                if (nextSkill != null) {
                  if (activeSkill != null) {
                    await endActiveSkill(
                      reason: 'replaced_by_skill',
                      endedTurn: turn,
                      model: modelUsed,
                    );
                  }
                  activeSkill = nextSkill;
                  await _emitSkillActivationHook(
                    prompt: userPrompt,
                    activeSkill: nextSkill,
                    model: _skillRuntimeModel(
                      currentModel: modelUsed,
                      activeSkill: nextSkill,
                    ),
                    effort: _skillRuntimeEffort(
                      currentEffort: effectiveTurnEffort,
                      activeSkill: nextSkill,
                    ),
                  );
                }
              } finally {
                _activeSkillToolTurn = null;
              }
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
          _emitToController(
            controller,
            ClartCodeSdkMessage.toolResult(
              sessionId: _sessionId,
              toolResult: sdkResult,
              model: modelUsed,
              turn: turn,
            ),
          );
        }

        _persistSession();
      }

      await endActiveSkill(
        reason: 'max_turns_reached',
        endedTurn: completedTurns,
        model: modelUsed,
        error: RuntimeError(
          code: RuntimeErrorCode.unknown,
          message:
              'agent reached max turns ($normalizedMaxTurns) before producing a final assistant response',
          source: 'sdk_agent',
          retriable: false,
        ),
        text:
            '[ERROR] agent reached max turns ($normalizedMaxTurns) before producing a final assistant response',
        durationMs: watch.elapsedMilliseconds,
      );
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
        usage: cumulativeUsage,
        costUsd: cumulativeCostUsd,
        modelUsage: _modelUsageListFromMap(modelUsageByModel),
      );
      _emitToController(controller, terminal);
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
    ClartCodeReasoningEffort? effort,
    ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
    QueryCancellationSignal? cancellationSignal,
  }) async {
    final messages = <ClartCodeSdkMessage>[];
    await for (final message in query(
      prompt,
      model: model,
      effort: effort,
      request: request,
      cancellationSignal: cancellationSignal,
    )) {
      messages.add(message);
    }

    return _promptResultFromMessages(
      messages,
      fallbackModel: model ?? _config.model,
    );
  }

  ClartCodePromptResult _promptResultFromMessages(
    List<ClartCodeSdkMessage> messages, {
    required String? fallbackModel,
  }) {
    final result = messages.lastWhere(
      (message) => message.type == 'result',
      orElse: () => ClartCodeSdkMessage.result(
        sessionId: _sessionId,
        subtype: 'error_missing_result',
        text: 'Prompt completed without a terminal result.',
        isError: true,
        model: fallbackModel,
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
      usage: result.usage,
      costUsd: result.costUsd,
      modelUsage: result.modelUsage == null
          ? null
          : List<QueryModelUsage>.unmodifiable(result.modelUsage!),
    );
  }

  Future<ClartCodeSubagentResult> runSubagent(
    String prompt, {
    ClartCodeSubagentOptions options = const ClartCodeSubagentOptions(),
    QueryCancellationSignal? cancellationSignal,
  }) async {
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) {
      throw ArgumentError.value(
          prompt, 'prompt', 'subagent prompt cannot be empty');
    }

    final effectivePromptPrefix = options.promptPrefix?.trim();
    final effectivePrompt =
        effectivePromptPrefix == null || effectivePromptPrefix.isEmpty
            ? normalizedPrompt
            : '$effectivePromptPrefix\n\n$normalizedPrompt';
    final subagentName = _stringMetadata(options.name);
    final childAgent = ClartCodeAgent(
      _buildChildAgentOptions(
        model: options.model,
        effort: options.effort,
        allowedTools: options.allowedTools,
        disallowedTools: options.disallowedTools,
        inheritMcp: options.inheritMcp,
        inheritAgents: options.inheritAgents,
        inheritSkills: options.inheritSkills,
        inheritHooks: options.inheritHooks,
      ),
    );
    childAgent._parentSessionId = _sessionId;
    final linkedCancellationController = QueryCancellationController();
    _activeSubagentCancellationControllers.add(linkedCancellationController);
    StreamSubscription<void>? externalCancellationSub;
    if (cancellationSignal != null) {
      if (cancellationSignal.isCancelled) {
        linkedCancellationController.cancel(
          cancellationSignal.reason ?? 'request cancelled',
        );
      } else {
        externalCancellationSub = cancellationSignal.onCancel.listen((_) {
          linkedCancellationController.cancel(
            cancellationSignal.reason ?? 'request cancelled',
          );
        });
      }
    }
    if (_stopRequested) {
      linkedCancellationController.cancel(
        _stopReason ?? 'request cancelled',
      );
    }
    await _options.hooks.onSubagentStart?.call(
      ClartCodeSubagentStartEvent(
        parentSessionId: _sessionId,
        sessionId: childAgent.sessionId,
        cwd: childAgent.cwd,
        provider: _config.provider,
        prompt: effectivePrompt,
        name: subagentName,
        model: options.model ?? childAgent.model,
      ),
    );
    try {
      _maybeEmitLiveSubagentMessage(
        _buildSubagentCascadedStartMessage(
          sessionId: childAgent.sessionId,
          parentSessionId: _sessionId,
          prompt: effectivePrompt,
          name: subagentName,
          model: options.model ?? childAgent.model,
        ),
      );
      final messages = <ClartCodeSdkMessage>[];
      await for (final message in childAgent.query(
        effectivePrompt,
        model: options.model,
        cancellationSignal: linkedCancellationController.signal,
      )) {
        messages.add(message);
        _maybeEmitLiveSubagentMessage(
          _cascadeSubagentMessage(
            parentSessionId: _sessionId,
            name: subagentName,
            message: message,
            includeAssistantDeltas: options.cascadeAssistantDeltas,
          ),
        );
      }
      final result = childAgent._promptResultFromMessages(
        messages,
        fallbackModel: options.model ?? childAgent.model ?? _config.model,
      );
      final transcriptMessages = _buildSubagentTranscriptMessages(
        sessionId: childAgent.sessionId,
        parentSessionId: _sessionId,
        prompt: effectivePrompt,
        text: result.text,
        turns: result.turns,
        isError: result.isError,
        name: subagentName,
        model: result.model,
        error: result.error,
      );
      final cascadedMessages = _buildSubagentCascadedMessages(
        sessionId: childAgent.sessionId,
        parentSessionId: _sessionId,
        prompt: effectivePrompt,
        name: subagentName,
        model: result.model,
        messages: result.messages,
        includeAssistantDeltas: options.cascadeAssistantDeltas,
      );
      if (transcriptMessages.isNotEmpty) {
        _conversation.appendTranscriptMessages(transcriptMessages);
        _persistSession();
      }
      final subagentResult = ClartCodeSubagentResult(
        parentSessionId: _sessionId,
        sessionId: childAgent.sessionId,
        cwd: childAgent.cwd,
        prompt: effectivePrompt,
        text: result.text,
        turns: result.turns,
        isError: result.isError,
        messages: result.messages,
        cascadedMessages: List<ClartCodeSdkMessage>.unmodifiable(
          cascadedMessages,
        ),
        transcriptMessages:
            List<TranscriptMessage>.unmodifiable(transcriptMessages),
        name: subagentName,
        model: result.model,
        error: result.error,
        durationMs: result.durationMs,
        usage: result.usage,
        costUsd: result.costUsd,
        modelUsage: result.modelUsage,
      );
      await _options.hooks.onSubagentEnd?.call(
        ClartCodeSubagentEndEvent(
          parentSessionId: _sessionId,
          result: subagentResult,
          provider: _config.provider,
          name: subagentName,
          reason: linkedCancellationController.signal.reason,
        ),
      );
      return subagentResult;
    } finally {
      _activeSubagentCancellationControllers
          .remove(linkedCancellationController);
      linkedCancellationController.close();
      await externalCancellationSub?.cancel();
      await childAgent.close();
    }
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
              request: run.request,
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
        parentSessionId: _parentSessionId,
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
    _agentRegistry = null;
    _skillRegistry = null;
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
    if (_options.skills != null) {
      await _ensureSkillsLoaded(_options.skills!);
    }
    if (_options.agents != null) {
      await _ensureAgentsLoaded(_options.agents!);
    }
    if (_options.mcp != null) {
      await _ensureMcpToolsLoaded(_options.mcp!);
    }
    _runtimePrepared = true;
  }

  Future<void> _ensureAgentsLoaded(ClartCodeAgentsOptions options) async {
    final registry = options.registry?.copy() ?? ClartCodeAgentRegistry();
    registry.registerAll(_normalizedAgentDefinitions());

    for (final directory in options.directories) {
      final trimmed = directory.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      registry.registerAll(
        await loadAgentsDir(_resolveAgentPath(trimmed)),
      );
    }

    _agentRegistry = registry;
    final definitions = agentDefinitions;
    if (!options.enableTool ||
        definitions.isEmpty ||
        !_isToolEnabled('agent') ||
        _runtime.toolExecutor.registry.lookup('agent') != null) {
      return;
    }

    _runtime.toolExecutor.registry.register(
      AgentTool(
        agents: definitions,
        runner: _runNamedAgent,
      ),
    );
  }

  Future<void> _ensureSkillsLoaded(ClartCodeSkillsOptions options) async {
    final registry = options.registry?.copy() ?? ClartCodeSkillRegistry();
    if (options.includeBundledSkills) {
      initBundledSkills(registry);
    }
    registry.registerAll(options.skills);

    for (final directory in options.directories) {
      final trimmed = directory.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      registry.registerAll(
        await loadSkillsDir(_resolveAgentPath(trimmed)),
      );
    }

    _skillRegistry = registry;
    if (!options.enableTool ||
        registry.modelInvocable.isEmpty ||
        !_isToolEnabled('skill') ||
        _runtime.toolExecutor.registry.lookup('skill') != null) {
      return;
    }

    _runtime.toolExecutor.registry.register(
      SkillTool(
        registry: registry,
        cwd: _cwd,
        sessionId: _sessionId,
        provider: _config.provider,
        model: _activeModel ?? _config.model,
        effort: _options.effort,
        contextBuilder: _buildSkillToolContext,
        agentResolver: _lookupNamedAgentDefinition,
        agentDefinitionsBuilder: () => agentDefinitions,
        forkRunner: _runForkedSkill,
      ),
    );
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
    final sdkServers = options.sdkServers;
    final sdkServerNames = <String>{
      for (final server in sdkServers) server.name,
    };
    final registry = await manager.loadRegistry();

    for (final serverName in sdkServerNames) {
      if (registry.containsKey(serverName)) {
        throw ArgumentError(
          'duplicate MCP server name in registry and sdkServers: $serverName',
        );
      }
    }

    if (selectedServers == null || selectedServers.isEmpty) {
      for (final server in sdkServers) {
        await manager.connect(server);
      }
      await manager.connectAll();
      return;
    }

    final connectedSdkServers = <String>{};
    for (final serverName in selectedServers) {
      if (sdkServerNames.contains(serverName)) {
        if (connectedSdkServers.add(serverName)) {
          final server = sdkServers.firstWhere(
            (item) => item.name == serverName,
          );
          await manager.connect(server);
        }
        continue;
      }
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
    required String? systemPrompt,
    required String? appendSystemPrompt,
    required int? maxTokens,
    required double? maxBudgetUsd,
    required ClartCodeThinkingConfig? thinking,
    required ClartCodeJsonSchema? jsonSchema,
    required ClartCodeOutputFormat? outputFormat,
    required bool includePartialMessages,
    required bool includeObservabilityMessages,
    required ClartCodeReasoningEffort? effort,
    required List<ClartCodeToolDefinition> toolDefinitions,
    required List<QueryToolDefinition> providerToolDefinitions,
    required String? providerStateToken,
    required QueryCancellationSignal? cancellationSignal,
  }) {
    final useNativeToolCalling = _runtime.provider.supportsNativeToolCalling;
    final agentProtocolPrompt = _buildAgentProtocolPrompt();
    final skillProtocolPrompt = _buildSkillProtocolPrompt();
    final outputFormatPrompt = _buildOutputFormatPrompt(
      jsonSchema: jsonSchema,
      outputFormat: outputFormat,
    );
    return QueryRequest(
      messages: [
        if (agentProtocolPrompt != null)
          ChatMessage(
            role: MessageRole.system,
            text: agentProtocolPrompt,
          ),
        if (skillProtocolPrompt != null)
          ChatMessage(
            role: MessageRole.system,
            text: skillProtocolPrompt,
          ),
        if (toolDefinitions.isNotEmpty && !useNativeToolCalling)
          ChatMessage(
            role: MessageRole.system,
            text: _buildToolProtocolPrompt(toolDefinitions),
          ),
        if (outputFormatPrompt != null)
          ChatMessage(
            role: MessageRole.system,
            text: outputFormatPrompt,
          ),
        ...messages,
      ],
      maxTurns: _options.maxTurns,
      model: model,
      effort: effort,
      systemPrompt: systemPrompt,
      appendSystemPrompt: appendSystemPrompt,
      maxTokens: maxTokens,
      maxBudgetUsd: maxBudgetUsd,
      thinking: thinking,
      jsonSchema: jsonSchema,
      outputFormat: outputFormat,
      includePartialMessages: includePartialMessages,
      includeObservabilityMessages: includeObservabilityMessages,
      toolDefinitions:
          useNativeToolCalling ? providerToolDefinitions : const [],
      providerStateToken: useNativeToolCalling ? providerStateToken : null,
      cancellationSignal: cancellationSignal,
    );
  }

  String? _buildOutputFormatPrompt({
    required ClartCodeJsonSchema? jsonSchema,
    required ClartCodeOutputFormat? outputFormat,
  }) {
    if (jsonSchema != null) {
      final buffer = StringBuffer()
        ..writeln('Return valid JSON only.')
        ..writeln(
          'The final response must strictly match this JSON schema:',
        )
        ..write(jsonEncode(jsonSchema.schema));
      return buffer.toString();
    }
    if (outputFormat?.type == ClartCodeOutputFormatType.jsonObject) {
      return 'Return a valid JSON object only. Do not wrap it in markdown.';
    }
    return null;
  }

  String? _normalizedPromptText(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  void _recordModelUsage(
    Map<String, QueryModelUsage> usageByModel, {
    required String? model,
    QueryUsage? usage,
    double? costUsd,
  }) {
    final normalizedModel = model?.trim();
    if (normalizedModel == null || normalizedModel.isEmpty) {
      return;
    }
    final existing = usageByModel[normalizedModel];
    usageByModel[normalizedModel] = existing == null
        ? QueryModelUsage(
            model: normalizedModel,
            usage: usage,
            costUsd: costUsd,
          )
        : existing.merge(
            usage: usage,
            costUsd: costUsd,
          );
  }

  List<QueryModelUsage>? _modelUsageListFromMap(
    Map<String, QueryModelUsage> usageByModel,
  ) {
    if (usageByModel.isEmpty) {
      return null;
    }
    return List<QueryModelUsage>.unmodifiable(usageByModel.values);
  }

  double? _sumNullableDouble(double? left, double? right) {
    if (left == null) {
      return right;
    }
    if (right == null) {
      return left;
    }
    return left + right;
  }

  RuntimeError? _budgetExceededError({
    required double? maxBudgetUsd,
    required double? costUsd,
  }) {
    if (maxBudgetUsd == null || costUsd == null || costUsd <= maxBudgetUsd) {
      return null;
    }
    return RuntimeError(
      code: RuntimeErrorCode.budgetExceeded,
      message:
          'query exceeded maxBudgetUsd (\$${costUsd.toStringAsFixed(4)} > \$${maxBudgetUsd.toStringAsFixed(4)})',
      source: 'sdk_agent',
      retriable: false,
    );
  }

  String _formatBudgetExceededOutput({
    required RuntimeError error,
    required String? terminalOutput,
  }) {
    final output = terminalOutput?.trim() ?? '';
    if (output.isEmpty) {
      return '[ERROR] ${error.message}';
    }
    return '[ERROR] ${error.message}\n\nLast model output:\n$output';
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

  List<ClartCodeToolDefinition> _effectiveToolDefinitions(
    List<ClartCodeToolDefinition> allToolDefinitions,
    _ActiveSkillState? activeSkill,
  ) {
    final allowedTools = activeSkill?.allowedTools;
    final disallowedTools = activeSkill?.disallowedTools;
    var filtered = allToolDefinitions;
    if (allowedTools != null && allowedTools.isNotEmpty) {
      filtered = filtered
          .where((tool) => allowedTools.contains(tool.name))
          .toList(growable: false);
    }
    if (disallowedTools == null || disallowedTools.isEmpty) {
      return filtered;
    }
    return filtered
        .where((tool) => !disallowedTools.contains(tool.name))
        .toList(growable: false);
  }

  String? _effectiveTurnModel(
    String? selectedModel,
    _ActiveSkillState? activeSkill,
  ) {
    final override = activeSkill?.modelOverride?.trim();
    if (override == null || override.isEmpty) {
      return selectedModel;
    }
    return override;
  }

  ClartCodeReasoningEffort? _effectiveTurnEffort(
    ClartCodeReasoningEffort? selectedEffort,
    _ActiveSkillState? activeSkill,
  ) {
    return activeSkill?.effortOverride ?? selectedEffort;
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

  Future<ToolPermissionResolution?> _resolveSkillRestriction({
    required _ActiveSkillState? activeSkill,
    required ClartCodeToolCall toolCall,
    required ClartCodeToolContext context,
  }) async {
    final disallowedTools = activeSkill?.disallowedTools;
    if (disallowedTools != null &&
        disallowedTools.isNotEmpty &&
        disallowedTools.contains(toolCall.name)) {
      final message =
          'tool "${toolCall.name}" is not allowed while skill "${activeSkill!.name}" is active';
      final hook = _options.hooks.onToolPermissionDecision;
      if (hook != null) {
        await Future<void>.value(
          hook(
            ClartCodeToolPermissionEvent(
              context: context,
              toolCall: toolCall,
              decision: ClartCodeToolPermissionDecision.deny,
              source: ClartCodeToolPermissionSource.skill,
              message: message,
            ),
          ),
        );
      }
      return ToolPermissionResolution.deny(message: message);
    }

    final allowedTools = activeSkill?.allowedTools;
    if (allowedTools == null || allowedTools.isEmpty) {
      return null;
    }
    if (allowedTools.contains(toolCall.name)) {
      return null;
    }

    final message =
        'tool "${toolCall.name}" is not allowed while skill "${activeSkill!.name}" is active';
    final hook = _options.hooks.onToolPermissionDecision;
    if (hook != null) {
      await Future<void>.value(
        hook(
          ClartCodeToolPermissionEvent(
            context: context,
            toolCall: toolCall,
            decision: ClartCodeToolPermissionDecision.deny,
            source: ClartCodeToolPermissionSource.skill,
            message: message,
          ),
        ),
      );
    }
    return ToolPermissionResolution.deny(message: message);
  }

  _ActiveSkillState? _skillStateFromToolResult(
    ToolExecutionResult result, {
    required int turn,
  }) {
    final state = _skillStateFromToolResultBase(result);
    if (state == null) {
      return null;
    }
    return state.copyWith(activatedTurn: turn);
  }

  _ActiveSkillState? _skillStateFromToolResultBase(ToolExecutionResult result) {
    if (!result.ok || result.tool != 'skill') {
      return null;
    }
    final metadata = result.metadata;
    if (metadata == null) {
      return null;
    }
    if (_stringMetadata(metadata['status']) != 'inline') {
      return null;
    }

    final name = _stringMetadata(metadata['resolved_name']) ??
        _stringMetadata(metadata['skill']);
    if (name == null || name.isEmpty) {
      return null;
    }

    final allowedTools = _stringListMetadata(metadata['allowed_tools']);
    final disallowedTools = _stringListMetadata(metadata['disallowed_tools']);
    final normalizedAllowedTools = allowedTools == null || allowedTools.isEmpty
        ? <String>[]
        : <String>{
            ...allowedTools,
            if (_runtime.toolExecutor.registry.lookup('skill') != null) 'skill',
          }.where((tool) => tool.trim().isNotEmpty).toList()
      ..sort();
    final normalizedDisallowedTools = <String>{
      ...?disallowedTools,
    }
        .where(
          (tool) => tool.trim().isNotEmpty && tool != 'skill',
        )
        .toList()
      ..sort();

    return _ActiveSkillState(
      name: name,
      allowedTools: normalizedAllowedTools.isEmpty
          ? null
          : Set<String>.unmodifiable(normalizedAllowedTools.toSet()),
      disallowedTools: normalizedDisallowedTools.isEmpty
          ? null
          : Set<String>.unmodifiable(normalizedDisallowedTools.toSet()),
      modelOverride: _stringMetadata(metadata['model']),
      effortOverride: _reasoningEffortMetadata(metadata['effort']),
      runtimeScope:
          _stringMetadata(metadata['runtime_scope']) ?? 'current_query',
      cleanupBoundary:
          _stringMetadata(metadata['cleanup_boundary']) ?? 'query_end',
      activatedTurn: 0,
    );
  }

  String? _buildSkillProtocolPrompt() {
    if (_runtime.toolExecutor.registry.lookup('skill') == null) {
      return null;
    }

    final skills = skillDefinitions;
    if (skills.isEmpty) {
      return null;
    }

    final buffer = StringBuffer()
      ..writeln(
          'You may use the skill tool when a specialized workflow matches the user request.')
      ..writeln(
        'If one of the listed skills is clearly relevant, call the skill tool before continuing the task.',
      )
      ..writeln('Available skills:');

    for (final skill in skills) {
      buffer.write('- ${skill.name}: ${skill.description}');
      if (skill.whenToUse != null && skill.whenToUse!.trim().isNotEmpty) {
        buffer.write(' Trigger when: ${skill.whenToUse!.trim()}');
      }
      if (skill.argumentHint != null && skill.argumentHint!.trim().isNotEmpty) {
        buffer.write(' Args: ${skill.argumentHint!.trim()}');
      }
      if (skill.effort != null) {
        buffer.write(' Effort: ${skill.effort!.name}');
      }
      buffer.writeln();
    }

    return buffer.toString().trimRight();
  }

  String? _buildAgentProtocolPrompt() {
    if (_runtime.toolExecutor.registry.lookup('agent') == null) {
      return null;
    }

    final definitions = agentDefinitions;
    if (definitions.isEmpty) {
      return null;
    }

    final buffer = StringBuffer()
      ..writeln(
          'You may use the agent tool to delegate a focused subtask to a named subagent.')
      ..writeln(
        'Only delegate when one of the listed agents is clearly a good fit for the task.',
      )
      ..writeln('Available agents:');

    for (final agent in definitions) {
      buffer.write('- ${agent.name}: ${agent.description}');
      final model = agent.model?.trim();
      if (model != null && model.isNotEmpty) {
        buffer.write(' Model: $model');
      }
      if (agent.effort != null) {
        buffer.write(' Effort: ${agent.effort!.name}');
      }
      final allowedTools = agent.allowedTools;
      if (allowedTools != null && allowedTools.isNotEmpty) {
        buffer.write(' Tools: ${allowedTools.join(', ')}');
      }
      buffer.writeln();
    }

    return buffer.toString().trimRight();
  }

  Future<_ProviderTurnResult> _runProviderTurn({
    required QueryRequest request,
    required int turn,
  }) async {
    final deltas = <String>[];
    final observabilityEvents = <_ProviderObservabilityEvent>[];
    final outputBuffer = StringBuffer();
    var toolCalls = const <QueryToolCall>[];
    RuntimeError? terminalError;
    String? terminalOutput;
    String? modelUsed = request.model;
    String? providerStateToken;
    QueryUsage? usage;
    double? costUsd;

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
          usage = event.usage;
          costUsd = event.costUsd;
          providerStateToken = event.providerStateToken;
          break;
        case ProviderStreamEventType.error:
          terminalError = event.error;
          terminalOutput = event.output ?? outputBuffer.toString();
          toolCalls = event.toolCalls;
          usage = event.usage;
          costUsd = event.costUsd;
          providerStateToken = event.providerStateToken;
          break;
        case ProviderStreamEventType.streamEvent:
        case ProviderStreamEventType.rateLimit:
          observabilityEvents.add(
            _ProviderObservabilityEvent(
              type: event.type,
              model: event.model,
              event: event.event,
              rateLimitInfo: event.rateLimitInfo,
            ),
          );
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
      usage: usage,
      costUsd: costUsd,
      providerStateToken: providerStateToken,
      observabilityEvents: observabilityEvents,
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

  void _maybeEmitStatusMessage(
    StreamController<ClartCodeSdkMessage> controller, {
    required bool enabled,
    required String status,
    required String? model,
    required int turn,
  }) {
    if (!enabled) {
      return;
    }
    _emitToController(
      controller,
      ClartCodeSdkMessage.systemStatus(
        sessionId: _sessionId,
        status: status,
        model: model,
        turn: turn,
      ),
    );
  }

  bool _providerStateTokenChanged({
    required String? previous,
    required String? next,
  }) {
    final normalizedNext = next?.trim();
    if (normalizedNext == null || normalizedNext.isEmpty) {
      return false;
    }
    final normalizedPrevious = previous?.trim();
    return normalizedPrevious != normalizedNext;
  }

  Map<String, Object?> _buildCompactBoundaryMetadata({
    required int turn,
    required List<ClartCodeToolCall> toolCalls,
    required String? previousProviderStateToken,
    required String? nextProviderStateToken,
  }) {
    return {
      'reason': 'provider_state_token',
      'scope': 'provider_managed_context',
      'next_turn': turn + 1,
      'tool_call_count': toolCalls.length,
      if (previousProviderStateToken != null &&
          previousProviderStateToken.trim().isNotEmpty)
        'previous_provider_state_token': previousProviderStateToken,
      if (nextProviderStateToken != null &&
          nextProviderStateToken.trim().isNotEmpty)
        'provider_state_token': nextProviderStateToken,
    };
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
      parentSessionId: _parentSessionId,
    );
  }

  ClartCodeSkillContext _buildSkillToolContext() {
    return ClartCodeSkillContext(
      cwd: _cwd,
      sessionId: _sessionId,
      provider: _config.provider,
      model: _activeModel ?? _config.model,
      effort: _activeEffort ?? _options.effort,
      turn: _activeSkillToolTurn,
    );
  }

  String? _skillRuntimeModel({
    required String? currentModel,
    required _ActiveSkillState activeSkill,
  }) {
    final override = activeSkill.modelOverride?.trim();
    if (override == null || override.isEmpty) {
      return currentModel;
    }
    return override;
  }

  ClartCodeReasoningEffort? _skillRuntimeEffort({
    required ClartCodeReasoningEffort? currentEffort,
    required _ActiveSkillState activeSkill,
  }) {
    return activeSkill.effortOverride ?? currentEffort;
  }

  Future<void> _emitSkillActivationHook({
    required String prompt,
    required _ActiveSkillState activeSkill,
    required String? model,
    required ClartCodeReasoningEffort? effort,
  }) async {
    await _options.hooks.onSkillActivation?.call(
      ClartCodeSkillActivationEvent(
        sessionId: _sessionId,
        cwd: _cwd,
        provider: _config.provider,
        prompt: prompt,
        turn: activeSkill.activatedTurn,
        name: activeSkill.name,
        runtimeScope: activeSkill.runtimeScope,
        cleanupBoundary: activeSkill.cleanupBoundary,
        model: model,
        effort: effort,
        allowedTools: activeSkill.allowedTools?.toList(growable: false),
        disallowedTools: activeSkill.disallowedTools?.toList(growable: false),
        parentSessionId: _parentSessionId,
      ),
    );
  }

  Future<void> _emitSkillEndHook({
    required String prompt,
    required _ActiveSkillState activeSkill,
    required String? model,
    required ClartCodeReasoningEffort? effort,
    required int endedTurn,
    required String reason,
  }) async {
    await _options.hooks.onSkillEnd?.call(
      ClartCodeSkillEndEvent(
        sessionId: _sessionId,
        cwd: _cwd,
        provider: _config.provider,
        prompt: prompt,
        name: activeSkill.name,
        activatedTurn: activeSkill.activatedTurn,
        endedTurn: endedTurn,
        reason: reason,
        runtimeScope: activeSkill.runtimeScope,
        cleanupBoundary: activeSkill.cleanupBoundary,
        model: model,
        effort: effort,
        allowedTools: activeSkill.allowedTools?.toList(growable: false),
        disallowedTools: activeSkill.disallowedTools?.toList(growable: false),
        parentSessionId: _parentSessionId,
      ),
    );
  }

  bool _shouldEmitSkillTerminalMessage(String reason) {
    // Keep normal inline-skill lifecycle (`query_end` / `replaced_by_skill`)
    // on hooks only. The query stream only gets a minimal synthetic
    // `skill/end` when an active skill is being torn down by an abnormal
    // terminal path, so the public stream surface stays close to the TS SDK.
    return reason == 'cancelled' ||
        reason == 'error' ||
        reason == 'max_turns_reached';
  }

  ClartCodeSdkMessage _buildSkillTerminalMessage({
    required _ActiveSkillState activeSkill,
    required String reason,
    required int endedTurn,
    required String? model,
    RuntimeError? error,
    String? text,
    int? durationMs,
  }) {
    return ClartCodeSdkMessage.skill(
      sessionId: _sessionId,
      subtype: 'end',
      terminalSubtype: reason,
      skillName: activeSkill.name,
      text: text,
      model: model,
      turn: endedTurn,
      isError: true,
      error: error,
      durationMs: durationMs,
    );
  }

  String _resolveAgentPath(String path) {
    if (_isAbsolutePath(path)) {
      return path;
    }
    return '$_cwd/$path';
  }

  bool _isAbsolutePath(String path) {
    if (path.startsWith(Platform.pathSeparator)) {
      return true;
    }
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path);
  }

  String? _stringMetadata(Object? value) {
    if (value is! String) {
      return null;
    }
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  List<String>? _stringListMetadata(Object? value) {
    if (value is! List) {
      return null;
    }
    final normalized = value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return normalized;
  }

  ClartCodeReasoningEffort? _reasoningEffortMetadata(Object? value) {
    return parseClartCodeReasoningEffort(value);
  }

  ClartCodeAgentDefinition? _lookupNamedAgentDefinition(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return null;
    }
    for (final definition in agentDefinitions) {
      if (definition.name == normalized) {
        return definition;
      }
    }
    return null;
  }

  Future<SkillForkExecutionResult> _runForkedSkill(
    ClartCodeSkillDefinition skill,
    String args,
    String promptText,
    ClartCodeSkillContext context, {
    ClartCodeAgentDefinition? agentDefinition,
  }) async {
    final allowedTools = skill.allowedTools.isEmpty
        ? agentDefinition?.allowedTools
        : skill.allowedTools;
    final disallowedTools = _mergeToolNames(
      agentDefinition?.disallowedTools,
      skill.disallowedTools,
    );
    final result = await runSubagent(
      promptText,
      options: ClartCodeSubagentOptions(
        name: skill.name,
        model: skill.model ??
            agentDefinition?.model ??
            context.model ??
            _config.model,
        effort: skill.effort ?? agentDefinition?.effort ?? context.effort,
        allowedTools: allowedTools,
        disallowedTools: disallowedTools,
        promptPrefix: agentDefinition?.prompt,
        inheritMcp: agentDefinition?.inheritMcp ?? true,
        inheritSkills: false,
        inheritHooks: false,
        cascadeAssistantDeltas: skill.cascadeAssistantDeltas ||
            (agentDefinition?.cascadeAssistantDeltas ?? false),
      ),
    );
    return SkillForkExecutionResult(
      output: result.text,
      turns: result.turns,
      isError: result.isError,
      cascadedMessages: result.cascadedMessages,
      name: result.name,
      model: result.model,
      sessionId: result.sessionId,
      parentSessionId: result.parentSessionId,
      errorCode: result.error?.code.name,
      errorMessage: result.error?.message,
    );
  }

  List<String>? _mergeToolNames(List<String>? base, List<String>? extra) {
    final merged = [
      ...?base,
      ...?extra,
    ];
    if (merged.isEmpty) {
      return null;
    }
    return _normalizeToolNames(merged);
  }

  List<TranscriptMessage> _buildSubagentTranscriptMessages({
    required String sessionId,
    required String parentSessionId,
    required String prompt,
    required String text,
    required int turns,
    required bool isError,
    required String? name,
    required String? model,
    RuntimeError? error,
  }) {
    final label = name == null ? 'Subagent' : 'Subagent "$name"';
    final lines = <String>[
      '$label ${isError ? 'failed' : 'completed'}.',
      'session_id: $sessionId',
      'turns: $turns',
      if (model != null && model.trim().isNotEmpty) 'model: $model',
      'prompt:',
      prompt,
      'output:',
      text,
    ];
    if (error != null) {
      lines.insert(
        3,
        'error: ${error.code.name}${error.message.trim().isEmpty ? '' : ' - ${error.message}'}',
      );
    }
    return [
      TranscriptMessage.subagent(
        lines.join('\n'),
        sessionId: sessionId,
        parentSessionId: parentSessionId,
        name: name,
      ),
    ];
  }

  List<ClartCodeSdkMessage> _buildSubagentCascadedMessages({
    required String sessionId,
    required String parentSessionId,
    required String prompt,
    required String? name,
    required String? model,
    required List<ClartCodeSdkMessage> messages,
    required bool includeAssistantDeltas,
  }) {
    final cascaded = <ClartCodeSdkMessage>[
      _buildSubagentCascadedStartMessage(
        sessionId: sessionId,
        parentSessionId: parentSessionId,
        prompt: prompt,
        name: name,
        model: model,
      ),
    ];
    for (final message in messages) {
      final cascadedMessage = _cascadeSubagentMessage(
        parentSessionId: parentSessionId,
        name: name,
        message: message,
        includeAssistantDeltas: includeAssistantDeltas,
      );
      if (cascadedMessage == null) {
        continue;
      }
      cascaded.add(cascadedMessage);
    }
    return cascaded;
  }

  void _emitToController(
    StreamController<ClartCodeSdkMessage>? controller,
    ClartCodeSdkMessage message,
  ) {
    if (controller == null || controller.isClosed) {
      return;
    }
    controller.add(message);
  }

  void _maybeEmitLiveSubagentMessage(ClartCodeSdkMessage? message) {
    if (message == null) {
      return;
    }
    _emitToController(_activeQueryMessageController, message);
  }

  ClartCodeSdkMessage _buildSubagentCascadedStartMessage({
    required String sessionId,
    required String parentSessionId,
    required String prompt,
    required String? name,
    required String? model,
  }) {
    return ClartCodeSdkMessage.subagent(
      sessionId: sessionId,
      parentSessionId: parentSessionId,
      subtype: 'start',
      text: prompt,
      model: model,
      subagentName: name,
    );
  }

  ClartCodeSdkMessage _buildSubagentCascadedEndMessage({
    required String parentSessionId,
    required String? name,
    required ClartCodeSdkMessage terminalMessage,
  }) {
    return ClartCodeSdkMessage.subagent(
      sessionId: terminalMessage.sessionId,
      parentSessionId: parentSessionId,
      subtype: 'end',
      terminalSubtype: terminalMessage.subtype,
      text: terminalMessage.text,
      model: terminalMessage.model,
      subagentName: name,
      turns: terminalMessage.turns,
      isError: terminalMessage.isError,
      error: terminalMessage.error,
      durationMs: terminalMessage.durationMs,
    );
  }

  ClartCodeSdkMessage? _cascadeSubagentMessage({
    required String parentSessionId,
    required String? name,
    required ClartCodeSdkMessage message,
    required bool includeAssistantDeltas,
  }) {
    if (message.type == 'assistant_delta' && !includeAssistantDeltas) {
      return null;
    }
    if (message.type == 'result') {
      return _buildSubagentCascadedEndMessage(
        parentSessionId: parentSessionId,
        name: name,
        terminalMessage: message,
      );
    }
    return ClartCodeSdkMessage(
      type: message.type,
      sessionId: message.sessionId,
      subtype: message.subtype,
      text: message.text,
      delta: message.delta,
      model: message.model,
      turn: message.turn,
      turns: message.turns,
      isError: message.isError,
      error: message.error,
      cwd: message.cwd,
      tools: message.tools,
      toolDefinitions: message.toolDefinitions,
      toolCall: message.toolCall,
      toolResult: message.toolResult,
      durationMs: message.durationMs,
      parentSessionId: parentSessionId,
      subagentName: name,
    );
  }

  List<ClartCodeAgentDefinition> _normalizedAgentDefinitions() {
    final rawDefinitions = _options.agents?.agents ?? const [];
    if (rawDefinitions.isEmpty) {
      return const [];
    }

    final byName = <String, ClartCodeAgentDefinition>{};
    for (final definition in rawDefinitions) {
      final name = definition.name.trim();
      if (name.isEmpty) {
        throw ArgumentError('agent definition name cannot be empty');
      }
      if (byName.containsKey(name)) {
        throw ArgumentError('duplicate agent definition name: $name');
      }
      if (definition.description.trim().isEmpty) {
        throw ArgumentError('agent "$name" description cannot be empty');
      }
      if (definition.prompt.trim().isEmpty) {
        throw ArgumentError('agent "$name" prompt cannot be empty');
      }
      byName[name] = ClartCodeAgentDefinition(
        name: name,
        description: definition.description.trim(),
        prompt: definition.prompt.trim(),
        allowedTools: definition.allowedTools == null
            ? null
            : _normalizeToolNames(definition.allowedTools!),
        disallowedTools: _normalizeToolNames(definition.disallowedTools),
        model: _stringMetadata(definition.model),
        effort: definition.effort,
        inheritMcp: definition.inheritMcp,
        cascadeAssistantDeltas: definition.cascadeAssistantDeltas,
      );
    }

    return byName.values.toList(growable: false);
  }

  List<String> _normalizeToolNames(List<String> tools) {
    final normalized = tools
        .map((tool) => tool.trim())
        .where((tool) => tool.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return List<String>.unmodifiable(normalized);
  }

  Future<AgentExecutionResult> _runNamedAgent(
    ClartCodeAgentDefinition definition,
    String prompt, {
    String? model,
  }) async {
    final result = await runSubagent(
      prompt,
      options: ClartCodeSubagentOptions(
        name: definition.name,
        model: model ?? definition.model ?? _config.model,
        effort: definition.effort ?? _options.effort,
        allowedTools: definition.allowedTools,
        disallowedTools: definition.disallowedTools,
        promptPrefix: definition.prompt,
        inheritMcp: definition.inheritMcp,
        inheritAgents: false,
        inheritSkills: false,
        inheritHooks: false,
        cascadeAssistantDeltas: definition.cascadeAssistantDeltas,
      ),
    );
    return AgentExecutionResult(
      output: result.text,
      turns: result.turns,
      isError: result.isError,
      cascadedMessages: result.cascadedMessages,
      name: result.name,
      model: result.model,
      sessionId: result.sessionId,
      parentSessionId: result.parentSessionId,
      errorCode: result.error?.code.name,
      errorMessage: result.error?.message,
    );
  }

  ClartCodeAgentOptions _buildChildAgentOptions({
    String? model,
    ClartCodeReasoningEffort? effort,
    List<String>? allowedTools,
    List<String>? disallowedTools,
    required bool inheritMcp,
    required bool inheritAgents,
    required bool inheritSkills,
    required bool inheritHooks,
  }) {
    return ClartCodeAgentOptions(
      provider: _options.provider,
      model: model ?? _config.model,
      effort: effort ?? _options.effort,
      claudeApiKey: _options.claudeApiKey,
      claudeBaseUrl: _options.claudeBaseUrl,
      openAiApiKey: _options.openAiApiKey,
      openAiBaseUrl: _options.openAiBaseUrl,
      cwd: _cwd,
      persistSession: false,
      providerOverride: _options.providerOverride,
      toolExecutor: _options.toolExecutor,
      tools: _options.tools,
      allowedTools: allowedTools ?? _options.allowedTools,
      disallowedTools: disallowedTools ?? _options.disallowedTools,
      permissionMode: _options.permissionMode,
      maxTurns: _options.maxTurns,
      systemPrompt: _options.systemPrompt,
      appendSystemPrompt: _options.appendSystemPrompt,
      maxTokens: _options.maxTokens,
      maxBudgetUsd: _options.maxBudgetUsd,
      thinking: _options.thinking,
      jsonSchema: _options.jsonSchema,
      outputFormat: _options.outputFormat,
      includePartialMessages: _options.includePartialMessages,
      includeObservabilityMessages: _options.includeObservabilityMessages,
      permissionPolicy: _options.permissionPolicy,
      telemetry: _options.telemetry,
      securityGuard: _options.securityGuard,
      canUseTool: _options.canUseTool,
      resolveToolPermission: _options.resolveToolPermission,
      hooks: inheritHooks ? _options.hooks : const ClartCodeAgentHooks(),
      mcp: inheritMcp ? _options.mcp : null,
      agents: inheritAgents ? _options.agents : null,
      skills: inheritSkills ? _options.skills : null,
      mcpManagerOverride: _options.mcpManagerOverride,
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
    QueryUsage? usage,
    double? costUsd,
    List<QueryModelUsage>? modelUsage,
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
      usage: usage,
      costUsd: costUsd,
      modelUsage: modelUsage == null
          ? null
          : List<QueryModelUsage>.unmodifiable(modelUsage),
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
          parentSessionId: _parentSessionId,
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
        parentSessionId: _parentSessionId,
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
      usage: usage,
      costUsd: costUsd,
      modelUsage: modelUsage,
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
    this.usage,
    this.costUsd,
    this.providerStateToken,
    this.observabilityEvents = const [],
  });

  final int turn;
  final List<String> deltas;
  final String rawOutput;
  final String output;
  final List<QueryToolCall> toolCalls;
  final String? modelUsed;
  final RuntimeError? error;
  final QueryUsage? usage;
  final double? costUsd;
  final String? providerStateToken;
  final List<_ProviderObservabilityEvent> observabilityEvents;
}

class _ProviderObservabilityEvent {
  const _ProviderObservabilityEvent({
    required this.type,
    this.model,
    this.event,
    this.rateLimitInfo,
  });

  final ProviderStreamEventType type;
  final String? model;
  final Map<String, Object?>? event;
  final QueryRateLimitInfo? rateLimitInfo;
}

class _ActiveSkillState {
  const _ActiveSkillState({
    required this.name,
    required this.runtimeScope,
    required this.cleanupBoundary,
    required this.activatedTurn,
    this.allowedTools,
    this.disallowedTools,
    this.modelOverride,
    this.effortOverride,
  });

  final String name;
  final String runtimeScope;
  final String cleanupBoundary;
  final int activatedTurn;
  final Set<String>? allowedTools;
  final Set<String>? disallowedTools;
  final String? modelOverride;
  final ClartCodeReasoningEffort? effortOverride;

  _ActiveSkillState copyWith({
    String? name,
    String? runtimeScope,
    String? cleanupBoundary,
    int? activatedTurn,
    Set<String>? allowedTools,
    Set<String>? disallowedTools,
    String? modelOverride,
    ClartCodeReasoningEffort? effortOverride,
  }) {
    return _ActiveSkillState(
      name: name ?? this.name,
      runtimeScope: runtimeScope ?? this.runtimeScope,
      cleanupBoundary: cleanupBoundary ?? this.cleanupBoundary,
      activatedTurn: activatedTurn ?? this.activatedTurn,
      allowedTools: allowedTools ?? this.allowedTools,
      disallowedTools: disallowedTools ?? this.disallowedTools,
      modelOverride: modelOverride ?? this.modelOverride,
      effortOverride: effortOverride ?? this.effortOverride,
    );
  }
}

class _QueuedAgentRun {
  _QueuedAgentRun({
    required this.prompt,
    required this.model,
    required this.request,
    required this.cancellationSignal,
  });

  final String prompt;
  final String? model;
  final ClartCodeRequestOptions request;
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
