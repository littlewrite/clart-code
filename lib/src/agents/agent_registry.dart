import '../sdk/sdk_models.dart';

class ClartCodeAgentRegistry {
  ClartCodeAgentRegistry({
    Iterable<ClartCodeAgentDefinition> agents = const [],
  }) {
    registerAll(agents);
  }

  final Map<String, ClartCodeAgentDefinition> _byName =
      <String, ClartCodeAgentDefinition>{};

  ClartCodeAgentDefinition? lookup(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return _byName[normalized];
  }

  bool has(String name) => lookup(name) != null;

  Iterable<ClartCodeAgentDefinition> get all => _byName.values;

  ClartCodeAgentRegistry copy() =>
      ClartCodeAgentRegistry(agents: _byName.values);

  void register(ClartCodeAgentDefinition agent) {
    final name = agent.name.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(agent.name, 'agent.name', 'cannot be empty');
    }
    if (_byName.containsKey(name)) {
      throw ArgumentError('duplicate agent name: $name');
    }
    _byName[name] = agent;
  }

  void registerAll(Iterable<ClartCodeAgentDefinition> agents) {
    for (final agent in agents) {
      register(agent);
    }
  }

  bool unregister(String name) {
    return _byName.remove(name.trim()) != null;
  }

  void clear() {
    _byName.clear();
  }
}
