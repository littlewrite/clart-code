import 'dart:convert';
import 'dart:io';

class GitWorkspaceState {
  const GitWorkspaceState({
    required this.workspacePath,
    required this.isGitRepository,
    required this.rootPath,
    required this.baseRef,
    required this.files,
    required this.patch,
    required this.patchTruncated,
  }) : generatedAt = null;

  const GitWorkspaceState.snapshot({
    required this.workspacePath,
    required this.generatedAt,
    required this.isGitRepository,
    required this.rootPath,
    required this.baseRef,
    required this.files,
    required this.patch,
    required this.patchTruncated,
  });

  final String workspacePath;
  final String? generatedAt;
  final bool isGitRepository;
  final String? rootPath;
  final String? baseRef;
  final List<GitWorkspaceFile> files;
  final String patch;
  final bool patchTruncated;

  bool get hasChanges => files.isNotEmpty;

  int get filesChanged => files.length;

  int get untrackedFiles => files.where((file) => file.isUntracked).length;

  int get linesAdded =>
      files.fold(0, (sum, file) => sum + (file.isUntracked ? 0 : file.added));

  int get linesRemoved => files.fold(
        0,
        (sum, file) => sum + (file.isUntracked ? 0 : file.removed),
      );

  Map<String, Object?> toJson() {
    return {
      'workspacePath': workspacePath,
      'generatedAt': generatedAt,
      'isGitRepository': isGitRepository,
      'rootPath': rootPath,
      'baseRef': baseRef,
      'hasChanges': hasChanges,
      'filesChanged': filesChanged,
      'untrackedFiles': untrackedFiles,
      'linesAdded': linesAdded,
      'linesRemoved': linesRemoved,
      'patchTruncated': patchTruncated,
      'patch': patch,
      'files': files.map((file) => file.toJson()).toList(),
    };
  }
}

class GitWorkspaceFile {
  const GitWorkspaceFile({
    required this.path,
    required this.status,
    required this.added,
    required this.removed,
    required this.isBinary,
    required this.isUntracked,
    this.preview,
    this.previewTruncated = false,
  });

  final String path;
  final String status;
  final int added;
  final int removed;
  final bool isBinary;
  final bool isUntracked;
  final String? preview;
  final bool previewTruncated;

  Map<String, Object?> toJson() {
    return {
      'path': path,
      'status': status,
      'added': added,
      'removed': removed,
      'isBinary': isBinary,
      'isUntracked': isUntracked,
      'preview': preview,
      'previewTruncated': previewTruncated,
    };
  }
}

class _GitNumstatEntry {
  const _GitNumstatEntry({
    required this.added,
    required this.removed,
    required this.isBinary,
  });

  final int added;
  final int removed;
  final bool isBinary;
}

const _defaultPatchCharLimit = 40000;
const _defaultPreviewFileLimit = 5;
const _defaultPreviewCharLimit = 4000;

