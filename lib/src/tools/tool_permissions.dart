enum ToolPermissionMode { allow, deny }

class ToolPermissionPolicy {
  const ToolPermissionPolicy({
    this.mode = ToolPermissionMode.allow,
  });

  final ToolPermissionMode mode;

  bool canExecute(String toolName) {
    switch (mode) {
      case ToolPermissionMode.allow:
        return true;
      case ToolPermissionMode.deny:
        return false;
    }
  }
}
