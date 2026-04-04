import 'dart:convert';
import 'dart:io';

import 'tool_permissions.dart';

class PermissionStore {
  PermissionStore({String? storePath})
      : _storePath = storePath ?? './.clart/permissions.json';

  final String _storePath;

  Future<ToolPermissionPolicy> loadPolicy() async {
    final file = File(_storePath);
    if (!await file.exists()) {
      return const ToolPermissionPolicy();
    }

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, Object?>;
      return ToolPermissionPolicy.fromJson(json);
    } catch (e) {
      return const ToolPermissionPolicy();
    }
  }

  Future<void> savePolicy(ToolPermissionPolicy policy) async {
    final file = File(_storePath);
    await file.parent.create(recursive: true);
    final json = policy.toJson();
    await file.writeAsString(jsonEncode(json));
  }

  Future<void> setToolPermission(
    String toolName,
    ToolPermissionMode mode, {
    String? description,
  }) async {
    final policy = await loadPolicy();
    final rule = ToolPermissionRule(
      toolName: toolName,
      mode: mode,
      description: description,
    );
    final updatedPolicy = policy.withRule(rule);
    await savePolicy(updatedPolicy);
  }

  Future<void> removeToolPermission(String toolName) async {
    final policy = await loadPolicy();
    final updatedPolicy = policy.withoutRule(toolName);
    await savePolicy(updatedPolicy);
  }

  Future<void> setDefaultMode(ToolPermissionMode mode) async {
    final policy = await loadPolicy();
    final updatedPolicy = policy.copyWith(defaultMode: mode);
    await savePolicy(updatedPolicy);
  }
}
