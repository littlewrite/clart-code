import 'dart:io';

import 'package:clart_code/src/tools/builtin_tools.dart';
import 'package:clart_code/src/tools/tool_executor.dart';
import 'package:clart_code/src/tools/tool_models.dart';
import 'package:test/test.dart';

void main() {
  group('builtin tools', () {
    test('ToolExecutor.baseTools exposes the default builtin tool set', () {
      final tools = ToolExecutor.baseTools(cwd: '/tmp/demo');

      expect(tools.map((tool) => tool.name), [
        'read',
        'write',
        'edit',
        'glob',
        'grep',
        'shell',
      ]);
      expect(tools.whereType<ReadTool>().single.cwd, '/tmp/demo');
      expect(tools.whereType<ShellTool>().single.cwd, '/tmp/demo');
    });

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
        expect(readResult.metadata?['path'], '${tempDir.path}/nested/note.txt');
        expect(
            writeResult.metadata?['path'], '${tempDir.path}/nested/note.txt');
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

    test('builtin tools return invalid_input for wrong input types', () async {
      final read = const ReadTool();
      final write = const WriteTool();
      final shell = const ShellTool();
      final edit = const EditTool();
      final glob = const GlobTool();
      final grep = const GrepTool();

      final readResult = await read.run(
        ToolInvocation(
          name: 'read',
          input: {'path': 123},
        ),
      );
      final writeResult = await write.run(
        ToolInvocation(
          name: 'write',
          input: {
            'path': 'note.txt',
            'content': 123,
          },
        ),
      );
      final shellResult = await shell.run(
        ToolInvocation(
          name: 'shell',
          input: {
            'command': 'echo hi',
            'timeoutMs': 'fast',
          },
        ),
      );
      final editResult = await edit.run(
        ToolInvocation(
          name: 'edit',
          input: {
            'path': 'note.txt',
            'oldText': 'old',
            'newText': 'new',
            'replaceAll': 'yes',
          },
        ),
      );
      final globResult = await glob.run(
        ToolInvocation(
          name: 'glob',
          input: {
            'pattern': '**/*.txt',
            'cwd': 7,
          },
        ),
      );
      final grepResult = await grep.run(
        ToolInvocation(
          name: 'grep',
          input: {
            'pattern': 'hello',
            'regex': 'yes',
          },
        ),
      );

      expect(readResult.ok, isFalse);
      expect(readResult.errorCode, 'invalid_input');
      expect(writeResult.ok, isFalse);
      expect(writeResult.errorCode, 'invalid_input');
      expect(shellResult.ok, isFalse);
      expect(shellResult.errorCode, 'invalid_input');
      expect(editResult.ok, isFalse);
      expect(editResult.errorCode, 'invalid_input');
      expect(globResult.ok, isFalse);
      expect(globResult.errorCode, 'invalid_input');
      expect(grepResult.ok, isFalse);
      expect(grepResult.errorCode, 'invalid_input');
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

    test('file tools reject directory paths with stable error code', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_builtin_path_kind_',
      );
      await Directory('${tempDir.path}/nested').create(recursive: true);

      try {
        final read = ReadTool(cwd: tempDir.path);
        final write = WriteTool(cwd: tempDir.path);
        final edit = EditTool(cwd: tempDir.path);

        final readResult = await read.run(
          ToolInvocation(
            name: 'read',
            input: {'path': 'nested'},
          ),
        );
        final writeResult = await write.run(
          ToolInvocation(
            name: 'write',
            input: {
              'path': 'nested',
              'content': 'hello',
            },
          ),
        );
        final editResult = await edit.run(
          ToolInvocation(
            name: 'edit',
            input: {
              'path': 'nested',
              'oldText': 'a',
              'newText': 'b',
            },
          ),
        );

        expect(readResult.errorCode, 'path_is_directory');
        expect(writeResult.errorCode, 'path_is_directory');
        expect(editResult.errorCode, 'path_is_directory');
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
        expect(result.metadata?['pattern'], '**/*.txt');
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('glob and shell reject non-directory cwd values', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'clart_builtin_bad_cwd_',
      );
      final file = File('${tempDir.path}/file.txt');
      await file.writeAsString('hello');

      try {
        final glob = const GlobTool();
        final shell = const ShellTool();

        final globResult = await glob.run(
          ToolInvocation(
            name: 'glob',
            input: {
              'pattern': '*.txt',
              'cwd': file.path,
            },
          ),
        );
        final shellResult = await shell.run(
          ToolInvocation(
            name: 'shell',
            input: {
              'command': Platform.isWindows ? 'cd' : 'pwd',
              'cwd': file.path,
            },
          ),
        );

        expect(globResult.errorCode, 'path_not_directory');
        expect(shellResult.errorCode, 'path_not_directory');
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
        expect(result.metadata?['regex'], isFalse);
        expect(result.metadata?['caseSensitive'], isTrue);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('grep returns invalid_regex for malformed regex input', () async {
      final grep = const GrepTool();

      final result = await grep.run(
        ToolInvocation(
          name: 'grep',
          input: {
            'pattern': '[',
            'regex': true,
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'invalid_regex');
    });

    test('shell env values must be strings', () async {
      final shell = const ShellTool();

      final result = await shell.run(
        ToolInvocation(
          name: 'shell',
          input: {
            'command': Platform.isWindows ? 'cd' : 'pwd',
            'env': {'FOO': 1},
          },
        ),
      );

      expect(result.ok, isFalse);
      expect(result.errorCode, 'invalid_input');
      expect(result.errorMessage, contains('must be a string'));
    });
  });
}