Future<GitWorkspaceState> readGitWorkspaceState({
  String? cwd,
  int patchCharLimit = _defaultPatchCharLimit,
  int previewFileLimit = _defaultPreviewFileLimit,
  int previewCharLimit = _defaultPreviewCharLimit,
}) async {
  final workspacePath = cwd ?? Directory.current.path;
  final repoCheck = await _runGit(
    workspacePath,
    const ['rev-parse', '--show-toplevel'],
  );
  if (repoCheck.exitCode != 0) {
    return GitWorkspaceState.snapshot(
      workspacePath: workspacePath,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      isGitRepository: false,
      rootPath: null,
      baseRef: null,
      files: const [],
      patch: '',
      patchTruncated: false,
    );
  }

  final rootPath = (repoCheck.stdout as String).trim();
  final headCheck =
      await _runGit(rootPath, const ['rev-parse', '--verify', 'HEAD']);
  final hasHead = headCheck.exitCode == 0;
  final statusResult = await _runGit(
    rootPath,
    const ['status', '--porcelain', '--untracked-files=all'],
  );

  final numstatMap = hasHead
      ? _parseGitNumstat(
          (await _runGit(
            rootPath,
            const ['diff', '--no-ext-diff', '--numstat', 'HEAD', '--'],
          ))
              .stdout as String,
        )
      : const <String, _GitNumstatEntry>{};

  var patch = '';
  var patchTruncated = false;
  if (hasHead) {
    final patchResult = await _runGit(
      rootPath,
      const ['diff', '--no-ext-diff', '--patch', '--binary', 'HEAD', '--'],
    );
    final rawPatch = patchResult.stdout as String;
    if (rawPatch.length > patchCharLimit) {
      patch = '${rawPatch.substring(0, patchCharLimit)}\n'
          '[patch truncated at $patchCharLimit chars]';
      patchTruncated = true;
    } else {
      patch = rawPatch;
    }
  }

  final statusLines = ((statusResult.stdout as String).trim().isEmpty)
      ? const <String>[]
      : const LineSplitter()
          .convert((statusResult.stdout as String).trimRight());

  final changes = <GitWorkspaceFile>[];
  final seenPaths = <String>{};
  var previewedFiles = 0;

  for (final line in statusLines) {
    if (line.length < 3) {
      continue;
    }
    final statusCode = line.substring(0, 2);
    final rawPath = line.substring(3).trim();
    final normalizedPath = _normalizeStatusPath(rawPath);
    final isUntracked = statusCode == '??';
    final numstat = numstatMap[normalizedPath];
    String? preview;
    var previewTruncated = false;
    var isBinary = numstat?.isBinary ?? false;

    if (isUntracked && previewedFiles < previewFileLimit) {
      final previewResult = await _readFilePreview(
        '$rootPath/$normalizedPath',
        charLimit: previewCharLimit,
      );
      preview = previewResult.preview;
      previewTruncated = previewResult.truncated;
      isBinary = previewResult.isBinary;
      previewedFiles += 1;
    }

    if (seenPaths.add(normalizedPath)) {
      changes.add(
        GitWorkspaceFile(
          path: normalizedPath,
          status: _describeStatus(statusCode),
          added: isUntracked ? 0 : numstat?.added ?? 0,
          removed: isUntracked ? 0 : numstat?.removed ?? 0,
          isBinary: isBinary,
          isUntracked: isUntracked,
          preview: preview,
          previewTruncated: previewTruncated,
        ),
      );
    }
  }

  changes.sort((a, b) => a.path.compareTo(b.path));

  return GitWorkspaceState.snapshot(
    workspacePath: workspacePath,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    isGitRepository: true,
    rootPath: rootPath,
    baseRef: hasHead ? 'HEAD' : null,
    files: changes,
    patch: patch,
    patchTruncated: patchTruncated,
  );
}

GitWorkspaceState readGitWorkspaceStateSync({
  String? cwd,
  int patchCharLimit = _defaultPatchCharLimit,
  int previewFileLimit = _defaultPreviewFileLimit,
  int previewCharLimit = _defaultPreviewCharLimit,
}) {
  final workspacePath = cwd ?? Directory.current.path;
  final repoCheck = _runGitSync(
    workspacePath,
    const ['rev-parse', '--show-toplevel'],
  );
  if (repoCheck.exitCode != 0) {
    return GitWorkspaceState.snapshot(
      workspacePath: workspacePath,
      generatedAt: DateTime.now().toUtc().toIso8601String(),
      isGitRepository: false,
      rootPath: null,
      baseRef: null,
      files: const [],
      patch: '',
      patchTruncated: false,
    );
  }

  final rootPath = (repoCheck.stdout as String).trim();
  final headCheck =
      _runGitSync(rootPath, const ['rev-parse', '--verify', 'HEAD']);
  final hasHead = headCheck.exitCode == 0;
  final statusResult = _runGitSync(
    rootPath,
    const ['status', '--porcelain', '--untracked-files=all'],
  );

  final numstatMap = hasHead
      ? _parseGitNumstat(
          (_runGitSync(
            rootPath,
            const ['diff', '--no-ext-diff', '--numstat', 'HEAD', '--'],
          ).stdout as String),
        )
      : const <String, _GitNumstatEntry>{};

  var patch = '';
  var patchTruncated = false;
  if (hasHead) {
    final patchResult = _runGitSync(
      rootPath,
      const ['diff', '--no-ext-diff', '--patch', '--binary', 'HEAD', '--'],
    );
    final rawPatch = patchResult.stdout as String;
    if (rawPatch.length > patchCharLimit) {
      patch = '${rawPatch.substring(0, patchCharLimit)}\n'
          '[patch truncated at $patchCharLimit chars]';
      patchTruncated = true;
    } else {
      patch = rawPatch;
    }
  }

  final statusLines = ((statusResult.stdout as String).trim().isEmpty)
      ? const <String>[]
      : const LineSplitter()
          .convert((statusResult.stdout as String).trimRight());

  final changes = <GitWorkspaceFile>[];
  final seenPaths = <String>{};
  var previewedFiles = 0;

  for (final line in statusLines) {
    if (line.length < 3) {
      continue;
    }
    final statusCode = line.substring(0, 2);
    final rawPath = line.substring(3).trim();
    final normalizedPath = _normalizeStatusPath(rawPath);
    final isUntracked = statusCode == '??';
    final numstat = numstatMap[normalizedPath];
    String? preview;
    var previewTruncated = false;
    var isBinary = numstat?.isBinary ?? false;

    if (isUntracked && previewedFiles < previewFileLimit) {
      final previewResult = _readFilePreviewSync(
        '$rootPath/$normalizedPath',
        charLimit: previewCharLimit,
      );
      preview = previewResult.preview;
      previewTruncated = previewResult.truncated;
      isBinary = previewResult.isBinary;
      previewedFiles += 1;
    }

    if (seenPaths.add(normalizedPath)) {
      changes.add(
        GitWorkspaceFile(
          path: normalizedPath,
          status: _describeStatus(statusCode),
          added: isUntracked ? 0 : numstat?.added ?? 0,
          removed: isUntracked ? 0 : numstat?.removed ?? 0,
          isBinary: isBinary,
          isUntracked: isUntracked,
          preview: preview,
          previewTruncated: previewTruncated,
        ),
      );
    }
  }

  changes.sort((a, b) => a.path.compareTo(b.path));

  return GitWorkspaceState.snapshot(
    workspacePath: workspacePath,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    isGitRepository: true,
    rootPath: rootPath,
    baseRef: hasHead ? 'HEAD' : null,
    files: changes,
    patch: patch,
    patchTruncated: patchTruncated,
  );
}

