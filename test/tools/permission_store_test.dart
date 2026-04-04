import 'dart:io';

import 'package:clart_code/src/tools/permission_store.dart';
import 'package:clart_code/src/tools/tool_permissions.dart';
import 'package:test/test.dart';

void main() {
  group('PermissionStore - Persistence', () {
    late PermissionStore store;

    setUp(() {
      store = PermissionStore(storePath: './.clart/test_permissions.json');
    });

    tearDown(() async {
      final file = File('./.clart/test_permissions.json');
      if (await file.exists()) {
        await file.delete();
      }
    });

    test('loadPolicy() returns default policy when file does not exist', () async {
      final policy = await store.loadPolicy();

      expect(policy.defaultMode, ToolPermissionMode.allow);
      expect(policy.rules.isEmpty, true);
    });

    test('savePolicy() persists policy to file', () async {
      final rule = ToolPermissionRule(
        toolName: 'shell',
        mode: ToolPermissionMode.deny,
      );
      final policy = ToolPermissionPolicy(
        defaultMode: ToolPermissionMode.allow,
        rules: {'shell': rule},
      );

      await store.savePolicy(policy);
      final loaded = await store.loadPolicy();

      expect(loaded.defaultMode, ToolPermissionMode.allow);
      expect(loaded.canExecute('shell'), false);
    });

    test('setToolPermission() adds or updates a tool permission', () async {
      await store.setToolPermission('shell', ToolPermissionMode.deny);
      final policy = await store.loadPolicy();

      expect(policy.canExecute('shell'), false);
      expect(policy.canExecute('read'), true);
    });

    test('removeToolPermission() removes a tool permission', () async {
      await store.setToolPermission('shell', ToolPermissionMode.deny);
      await store.removeToolPermission('shell');
      final policy = await store.loadPolicy();

      expect(policy.canExecute('shell'), true);
    });

    test('setDefaultMode() updates default permission mode', () async {
      await store.setDefaultMode(ToolPermissionMode.deny);
      final policy = await store.loadPolicy();

      expect(policy.defaultMode, ToolPermissionMode.deny);
      expect(policy.canExecute('read'), false);
    });
  });
}
