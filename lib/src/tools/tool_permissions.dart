enum ToolPermissionMode { allow, deny, ask }

class ToolPermissionRule {
  const ToolPermissionRule({
    required this.toolName,
    required this.mode,
    this.description,
  });

  final String toolName;
  final ToolPermissionMode mode;
  final String? description;

  Map<String, Object?> toJson() {
    return {
      'toolName': toolName,
      'mode': mode.name,
      'description': description,
    };
  }

  factory ToolPermissionRule.fromJson(Map<String, Object?> json) {
    return ToolPermissionRule(
      toolName: json['toolName'] as String,
      mode: ToolPermissionMode.values.byName(json['mode'] as String),
      description: json['description'] as String?,
    );
  }
}

class ToolPermissionPolicy {
  const ToolPermissionPolicy({
    this.defaultMode = ToolPermissionMode.allow,
    this.rules = const {},
  });

  final ToolPermissionMode defaultMode;
  final Map<String, ToolPermissionRule> rules;

  bool canExecute(String toolName) {
    final rule = rules[toolName];
    if (rule != null) {
      return rule.mode == ToolPermissionMode.allow;
    }
    return defaultMode == ToolPermissionMode.allow;
  }

  bool shouldAsk(String toolName) {
    final rule = rules[toolName];
    if (rule != null) {
      return rule.mode == ToolPermissionMode.ask;
    }
    return defaultMode == ToolPermissionMode.ask;
  }

  ToolPermissionPolicy copyWith({
    ToolPermissionMode? defaultMode,
    Map<String, ToolPermissionRule>? rules,
  }) {
    return ToolPermissionPolicy(
      defaultMode: defaultMode ?? this.defaultMode,
      rules: rules ?? this.rules,
    );
  }

  ToolPermissionPolicy withRule(ToolPermissionRule rule) {
    final newRules = Map<String, ToolPermissionRule>.from(rules);
    newRules[rule.toolName] = rule;
    return copyWith(rules: newRules);
  }

  ToolPermissionPolicy withoutRule(String toolName) {
    final newRules = Map<String, ToolPermissionRule>.from(rules);
    newRules.remove(toolName);
    return copyWith(rules: newRules);
  }

  Map<String, Object?> toJson() {
    return {
      'defaultMode': defaultMode.name,
      'rules': rules.values.map((r) => r.toJson()).toList(),
    };
  }

  factory ToolPermissionPolicy.fromJson(Map<String, Object?> json) {
    final defaultMode = ToolPermissionMode.values
        .byName(json['defaultMode'] as String? ?? 'allow');
    final rulesJson = json['rules'] as List? ?? [];
    final rules = <String, ToolPermissionRule>{};
    for (final ruleJson in rulesJson.cast<Map<String, Object?>>()) {
      final rule = ToolPermissionRule.fromJson(ruleJson);
      rules[rule.toolName] = rule;
    }
    return ToolPermissionPolicy(defaultMode: defaultMode, rules: rules);
  }
}
