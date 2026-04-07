import 'dart:convert';
import 'dart:io';

import 'task_models.dart';

class TaskStore {
  TaskStore({String? storePath})
      : _storePath = storePath ?? './.clart/tasks.json';

  final String _storePath;

  Future<List<Task>> loadTasks() async {
    final file = File(_storePath);
    if (!await file.exists()) {
      return [];
    }

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as List;
      return json
          .cast<Map<String, Object?>>()
          .map((item) => Task.fromJson(item))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> saveTasks(List<Task> tasks) async {
    final file = File(_storePath);
    await file.parent.create(recursive: true);
    final json = tasks.map((t) => t.toJson()).toList();
    await file.writeAsString(jsonEncode(json));
  }

  Future<Task?> getTask(String id) async {
    final tasks = await loadTasks();
    try {
      return tasks.firstWhere((t) => t.id == id);
    } catch (e) {
      return null;
    }
  }

  Future<void> addTask(Task task) async {
    final tasks = await loadTasks();
    tasks.add(task);
    await saveTasks(tasks);
  }

  Future<void> updateTask(Task task) async {
    final tasks = await loadTasks();
    final index = tasks.indexWhere((t) => t.id == task.id);
    if (index >= 0) {
      tasks[index] = task;
      await saveTasks(tasks);
    }
  }

  Future<void> removeTask(String id) async {
    final tasks = await loadTasks();
    tasks.removeWhere((t) => t.id == id);
    await saveTasks(tasks);
  }
}
