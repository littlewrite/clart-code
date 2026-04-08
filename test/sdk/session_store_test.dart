import 'dart:io';

import 'package:clart_code/clart_code_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('session store can rename tag and fork snapshots', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_store_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(cwd: tempDir.path),
      );
      final firstResult = await agent.prompt('session metadata');
      expect(firstResult.isError, false);

      final store = ClartCodeSessionStore(cwd: tempDir.path);
      final renamed = store.rename(agent.sessionId, 'Renamed Session');
      expect(renamed, isNotNull);
      expect(renamed!.title, 'Renamed Session');

      final tagged = store.addTag(agent.sessionId, 'sdk');
      expect(tagged, isNotNull);
      expect(tagged!.tags, ['sdk']);

      final retagged = store.setTags(agent.sessionId, ['phase2', 'sdk']);
      expect(retagged, isNotNull);
      expect(retagged!.tags, ['phase2', 'sdk']);

      final forked = store.fork(agent.sessionId, title: 'Forked Session');
      expect(forked, isNotNull);
      expect(forked!.id, isNot(agent.sessionId));
      expect(forked.title, 'Forked Session');
      expect(forked.tags, ['phase2', 'sdk']);
      expect(
          forked.history.map((message) => message.text),
          containsAll([
            'session metadata',
            'echo: session metadata',
          ]));

      final removedTag = store.removeTag(agent.sessionId, 'sdk');
      expect(removedTag, isNotNull);
      expect(removedTag!.tags, ['phase2']);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('resumed agent preserves renamed title and tags on next persist',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_store_resume_',
    );

    try {
      final firstAgent = ClartCodeAgent(
        ClartCodeAgentOptions(cwd: tempDir.path),
      );
      await firstAgent.prompt('first session title');

      final store = ClartCodeSessionStore(cwd: tempDir.path);
      store.rename(firstAgent.sessionId, 'Pinned Title');
      store.setTags(firstAgent.sessionId, ['kept', 'sdk']);

      final resumedAgent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          resumeSessionId: firstAgent.sessionId,
        ),
      );
      await resumedAgent.prompt('second turn');

      final persisted = store.load(firstAgent.sessionId);
      expect(persisted, isNotNull);
      expect(persisted!.title, 'Pinned Title');
      expect(persisted.tags, ['kept', 'sdk']);
      expect(
        persisted.history.map((message) => message.text),
        containsAll(['first session title', 'second turn']),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('agent convenience API manages current session metadata', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_store_agent_meta_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(cwd: tempDir.path),
      );
      await agent.prompt('agent metadata prompt');

      final initialSnapshot = agent.snapshot();
      expect(initialSnapshot.id, agent.sessionId);
      expect(
        initialSnapshot.history.map((message) => message.text),
        containsAll([
          'agent metadata prompt',
          'echo: agent metadata prompt',
        ]),
      );

      final renamed = agent.renameSession('  Renamed Agent Session  ');
      expect(renamed.title, 'Renamed Agent Session');
      expect(agent.sessionTitle, 'Renamed Agent Session');

      final retagged = agent.setSessionTags(['sdk', 'phase2', 'sdk']);
      expect(retagged.tags, ['phase2', 'sdk']);
      expect(agent.sessionTags, ['phase2', 'sdk']);

      final added = agent.addSessionTag('alpha');
      expect(added.tags, ['alpha', 'phase2', 'sdk']);
      expect(agent.sessionTags, ['alpha', 'phase2', 'sdk']);

      final removed = agent.removeSessionTag('phase2');
      expect(removed.tags, ['alpha', 'sdk']);
      expect(agent.sessionTags, ['alpha', 'sdk']);

      final forked = agent.forkSession(
        title: 'Forked Agent Session',
        tags: ['fork', 'sdk'],
      );
      expect(forked.id, isNot(agent.sessionId));
      expect(forked.title, 'Forked Agent Session');
      expect(forked.tags, ['fork', 'sdk']);
      expect(
        forked.history.map((message) => message.text),
        containsAll([
          'agent metadata prompt',
          'echo: agent metadata prompt',
        ]),
      );

      final store = ClartCodeSessionStore(cwd: tempDir.path);
      final persisted = store.load(agent.sessionId);
      expect(persisted, isNotNull);
      expect(persisted!.title, 'Renamed Agent Session');
      expect(persisted.tags, ['alpha', 'sdk']);
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });

  test('session store preserves cascaded subagent transcript metadata',
      () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'clart_sdk_store_subagent_transcript_',
    );

    try {
      final agent = ClartCodeAgent(
        ClartCodeAgentOptions(
          cwd: tempDir.path,
          model: 'parent-model',
          providerOverride: _SubagentTranscriptProvider(),
        ),
      );

      final result = await agent.runSubagent(
        'inspect persisted child output',
        options: const ClartCodeSubagentOptions(
          name: 'reviewer',
          model: 'child-model',
          allowedTools: ['read'],
        ),
      );

      expect(result.transcriptMessages, hasLength(1));

      final store = ClartCodeSessionStore(cwd: tempDir.path);
      final persisted = store.load(agent.sessionId);
      expect(persisted, isNotNull);

      final subagentMessage = persisted!.transcript.singleWhere(
        (message) => message.kind == TranscriptMessageKind.subagent,
      );
      expect(subagentMessage.name, 'reviewer');
      expect(subagentMessage.sessionId, result.sessionId);
      expect(subagentMessage.parentSessionId, agent.sessionId);
      expect(subagentMessage.text, contains('output:\npersisted child answer'));
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });
}

class _SubagentTranscriptProvider extends NativeToolCallingLlmProvider {
  @override
  Future<QueryResponse> run(QueryRequest request) async {
    return QueryResponse.success(
      output: 'persisted child answer',
      modelUsed: request.model,
    );
  }
}
