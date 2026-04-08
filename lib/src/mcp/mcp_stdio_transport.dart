/// MCP Stdio 传输实现
/// 通过子进程的 stdin/stdout 进行 JSON-RPC 通信
library mcp_stdio_transport;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'json_rpc.dart';
import 'mcp_types.dart';

/// Stdio 传输客户端
class McpStdioTransport extends JsonRpcClient {
  McpStdioTransport({
    required this.config,
  });

  final McpStdioServerConfig config;
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final _stderrBuffer = StringBuffer();

  /// 启动子进程并建立连接
  Future<void> connect() async {
    if (_process != null) {
      throw StateError('Already connected');
    }

    try {
      _process = await Process.start(
        config.command,
        config.args,
        environment: config.env,
        mode: ProcessStartMode.normal,
      );

      // 监听 stdout（JSON-RPC 消息）
      _stdoutSubscription = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.trim().isNotEmpty) {
            handleMessage(line);
          }
        },
        onError: (error) {
          // 忽略流错误
        },
      );

      // 监听 stderr（日志输出）
      _stderrSubscription = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          _stderrBuffer.writeln(line);
        },
        onError: (error) {
          // 忽略流错误
        },
      );
    } catch (e) {
      throw Exception('Failed to start MCP server: $e');
    }
  }

  @override
  Future<void> sendMessage(String message) async {
    if (_process == null) {
      throw StateError('Not connected');
    }

    try {
      _process!.stdin.writeln(message);
      await _process!.stdin.flush();
    } catch (e) {
      throw Exception('Failed to send message: $e');
    }
  }

  String get stderrOutput => _stderrBuffer.toString();

  @override
  Future<void> close() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _process?.kill();
    _process = null;
    await super.close();
  }
}
