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
}
