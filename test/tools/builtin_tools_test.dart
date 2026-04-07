import 'dart:io';

import 'package:clart_code/src/tools/builtin_tools.dart';
import 'package:clart_code/src/tools/tool_models.dart';
import 'package:test/test.dart';

void main() {
  group('builtin tools', () {
    test('read/write resolve relative paths against configured cwd', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_builtin_rw_',
      );

      try {
        final write = WriteTool(cwd: tempDir.path);
        final read = ReadTool(cwd: tempDir.path);

        final writeResult = await write.run(
          ToolInvocation(
            name: 'write',
            input: {
              'path': 'nested/note.txt',
              'content': 'hello builtin',
            },
          ),
        );
        final readResult = await read.run(
          ToolInvocation(
            name: 'read',
            input: {'path': 'nested/note.txt'},
          ),
        );

        expect(writeResult.ok, isTrue);
        expect(
          File('${tempDir.path}/nested/note.txt').existsSync(),
          isTrue,
        );
        expect(readResult.ok, isTrue);
        expect(readResult.output, 'hello builtin');
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('shell executes command in configured cwd', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_builtin_shell_',
      );

      try {
        final shell = ShellTool(cwd: tempDir.path);
        final command = Platform.isWindows ? 'cd' : 'pwd';
        final result = await shell.run(
          ToolInvocation(
            name: 'shell',
            input: {'command': command},
          ),
        );

        expect(result.ok, isTrue);
        expect(result.output, contains(tempDir.path));
        expect(result.metadata?['cwd'], tempDir.path);
        expect(result.metadata?['exitCode'], 0);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('shell returns stable failure for non-zero exit code', () async {
      final shell = const ShellTool();
      final command = Platform.isWindows
          ? 'echo shell_fail 1>&2 & exit /b 7'
          : 'echo shell_fail 1>&2; exit 7';

      final result = await shell.run(
        ToolInvocation(
          name: 'shell',
          input: {'command': command},
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'command_failed');
      expect(result.errorMessage, contains('code 7'));
      expect(result.metadata?['exitCode'], 7);
      expect(result.metadata?['stderr'], contains('shell_fail'));
    });

    test('shell returns timeout failure', () async {
      final shell = const ShellTool();
      final command =
          Platform.isWindows ? 'ping 127.0.0.1 -n 6 > nul' : 'sleep 5';

      final result = await shell.run(
        ToolInvocation(
          name: 'shell',
          input: {
            'command': command,
            'timeoutMs': 20,
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'timeout');
      expect(result.errorMessage, contains('timed out'));
      expect(result.metadata?['timeoutMs'], 20);
    });

    test('edit replaces text in a relative file under cwd', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_builtin_edit_',
      );
      final file = File('${tempDir.path}/note.txt');
      await file.writeAsString('alpha beta gamma');

      try {
        final edit = EditTool(cwd: tempDir.path);
        final result = await edit.run(
          ToolInvocation(
            name: 'edit',
            input: {
              'path': 'note.txt',
              'oldText': 'beta',
              'newText': 'BETA',
            },
          ),
        );

        expect(result.ok, isTrue);
        expect(await file.readAsString(), 'alpha BETA gamma');
        expect(result.metadata?['replacements'], 1);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('glob lists files matching pattern relative to cwd', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_builtin_glob_',
      );
      await File('${tempDir.path}/a.txt').writeAsString('a');
      await Directory('${tempDir.path}/nested').create(recursive: true);
      await File('${tempDir.path}/nested/b.txt').writeAsString('b');
      await File('${tempDir.path}/nested/c.dart').writeAsString('c');

      try {
        final glob = GlobTool(cwd: tempDir.path);
        final result = await glob.run(
          ToolInvocation(
            name: 'glob',
            input: {'pattern': '**/*.txt'},
          ),
        );

        expect(result.ok, isTrue);
        expect(
          result.output.split('\n'),
          containsAll(['a.txt', 'nested/b.txt']),
        );
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('grep returns matching lines with file and line number', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_builtin_grep_',
      );
      final file = File('${tempDir.path}/note.txt');
      await file
          .writeAsString('first line\nmatch me\nthird line\nmatch me too');

      try {
        final grep = GrepTool(cwd: tempDir.path);
        final result = await grep.run(
          ToolInvocation(
            name: 'grep',
            input: {
              'pattern': 'match me',
              'path': '.',
            },
          ),
        );

        expect(result.ok, isTrue);
        expect(result.output, contains('note.txt:2:match me'));
        expect(result.output, contains('note.txt:4:match me too'));
        expect(result.metadata?['count'], 2);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
