/// JSON-RPC 2.0 协议实现
library json_rpc;

import 'dart:async';
import 'dart:convert';

/// JSON-RPC 请求
class JsonRpcRequest {
  JsonRpcRequest({
    required this.method,
    this.params,
    String? id,
  }) : id = id ?? _generateId();

  final String id;
  final String method;
  final Object? params;

  static int _idCounter = 0;
  static String _generateId() => 'req_${++_idCounter}';

  Map<String, Object?> toJson() {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
  }

  String toJsonString() => jsonEncode(toJson());
}

/// JSON-RPC 响应
class JsonRpcResponse {
  const JsonRpcResponse({
    required this.id,
    this.result,
    this.error,
  });

  final String id;
  final Object? result;
  final JsonRpcError? error;

  bool get isSuccess => error == null;
  bool get isError => error != null;

  factory JsonRpcResponse.fromJson(Map<String, Object?> json) {
    final errorJson = json['error'] as Map<String, Object?>?;
    return JsonRpcResponse(
      id: json['id'] as String,
      result: json['result'],
      error: errorJson != null ? JsonRpcError.fromJson(errorJson) : null,
    );
  }
}

/// JSON-RPC 错误
class JsonRpcError {
  const JsonRpcError({
    required this.code,
    required this.message,
    this.data,
  });

  final int code;
  final String message;
  final Object? data;

  factory JsonRpcError.fromJson(Map<String, Object?> json) {
    return JsonRpcError(
      code: json['code'] as int,
      message: json['message'] as String,
      data: json['data'],
    );
  }

  Map<String, Object?> toJson() {
    return {
      'code': code,
      'message': message,
      if (data != null) 'data': data,
    };
  }

  @override
  String toString() => 'JsonRpcError($code): $message';
}

/// JSON-RPC 通知（无需响应的消息）
class JsonRpcNotification {
  const JsonRpcNotification({
    required this.method,
    this.params,
  });

  final String method;
  final Object? params;

  Map<String, Object?> toJson() {
    return {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  factory JsonRpcNotification.fromJson(Map<String, Object?> json) {
    return JsonRpcNotification(
      method: json['method'] as String,
      params: json['params'],
    );
  }
}

/// JSON-RPC 客户端基类
abstract class JsonRpcClient {
  final _pendingRequests = <String, Completer<JsonRpcResponse>>{};
  final _notificationController =
      StreamController<JsonRpcNotification>.broadcast();

  Stream<JsonRpcNotification> get notifications =>
      _notificationController.stream;

  /// 发送请求并等待响应
  Future<JsonRpcResponse> sendRequest(JsonRpcRequest request) async {
    final completer = Completer<JsonRpcResponse>();
    _pendingRequests[request.id] = completer;

    try {
      await sendMessage(request.toJsonString());
      return await completer.future;
    } catch (e) {
      _pendingRequests.remove(request.id);
      rethrow;
    }
  }

  /// 发送通知（不等待响应）
  Future<void> sendNotification(JsonRpcNotification notification) async {
    await sendMessage(notification.toJsonString());
  }

  /// 处理接收到的消息
  void handleMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, Object?>;

      // 检查是否是响应
      if (json.containsKey('id') && json.containsKey('result') ||
          json.containsKey('error')) {
        final response = JsonRpcResponse.fromJson(json);
        final completer = _pendingRequests.remove(response.id);
        completer?.complete(response);
        return;
      }

      // 检查是否是通知
      if (json.containsKey('method') && !json.containsKey('id')) {
        final notification = JsonRpcNotification.fromJson(json);
        _notificationController.add(notification);
        return;
      }
    } catch (e) {
      // 忽略无法解析的消息
    }
  }

  /// 发送原始消息（由子类实现）
  Future<void> sendMessage(String message);

  /// 关闭客户端
  Future<void> close() async {
    for (final completer in _pendingRequests.values) {
      completer.completeError(Exception('Client closed'));
    }
    _pendingRequests.clear();
    await _notificationController.close();
  }
}
