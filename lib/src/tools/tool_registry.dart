import 'tool_models.dart';

class ToolRegistry {
  ToolRegistry({required List<Tool> tools}) : _byName = _buildMap(tools);

  final Map<String, Tool> _byName;

  Tool? lookup(String name) => _byName[name];

  Iterable<Tool> get all => _byName.values;

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
