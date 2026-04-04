enum TaskType { localShell, localAgent, remoteAgent }

enum TaskStatus { pending, running, completed, failed, cancelled }

class Task {
  const Task({
    required this.id,
    required this.type,
    required this.status,
    required this.title,
    this.description,
    this.output,
    this.error,
    this.createdAt,
    this.completedAt,
  });

  final String id;
  final TaskType type;
  final TaskStatus status;
  final String title;
  final String? description;
  final String? output;
  final String? error;
  final DateTime? createdAt;
  final DateTime? completedAt;

  bool get isRunning => status == TaskStatus.running;
  bool get isCompleted => status == TaskStatus.completed;
  bool get isFailed => status == TaskStatus.failed;
  bool get isCancelled => status == TaskStatus.cancelled;

  Task copyWith({
    TaskStatus? status,
    String? output,
    String? error,
    DateTime? completedAt,
  }) {
    return Task(
      id: id,
      type: type,
      status: status ?? this.status,
      title: title,
      description: description,
      output: output ?? this.output,
      error: error ?? this.error,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'type': type.name,
      'status': status.name,
      'title': title,
      'description': description,
      'output': output,
      'error': error,
      'createdAt': createdAt?.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
    };
  }

  factory Task.fromJson(Map<String, Object?> json) {
    return Task(
      id: json['id'] as String,
      type: TaskType.values.byName(json['type'] as String),
      status: TaskStatus.values.byName(json['status'] as String),
      title: json['title'] as String,
      description: json['description'] as String?,
      output: json['output'] as String?,
      error: json['error'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
    );
  }
}
