import 'package:uuid/uuid.dart';

import 'task_models.dart';
import 'task_store.dart';

class TaskExecutor {
  TaskExecutor({TaskStore? store}) : _store = store ?? TaskStore();

  final TaskStore _store;
  static const _uuid = Uuid();

  Future<Task> createTask({
    required TaskType type,
    required String title,
    String? description,
  }) async {
    final task = Task(
      id: _uuid.v4(),
      type: type,
      status: TaskStatus.pending,
      title: title,
      description: description,
      createdAt: DateTime.now(),
    );
    await _store.addTask(task);
    return task;
  }

  Future<void> startTask(String taskId) async {
    final task = await _store.getTask(taskId);
    if (task != null) {
      await _store.updateTask(
        task.copyWith(status: TaskStatus.running),
      );
    }
  }

  Future<void> completeTask(String taskId, {String? output}) async {
    final task = await _store.getTask(taskId);
    if (task != null) {
      await _store.updateTask(
        task.copyWith(
          status: TaskStatus.completed,
          output: output,
          completedAt: DateTime.now(),
        ),
      );
    }
  }

  Future<void> failTask(String taskId, {String? error}) async {
    final task = await _store.getTask(taskId);
    if (task != null) {
      await _store.updateTask(
        task.copyWith(
          status: TaskStatus.failed,
          error: error,
          completedAt: DateTime.now(),
        ),
      );
    }
  }

  Future<void> cancelTask(String taskId) async {
    final task = await _store.getTask(taskId);
    if (task != null && !task.isCompleted && !task.isFailed) {
      await _store.updateTask(
        task.copyWith(
          status: TaskStatus.cancelled,
          completedAt: DateTime.now(),
        ),
      );
    }
  }

  Future<List<Task>> listTasks({TaskStatus? filterStatus}) async {
    final tasks = await _store.loadTasks();
    if (filterStatus != null) {
      return tasks.where((t) => t.status == filterStatus).toList();
    }
    return tasks;
  }
}
