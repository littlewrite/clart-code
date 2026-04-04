import 'dart:io';

import 'package:clart_code/src/tasks/task_executor.dart';
import 'package:clart_code/src/tasks/task_models.dart';
import 'package:clart_code/src/tasks/task_store.dart';
import 'package:test/test.dart';

void main() {
  group('Task System', () {
    late TaskExecutor executor;
    late TaskStore store;

    setUp(() {
      store = TaskStore(storePath: './.clart/test_tasks.json');
      executor = TaskExecutor(store: store);
    });

    tearDown(() async {
      // Clean up test file
      final file = File('./.clart/test_tasks.json');
      if (await file.exists()) {
        await file.delete();
      }
    });

    test('createTask() creates a new task', () async {
      final task = await executor.createTask(
        type: TaskType.localShell,
        title: 'Test Task',
        description: 'A test task',
      );

      expect(task.id, isNotEmpty);
      expect(task.type, TaskType.localShell);
      expect(task.status, TaskStatus.pending);
      expect(task.title, 'Test Task');
      expect(task.description, 'A test task');
      expect(task.createdAt, isNotNull);
    });

    test('completeTask() marks task as completed', () async {
      final task = await executor.createTask(
        type: TaskType.localShell,
        title: 'Test Task',
      );

      await executor.startTask(task.id);
      await executor.completeTask(task.id, output: 'Task completed');

      final completed = await store.getTask(task.id);
      expect(completed?.status, TaskStatus.completed);
      expect(completed?.output, 'Task completed');
      expect(completed?.completedAt, isNotNull);
    });

    test('failTask() marks task as failed', () async {
      final task = await executor.createTask(
        type: TaskType.localShell,
        title: 'Test Task',
      );

      await executor.failTask(task.id, error: 'Task failed');

      final failed = await store.getTask(task.id);
      expect(failed?.status, TaskStatus.failed);
      expect(failed?.error, 'Task failed');
    });

    test('cancelTask() marks task as cancelled', () async {
      final task = await executor.createTask(
        type: TaskType.localShell,
        title: 'Test Task',
      );

      await executor.startTask(task.id);
      await executor.cancelTask(task.id);

      final cancelled = await store.getTask(task.id);
      expect(cancelled?.status, TaskStatus.cancelled);
    });

    test('listTasks() returns all tasks', () async {
      await executor.createTask(
        type: TaskType.localShell,
        title: 'Task 1',
      );
      await executor.createTask(
        type: TaskType.localAgent,
        title: 'Task 2',
      );

      final tasks = await executor.listTasks();
      expect(tasks.length, 2);
    });

    test('listTasks() filters by status', () async {
      final task1 = await executor.createTask(
        type: TaskType.localShell,
        title: 'Task 1',
      );
      final task2 = await executor.createTask(
        type: TaskType.localAgent,
        title: 'Task 2',
      );

      await executor.completeTask(task1.id);

      final completed = await executor.listTasks(filterStatus: TaskStatus.completed);
      expect(completed.length, 1);
      expect(completed.first.id, task1.id);

      final pending = await executor.listTasks(filterStatus: TaskStatus.pending);
      expect(pending.length, 1);
      expect(pending.first.id, task2.id);
    });
  });
}
