import 'package:test/test.dart';
import 'package:clart_code/src/mcp/json_rpc.dart';

void main() {
  group('JsonRpcRequest', () {
    test('toJson() creates valid JSON-RPC 2.0 request', () {
      final request = JsonRpcRequest(
        method: 'test_method',
        params: {'key': 'value'},
        id: 'test_id',
      );

      final json = request.toJson();

      expect(json['jsonrpc'], '2.0');
      expect(json['id'], 'test_id');
      expect(json['method'], 'test_method');
      expect(json['params'], {'key': 'value'});
    });

    test('generates unique IDs when not provided', () {
      final request1 = JsonRpcRequest(method: 'method1');
      final request2 = JsonRpcRequest(method: 'method2');

      expect(request1.id, isNot(equals(request2.id)));
    });

    test('omits params when null', () {
      final request = JsonRpcRequest(method: 'test_method');
      final json = request.toJson();

      expect(json.containsKey('params'), false);
    });
  });

  group('JsonRpcResponse', () {
    test('fromJson() parses success response', () {
      final json = {
        'jsonrpc': '2.0',
        'id': 'test_id',
        'result': {'data': 'value'},
      };

      final response = JsonRpcResponse.fromJson(json);

      expect(response.id, 'test_id');
      expect(response.result, {'data': 'value'});
      expect(response.error, isNull);
      expect(response.isSuccess, true);
      expect(response.isError, false);
    });

    test('fromJson() parses error response', () {
      final json = {
        'jsonrpc': '2.0',
        'id': 'test_id',
        'error': {
          'code': -32600,
          'message': 'Invalid Request',
        },
      };

      final response = JsonRpcResponse.fromJson(json);

      expect(response.id, 'test_id');
      expect(response.result, isNull);
      expect(response.error, isNotNull);
      expect(response.error!.code, -32600);
      expect(response.error!.message, 'Invalid Request');
      expect(response.isSuccess, false);
      expect(response.isError, true);
    });
  });

  group('JsonRpcError', () {
    test('fromJson() parses error object', () {
      final json = {
        'code': -32601,
        'message': 'Method not found',
        'data': {'detail': 'extra info'},
      };

      final error = JsonRpcError.fromJson(json);

      expect(error.code, -32601);
      expect(error.message, 'Method not found');
      expect(error.data, {'detail': 'extra info'});
    });

    test('toString() formats error message', () {
      final error = JsonRpcError(
        code: -32600,
        message: 'Invalid Request',
      );

      expect(error.toString(), 'JsonRpcError(-32600): Invalid Request');
    });
  });

  group('JsonRpcNotification', () {
    test('toJson() creates valid notification', () {
      final notification = JsonRpcNotification(
        method: 'notify',
        params: {'event': 'update'},
      );

      final json = notification.toJson();

      expect(json['jsonrpc'], '2.0');
      expect(json['method'], 'notify');
      expect(json['params'], {'event': 'update'});
      expect(json.containsKey('id'), false);
    });

    test('fromJson() parses notification', () {
      final json = {
        'jsonrpc': '2.0',
        'method': 'notify',
        'params': {'event': 'update'},
      };

      final notification = JsonRpcNotification.fromJson(json);

      expect(notification.method, 'notify');
      expect(notification.params, {'event': 'update'});
    });
  });
}
