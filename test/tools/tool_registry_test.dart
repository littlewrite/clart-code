import 'package:test/test.dart';
import 'package:clart_code/src/tools/tool_models.dart';
import 'package:clart_code/src/tools/tool_registry.dart';

class MockTool implements Tool {
  MockTool(this.name);

  @override
  final String name;

  String get description => 'Mock tool';

  Map<String, Object?>? get inputSchema => null;

  @override
  ToolExecutionHint get executionHint => ToolExecutionHint.parallelSafe;

  @override
  Future<ToolExecutionResult> run(ToolInvocation invocation) async {
    return ToolExecutionResult.success(tool: name, output: 'mock output');
  }
}

void main() {
  group('ToolRegistry', () {
    test('lookup() returns registered tool', () {
      final registry = ToolRegistry(tools: [MockTool('test')]);
      final tool = registry.lookup('test');
      expect(tool, isNotNull);
      expect(tool!.name, 'test');
    });

    test('lookup() returns null for non-existent tool', () {
      final registry = ToolRegistry(tools: []);
      final tool = registry.lookup('non-existent');
      expect(tool, isNull);
    });

    test('all returns all registered tools', () {
      final tools = [MockTool('tool1'), MockTool('tool2')];
      final registry = ToolRegistry(tools: tools);
      expect(registry.all, hasLength(2));
    });

    test('throws on duplicate tool names during construction', () {
      expect(
        () => ToolRegistry(tools: [MockTool('dup'), MockTool('dup')]),
        throwsArgumentError,
      );
    });

    test('register() adds a new tool', () {
      final registry = ToolRegistry(tools: [MockTool('existing')]);
      registry.register(MockTool('new'));

      expect(registry.lookup('existing'), isNotNull);
      expect(registry.lookup('new'), isNotNull);
      expect(registry.all, hasLength(2));
    });

    test('register() throws on duplicate name', () {
      final registry = ToolRegistry(tools: [MockTool('existing')]);
      expect(
        () => registry.register(MockTool('existing')),
        throwsArgumentError,
      );
    });

    test('registerAll() adds multiple tools', () {
      final registry = ToolRegistry(tools: [MockTool('existing')]);
      registry.registerAll([MockTool('new1'), MockTool('new2')]);

      expect(registry.all, hasLength(3));
      expect(registry.lookup('new1'), isNotNull);
      expect(registry.lookup('new2'), isNotNull);
    });

    test('unregister() removes a tool', () {
      final registry = ToolRegistry(tools: [MockTool('tool1'), MockTool('tool2')]);
      registry.unregister('tool1');

      expect(registry.lookup('tool1'), isNull);
      expect(registry.lookup('tool2'), isNotNull);
      expect(registry.all, hasLength(1));
    });

    test('unregister() is safe for non-existent tool', () {
      final registry = ToolRegistry(tools: [MockTool('tool1')]);
      registry.unregister('non-existent');

      expect(registry.all, hasLength(1));
    });
  });
}
