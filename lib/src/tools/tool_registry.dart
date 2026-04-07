import 'tool_models.dart';

class ToolRegistry {
  ToolRegistry({required List<Tool> tools}) : _byName = _buildMap(tools);

  factory ToolRegistry.empty() => ToolRegistry(tools: const []);

  final Map<String, Tool> _byName;

  Tool? lookup(String name) => _byName[name];

  Iterable<Tool> get all => _byName.values;

  ToolRegistry copy() => ToolRegistry(tools: _byName.values.toList());

  ToolRegistry merged(Iterable<Tool> tools) {
    final registry = copy();
    registry.registerAll(tools.toList(growable: false));
    return registry;
  }

  /// 动态注册工具（用于 MCP 工具）
  void register(Tool tool) {
    if (_byName.containsKey(tool.name)) {
      throw ArgumentError('duplicate tool name: ${tool.name}');
    }
    _byName[tool.name] = tool;
  }

  /// 动态注册多个工具
  void registerAll(List<Tool> tools) {
    for (final tool in tools) {
      register(tool);
    }
  }

  /// 取消注册工具
  void unregister(String name) {
    _byName.remove(name);
  }

  static Map<String, Tool> _buildMap(List<Tool> tools) {
    final byName = <String, Tool>{};
    for (final tool in tools) {
      if (byName.containsKey(tool.name)) {
        throw ArgumentError('duplicate tool name: ${tool.name}');
      }
      byName[tool.name] = tool;
    }
    return byName;
  }
}
