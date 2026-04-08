import 'skill_models.dart';

class ClartCodeSkillRegistry {
  ClartCodeSkillRegistry({
    Iterable<ClartCodeSkillDefinition> skills = const [],
  }) {
    registerAll(skills);
  }

  final Map<String, ClartCodeSkillDefinition> _byName =
      <String, ClartCodeSkillDefinition>{};
  final Map<String, String> _aliases = <String, String>{};

  ClartCodeSkillDefinition? lookup(String nameOrAlias) {
    final normalized = _normalizeLookup(nameOrAlias);
    if (normalized.isEmpty) {
      return null;
    }
    return _byName[normalized] ?? _byName[_aliases[normalized]];
  }

  bool has(String nameOrAlias) => lookup(nameOrAlias) != null;

  Iterable<ClartCodeSkillDefinition> get all => _byName.values;

  List<ClartCodeSkillDefinition> get userInvocable => _byName.values
      .where((skill) => skill.userInvocable && skill.enabled)
      .toList(growable: false);

  List<ClartCodeSkillDefinition> get modelInvocable => _byName.values
      .where(
        (skill) =>
            skill.userInvocable &&
            !skill.disableModelInvocation &&
            skill.enabled,
      )
      .toList(growable: false);

  ClartCodeSkillRegistry copy() =>
      ClartCodeSkillRegistry(skills: _byName.values);

  void register(ClartCodeSkillDefinition skill) {
    final name = skill.name.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(skill.name, 'skill.name', 'cannot be empty');
    }
    if (_byName.containsKey(name) || _aliases.containsKey(name)) {
      throw ArgumentError('duplicate skill name: $name');
    }

    final aliases = <String>{};
    for (final alias in skill.aliases) {
      final normalized = alias.trim();
      if (normalized.isEmpty || normalized == name) {
        continue;
      }
      if (_byName.containsKey(normalized) || _aliases.containsKey(normalized)) {
        throw ArgumentError('duplicate skill alias: $normalized');
      }
      aliases.add(normalized);
    }

    _byName[name] = skill;
    for (final alias in aliases) {
      _aliases[alias] = name;
    }
  }

  void registerAll(Iterable<ClartCodeSkillDefinition> skills) {
    for (final skill in skills) {
      register(skill);
    }
  }

  bool unregister(String name) {
    final removed = _byName.remove(name);
    if (removed == null) {
      return false;
    }
    for (final alias in removed.aliases) {
      _aliases.remove(alias.trim());
    }
    return true;
  }

  void clear() {
    _byName.clear();
    _aliases.clear();
  }

  String _normalizeLookup(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith('/')) {
      return trimmed;
    }
    return trimmed.substring(1).trimLeft();
  }
}
