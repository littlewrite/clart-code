import '../core/app_config.dart';
import 'llm_provider.dart';

abstract class ProviderStrategy {
  const ProviderStrategy();

  ProviderKind get kind;

  String get displayName;

  String get summaryKey;

  bool get isRemote;

  String apiKey(AppConfig config);

  String? configuredBaseUrl(AppConfig config);

  String? effectiveBaseUrl(AppConfig config);

  LlmProvider build(AppConfig config);

  String? buildSetupHint(AppConfig config);

  String? buildStartupHint(AppConfig config);

  List<String> buildConfigSummaryLines(AppConfig config);

  void writeSetupJson(
    Map<String, Object?> json, {
    required String apiKey,
    String? baseUrl,
  });
}

class LocalProviderStrategy extends ProviderStrategy {
  const LocalProviderStrategy();

  @override
  ProviderKind get kind => ProviderKind.local;

  @override
  String get displayName => 'Local';

  @override
  String get summaryKey => 'local';

  @override
  bool get isRemote => false;

  @override
  String apiKey(AppConfig config) => '';

  @override
  String? configuredBaseUrl(AppConfig config) => null;

  @override
  String? effectiveBaseUrl(AppConfig config) => null;

  @override
  LlmProvider build(AppConfig config) => LocalEchoProvider();

  @override
  String? buildSetupHint(AppConfig config) {
    return 'Not configured for real LLM. Run /init or clart_code init.';
  }

  @override
  String? buildStartupHint(AppConfig config) {
    return 'Run /init to connect a real model provider.';
  }

  @override
  List<String> buildConfigSummaryLines(AppConfig config) {
    return const ['auth=not required (local provider)'];
  }

  @override
  void writeSetupJson(
    Map<String, Object?> json, {
    required String apiKey,
    String? baseUrl,
  }) {
    throw ArgumentError.value(
      kind.name,
      'kind',
      'local provider does not support remote setup',
    );
  }
}

class RemoteProviderStrategy extends ProviderStrategy {
  const RemoteProviderStrategy({
    required this.kind,
    required this.displayName,
    required this.summaryKey,
    required this.defaultBaseUrl,
    required this.apiKeySelector,
    required this.baseUrlSelector,
    required this.providerBuilder,
    required this.apiKeyConfigKey,
    required this.baseUrlConfigKey,
  });

  @override
  final ProviderKind kind;

  @override
  final String displayName;

  @override
  final String summaryKey;

  final String defaultBaseUrl;
  final String? Function(AppConfig config) apiKeySelector;
  final String? Function(AppConfig config) baseUrlSelector;
  final LlmProvider Function(AppConfig config) providerBuilder;
  final String apiKeyConfigKey;
  final String baseUrlConfigKey;

  @override
  bool get isRemote => true;

  @override
  String apiKey(AppConfig config) => apiKeySelector(config)?.trim() ?? '';

  @override
  String? configuredBaseUrl(AppConfig config) {
    final value = baseUrlSelector(config)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  @override
  String effectiveBaseUrl(AppConfig config) {
    return configuredBaseUrl(config) ?? defaultBaseUrl;
  }

  @override
  LlmProvider build(AppConfig config) => providerBuilder(config);

  @override
  String? buildSetupHint(AppConfig config) {
    if (apiKey(config).isEmpty) {
      return '$displayName is not configured (missing API key). Run /init or clart_code init.';
    }
    return null;
  }

  @override
  String? buildStartupHint(AppConfig config) {
    if (apiKey(config).isEmpty) {
      return '$displayName API key missing. Run /init.';
    }
    return null;
  }

  @override
  List<String> buildConfigSummaryLines(AppConfig config) {
    return [
      '$summaryKey.baseUrl=${effectiveBaseUrl(config)}',
      '$summaryKey.apiKey=${maskSecret(apiKey(config))}',
    ];
  }

  @override
  void writeSetupJson(
    Map<String, Object?> json, {
    required String apiKey,
    String? baseUrl,
  }) {
    json[apiKeyConfigKey] = apiKey.trim();
    final trimmedBaseUrl = baseUrl?.trim();
    if (trimmedBaseUrl != null && trimmedBaseUrl.isNotEmpty) {
      json[baseUrlConfigKey] = trimmedBaseUrl;
    }
  }
}

const ProviderStrategy localProviderStrategy = LocalProviderStrategy();
const ProviderStrategy claudeProviderStrategy = RemoteProviderStrategy(
  kind: ProviderKind.claude,
  displayName: 'Claude',
  summaryKey: 'claude',
  defaultBaseUrl: 'https://api.anthropic.com',
  apiKeySelector: _claudeApiKey,
  baseUrlSelector: _claudeBaseUrl,
  providerBuilder: _buildClaudeProvider,
  apiKeyConfigKey: 'claudeApiKey',
  baseUrlConfigKey: 'claudeBaseUrl',
);
const ProviderStrategy openAiProviderStrategy = RemoteProviderStrategy(
  kind: ProviderKind.openai,
  displayName: 'OpenAI',
  summaryKey: 'openai',
  defaultBaseUrl: 'https://api.openai.com/v1',
  apiKeySelector: _openAiApiKey,
  baseUrlSelector: _openAiBaseUrl,
  providerBuilder: _buildOpenAiProvider,
  apiKeyConfigKey: 'openAiApiKey',
  baseUrlConfigKey: 'openAiBaseUrl',
);

const List<ProviderStrategy> allProviderStrategies = [
  localProviderStrategy,
  claudeProviderStrategy,
  openAiProviderStrategy,
];

ProviderStrategy providerStrategyFor(ProviderKind kind) {
  return allProviderStrategies.firstWhere(
    (strategy) => strategy.kind == kind,
  );
}

String maskSecret(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return '<missing>';
  }
  if (raw.length <= 6) {
    return '*' * raw.length;
  }
  final visibleSuffix = raw.substring(raw.length - 4);
  return '${'*' * (raw.length - 4)}$visibleSuffix';
}

String? _claudeApiKey(AppConfig config) => config.claudeApiKey;

String? _claudeBaseUrl(AppConfig config) => config.claudeBaseUrl;

String? _openAiApiKey(AppConfig config) => config.openAiApiKey;

String? _openAiBaseUrl(AppConfig config) => config.openAiBaseUrl;

LlmProvider _buildClaudeProvider(AppConfig config) {
  return ClaudeApiProvider(
    apiKey: config.claudeApiKey ?? '',
    baseUrl: config.claudeBaseUrl,
    model: config.model,
  );
}

LlmProvider _buildOpenAiProvider(AppConfig config) {
  return OpenAiApiProvider(
    apiKey: config.openAiApiKey ?? '',
    baseUrl: config.openAiBaseUrl,
    model: config.model,
  );
}