String renderGitWorkspaceSummary(
  GitWorkspaceState state, {
  bool includePatch = true,
  bool includeUntrackedPreview = true,
}) {
  if (!state.isGitRepository) {
    return '[not-git-repository]';
  }

  if (!state.hasChanges) {
    return '[clean-worktree]';
  }

  final buffer = StringBuffer();
  buffer.writeln('git.root=${state.rootPath}');
  buffer.writeln('git.base=${state.baseRef ?? '-'}');
  buffer.writeln('git.files=${state.filesChanged}');
  buffer.writeln('git.linesAdded=${state.linesAdded}');
  buffer.writeln('git.linesRemoved=${state.linesRemoved}');
  buffer.writeln('git.untracked=${state.untrackedFiles}');
  buffer.writeln();
  buffer.writeln('Files:');
  for (final file in state.files) {
    final counts = file.isUntracked ? '' : ' (+${file.added}/-${file.removed})';
    final binary = file.isBinary ? ' [binary]' : '';
    buffer.writeln('- ${file.path} [${file.status}]$counts$binary');
  }

  if (includePatch && state.patch.trim().isNotEmpty) {
    buffer.writeln();
    buffer.writeln('Patch:');
    buffer.writeln(state.patch.trimRight());
  }

  if (includeUntrackedPreview) {
    final previewFiles = state.files
        .where((file) => file.isUntracked && file.preview != null)
        .toList();
    if (previewFiles.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Untracked file previews:');
      for (final file in previewFiles) {
        buffer.writeln('- ${file.path}');
        if (file.isBinary) {
          buffer.writeln('[binary file omitted]');
        } else {
          buffer.writeln(file.preview!.trimRight());
          if (file.previewTruncated) {
            buffer.writeln('[preview truncated]');
          }
        }
        buffer.writeln();
      }
    }
  }

  return buffer.toString().trimRight();
}

String buildReviewPrompt(
  GitWorkspaceState state, {
  String? extraInstructions,
}) {
  final buffer = StringBuffer();
  buffer.writeln('You are reviewing the current git working tree changes.');
  buffer.writeln(
    'Focus on correctness, regressions, missing tests, security, and maintainability.',
  );
  buffer.writeln(
    'List findings first, ordered by severity, and include file paths when possible.',
  );
  buffer.writeln(
    'If you find no concrete issues, say that explicitly and mention residual risks or missing validation.',
  );
  if (extraInstructions != null && extraInstructions.trim().isNotEmpty) {
    buffer.writeln();
    buffer.writeln('Extra review instructions: ${extraInstructions.trim()}');
  }
  buffer.writeln();
  buffer.writeln('Workspace: ${state.workspacePath}');
  buffer.writeln('Git root: ${state.rootPath}');
  buffer.writeln('Base ref: ${state.baseRef ?? 'none'}');
  buffer.writeln('Files changed: ${state.filesChanged}');
  buffer.writeln('Lines added: ${state.linesAdded}');
  buffer.writeln('Lines removed: ${state.linesRemoved}');
  buffer.writeln('Untracked files: ${state.untrackedFiles}');
  buffer.writeln();
  buffer.writeln('Changed files:');
  for (final file in state.files) {
    final counts =
        file.isUntracked ? '' : ' (+${file.added} / -${file.removed})';
    final binary = file.isBinary ? ' [binary]' : '';
    buffer.writeln('- ${file.path} [${file.status}]$counts$binary');
  }

  if (state.patch.trim().isNotEmpty) {
    buffer.writeln();
    buffer.writeln('Tracked file patch:');
    buffer.writeln('```diff');
    buffer.writeln(state.patch.trimRight());
    buffer.writeln('```');
  }

  final previewFiles = state.files
      .where((file) => file.isUntracked && file.preview != null)
      .toList();
  if (previewFiles.isNotEmpty) {
    buffer.writeln();
    buffer.writeln('Untracked file previews:');
    for (final file in previewFiles) {
      buffer.writeln('- ${file.path}');
      if (file.isBinary) {
        buffer.writeln('[binary file omitted]');
      } else {
        buffer.writeln('```');
        buffer.writeln(file.preview!.trimRight());
        buffer.writeln('```');
      }
      if (file.previewTruncated) {
        buffer.writeln('[preview truncated]');
      }
    }
  }

  final omittedUntrackedFiles = state.files
      .where((file) => file.isUntracked && file.preview == null)
      .map((file) => file.path)
      .toList();
  if (omittedUntrackedFiles.isNotEmpty) {
    buffer.writeln();
    buffer.writeln('Untracked files without inline preview:');
    for (final path in omittedUntrackedFiles) {
      buffer.writeln('- $path');
    }
  }

  return buffer.toString().trimRight();
}

