import 'clart_code_agent.dart';
import 'sdk_models.dart';
import 'session_store.dart';
import '../core/models.dart';
import '../core/transcript.dart';

Stream<ClartCodeSdkMessage> query({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  ClartCodeReasoningEffort? effort,
  ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
  QueryCancellationSignal? cancellationSignal,
}) async* {
  final agent = ClartCodeAgent(options);
  try {
    yield* agent.query(
      prompt,
      model: model,
      effort: effort,
      request: request,
      cancellationSignal: cancellationSignal,
    );
  } finally {
    await agent.close();
  }
}

Future<ClartCodePromptResult> prompt({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  ClartCodeReasoningEffort? effort,
  ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
  QueryCancellationSignal? cancellationSignal,
}) async {
  final agent = ClartCodeAgent(options);
  try {
    return await agent.prompt(
      prompt,
      model: model,
      effort: effort,
      request: request,
      cancellationSignal: cancellationSignal,
    );
  } finally {
    await agent.close();
  }
}

Stream<ClartCodeSdkMessage> continueLatestQuery({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  ClartCodeReasoningEffort? effort,
  ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
  QueryCancellationSignal? cancellationSignal,
}) {
  final latest = latestSession(cwd: options.cwd);
  return query(
    prompt: prompt,
    options:
        latest == null ? options : options.copyWith(resumeSessionId: latest.id),
    model: model,
    effort: effort,
    request: request,
    cancellationSignal: cancellationSignal,
  );
}

Future<ClartCodePromptResult> continueLatestPrompt({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  ClartCodeReasoningEffort? effort,
  ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
  QueryCancellationSignal? cancellationSignal,
}) {
  final latest = latestSession(cwd: options.cwd);
  return _promptHelper(
    promptText: prompt,
    options:
        latest == null ? options : options.copyWith(resumeSessionId: latest.id),
    model: model,
    effort: effort,
    request: request,
    cancellationSignal: cancellationSignal,
  );
}

Stream<ClartCodeSdkMessage> continueActiveQuery({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  ClartCodeReasoningEffort? effort,
  ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
  QueryCancellationSignal? cancellationSignal,
}) {
  final active = activeSession(cwd: options.cwd);
  return query(
    prompt: prompt,
    options:
        active == null ? options : options.copyWith(resumeSessionId: active.id),
    model: model,
    effort: effort,
    request: request,
    cancellationSignal: cancellationSignal,
  );
}

Future<ClartCodePromptResult> continueActivePrompt({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  ClartCodeReasoningEffort? effort,
  ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
  QueryCancellationSignal? cancellationSignal,
}) {
  final active = activeSession(cwd: options.cwd);
  return _promptHelper(
    promptText: prompt,
    options:
        active == null ? options : options.copyWith(resumeSessionId: active.id),
    model: model,
    effort: effort,
    request: request,
    cancellationSignal: cancellationSignal,
  );
}

Future<ClartCodePromptResult> _promptHelper({
  required String promptText,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
  ClartCodeReasoningEffort? effort,
  ClartCodeRequestOptions request = const ClartCodeRequestOptions(),
  QueryCancellationSignal? cancellationSignal,
}) {
  return prompt(
    prompt: promptText,
    options: options,
    model: model,
    effort: effort,
    request: request,
    cancellationSignal: cancellationSignal,
  );
}

Future<ClartCodeSubagentResult> runSubagent({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  ClartCodeSubagentOptions subagent = const ClartCodeSubagentOptions(),
  QueryCancellationSignal? cancellationSignal,
}) async {
  final agent = ClartCodeAgent(options);
  try {
    return await agent.runSubagent(
      prompt,
      options: subagent,
      cancellationSignal: cancellationSignal,
    );
  } finally {
    await agent.close();
  }
}

ClartCodeSessionStore sessionStore({String? cwd}) {
  return ClartCodeSessionStore(cwd: cwd);
}

ClartCodeSessionSnapshot? loadSession({
  required String sessionId,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).load(sessionId);
}

List<ClartCodeSessionSnapshot> listSessions({String? cwd}) {
  return sessionStore(cwd: cwd).list();
}

ClartCodeSessionSnapshot? latestSession({String? cwd}) {
  return sessionStore(cwd: cwd).latest();
}

String? activeSessionId({String? cwd}) {
  return sessionStore(cwd: cwd).readActiveSessionId();
}

ClartCodeSessionSnapshot? activeSession({String? cwd}) {
  return sessionStore(cwd: cwd).active();
}

ClartCodeSessionSnapshot? getSessionInfo({
  required String sessionId,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).info(sessionId);
}

List<ChatMessage>? getSessionMessages({
  required String sessionId,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).messages(sessionId);
}

List<TranscriptMessage>? getSessionTranscript({
  required String sessionId,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).transcriptMessages(sessionId);
}

ClartCodeSessionSnapshot? renameSession({
  required String sessionId,
  required String title,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).rename(sessionId, title);
}

ClartCodeSessionSnapshot? forkSession({
  required String sessionId,
  String? title,
  List<String>? tags,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).fork(
    sessionId,
    title: title,
    tags: tags,
  );
}

ClartCodeSessionSnapshot? setSessionTags({
  required String sessionId,
  required List<String> tags,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).setTags(sessionId, tags);
}

ClartCodeSessionSnapshot? addSessionTag({
  required String sessionId,
  required String tag,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).addTag(sessionId, tag);
}

ClartCodeSessionSnapshot? removeSessionTag({
  required String sessionId,
  required String tag,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).removeTag(sessionId, tag);
}

ClartCodeSessionSnapshot? appendToSession({
  required String sessionId,
  String? cwd,
  List<ChatMessage> history = const [],
  List<TranscriptMessage> transcript = const [],
}) {
  return sessionStore(cwd: cwd).append(
    sessionId,
    history: history,
    transcript: transcript,
  );
}

bool deleteSession({
  required String sessionId,
  String? cwd,
}) {
  return sessionStore(cwd: cwd).delete(sessionId);
}
