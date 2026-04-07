import '../core/app_config.dart';
import 'git_workspace.dart';
import 'provider_setup.dart';
import 'workspace_store.dart';

List<String> buildDoctorReportLines(
  AppConfig config, {
  String? cwd,
  GitWorkspaceState? gitState,
}) {
  final memory = readWorkspaceMemory(cwd: cwd);
  final tasks = readWorkspaceTasks(cwd: cwd);
  final mcpServers = readWorkspaceMcpServers(cwd: cwd);
  final permissionMode = readDefaultToolPermissionMode(cwd: cwd);
  final providerHint = buildProviderSetupHint(config);
  final effectiveGitState = gitState ?? readGitWorkspaceStateSync(cwd: cwd);

  return [
    'workspace=${effectiveGitState.workspacePath}',
    'config=${config.configPath ?? '-'}',
    'provider=${config.provider.name}',
    'model=${config.model ?? 'default'}',
    'providerStatus=${providerHint == null ? 'ready' : 'needs-init'}',
    if (providerHint != null) 'providerHint=$providerHint',
    'memory=${memory.trim().isEmpty ? 'empty' : 'present'}',
    'tasks.total=${tasks.length}',
    'tasks.open=${tasks.where((task) => !task.done).length}',
    'permissions.default=${permissionMode.name}',
    'mcp.servers=${mcpServers.length}',
    'git.repository=${effectiveGitState.isGitRepository}',
    if (effectiveGitState.isGitRepository) ...[
      'git.root=${effectiveGitState.rootPath}',
      'git.status=${effectiveGitState.hasChanges ? 'dirty' : 'clean'}',
      'git.files=${effectiveGitState.filesChanged}',
      'git.untracked=${effectiveGitState.untrackedFiles}',
      'git.linesAdded=${effectiveGitState.linesAdded}',
      'git.linesRemoved=${effectiveGitState.linesRemoved}',
    ],
  ];
}