Map<String, _GitNumstatEntry> _parseGitNumstat(String stdout) {
  final result = <String, _GitNumstatEntry>{};
  if (stdout.trim().isEmpty) {
    return result;
  }
  for (final line in const LineSplitter().convert(stdout.trimRight())) {
    final parts = line.split('\t');
    if (parts.length < 3) {
      continue;
    }
    final path = parts.sublist(2).join('\t');
    final isBinary = parts[0] == '-' || parts[1] == '-';
    result[path] = _GitNumstatEntry(
      added: isBinary ? 0 : int.tryParse(parts[0]) ?? 0,
      removed: isBinary ? 0 : int.tryParse(parts[1]) ?? 0,
      isBinary: isBinary,
    );
  }
  return result;
}

String _normalizeStatusPath(String rawPath) {
  final arrowIndex = rawPath.indexOf(' -> ');
  if (arrowIndex == -1) {
    return rawPath;
  }
  return rawPath.substring(arrowIndex + 4);
}

String _describeStatus(String statusCode) {
  if (statusCode == '??') {
    return 'untracked';
  }
  if (statusCode.contains('U')) {
    return 'unmerged';
  }
  if (statusCode.contains('R')) {
    return 'renamed';
  }
  if (statusCode.contains('C')) {
    return 'copied';
  }
  if (statusCode.contains('A')) {
    return 'added';
  }
  if (statusCode.contains('D')) {
    return 'deleted';
  }
  if (statusCode.contains('M')) {
    return 'modified';
  }
  return 'changed';
}

Future<({String? preview, bool truncated, bool isBinary})> _readFilePreview(
  String path, {
  required int charLimit,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    return (preview: null, truncated: false, isBinary: false);
  }

  try {
    final bytes = await file.readAsBytes();
    if (bytes.contains(0)) {
      return (preview: null, truncated: false, isBinary: true);
    }
    final decoded = utf8.decode(bytes, allowMalformed: true);
    if (decoded.length > charLimit) {
      return (
        preview: decoded.substring(0, charLimit),
        truncated: true,
        isBinary: false,
      );
    }
    return (preview: decoded, truncated: false, isBinary: false);
  } catch (_) {
    return (preview: null, truncated: false, isBinary: false);
  }
}

({String? preview, bool truncated, bool isBinary}) _readFilePreviewSync(
  String path, {
  required int charLimit,
}) {
  final file = File(path);
  if (!file.existsSync()) {
    return (preview: null, truncated: false, isBinary: false);
  }

  try {
    final bytes = file.readAsBytesSync();
    if (bytes.contains(0)) {
      return (preview: null, truncated: false, isBinary: true);
    }
    final decoded = utf8.decode(bytes, allowMalformed: true);
    if (decoded.length > charLimit) {
      return (
        preview: decoded.substring(0, charLimit),
        truncated: true,
        isBinary: false,
      );
    }
    return (preview: decoded, truncated: false, isBinary: false);
  } catch (_) {
    return (preview: null, truncated: false, isBinary: false);
  }
}

Future<ProcessResult> _runGit(
  String workingDirectory,
  List<String> args,
) async {
  try {
    return await Process.run(
      'git',
      args,
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    return ProcessResult(0, 1, '', error.message);
  }
}

ProcessResult _runGitSync(
  String workingDirectory,
  List<String> args,
) {
  try {
    return Process.runSync(
      'git',
      args,
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    return ProcessResult(0, 1, '', error.message);
  }
}
