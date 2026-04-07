import 'dart:convert';
import 'dart:io';

import '../core/app_config.dart';
import '../providers/provider_strategy.dart';

Map<String, Object?> readConfigJsonFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return <String, Object?>{};
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map<String, dynamic>) {
      return Map<String, Object?>.from(decoded);
    }
  } catch (_) {
    // Keep auth/status resilient if config file is malformed.
  }
  return <String, Object?>{};
}

AppConfig mergeConfigMapIntoAppConfig(
  AppConfig current,
  Map<String, Object?> raw,
) {
  final parsedProvider = parseProviderKind(raw['provider'] as String?);
  return current.copyWith(
    provider: parsedProvider ?? current.provider,
    model: raw['model'] as String? ?? current.model,
    claudeApiKey: raw['claudeApiKey'] as String? ?? current.claudeApiKey,
    claudeBaseUrl: raw['claudeBaseUrl'] as String? ?? current.claudeBaseUrl,
    openAiApiKey: raw['openAiApiKey'] as String? ?? current.openAiApiKey,
    openAiBaseUrl: raw['openAiBaseUrl'] as String? ?? current.openAiBaseUrl,
  );
}

void printProviderConfigSummary(AppConfig config) {
  for (final line in providerConfigSummaryLines(config)) {
    print(line);
  }
}

List<String> providerConfigSummaryLines(AppConfig config) {
  return providerStrategyFor(config.provider).buildConfigSummaryLines(config);
}

class InlineInitCommandParseResult {
  const InlineInitCommandParseResult({
    this.provider,
    this.apiKey,
    this.baseUrl,
    this.model,
    this.error,
  });

  final ProviderKind? provider;
  final String? apiKey;
  final String? baseUrl;
  final String? model;
  final String? error;
}

class ProviderSetupApplyResult {
  const ProviderSetupApplyResult({
    required this.config,
    required this.status,
    required this.lines,
  });

  final AppConfig config;
  final String status;
  final List<String> lines;
}

InlineInitCommandParseResult parseInlineInitCommand(String input) {
  final tokens = input.trim().split(RegExp(r'\s+'));
  if (tokens.length < 3) {
    return const InlineInitCommandParseResult(
      error:
          'usage: /init <claude|openai> <apiKey> [baseUrl] [model]  (example: /init openai sk-xxx)',
    );
  }
  final parsedProvider = parseProviderKind(tokens[1]);
  if (parsedProvider == null || parsedProvider == ProviderKind.local) {
    return const InlineInitCommandParseResult(
      error: 'provider must be claude|openai',
    );
  }
  final apiKey = tokens[2].trim();
  if (apiKey.isEmpty) {
    return const InlineInitCommandParseResult(
      error: 'api key cannot be empty',
    );
  }
  final baseUrl = tokens.length >= 4 ? tokens[3].trim() : null;
  final model = tokens.length >= 5 ? tokens.sublist(4).join(' ').trim() : null;
  return InlineInitCommandParseResult(
    provider: parsedProvider,
    apiKey: apiKey,
    baseUrl: baseUrl?.isEmpty == true ? null : baseUrl,
    model: model?.isEmpty == true ? null : model,
  );
}

AppConfig saveProviderSetup({
  required AppConfig current,
  required ProviderKind provider,
  required String apiKey,
  String? baseUrl,
  String? model,
  String? configPath,
}) {
  final strategy = providerStrategyFor(provider);
  if (!strategy.isRemote) {
    throw ArgumentError.value(provider, 'provider', 'provider must be remote');
  }
  final trimmedKey = apiKey.trim();
  if (trimmedKey.isEmpty) {
    throw ArgumentError.value(apiKey, 'apiKey', 'api key cannot be empty');
  }
  final resolvedPath = configPath ??
      current.configPath ??
      defaultConfigPath(cwd: Directory.current.path);
  final existing = readConfigJsonFile(resolvedPath);
  final next = Map<String, Object?>.from(existing);

  next['provider'] = provider.name;
  if (model != null && model.trim().isNotEmpty) {
    next['model'] = model.trim();
  }
  strategy.writeSetupJson(next, apiKey: trimmedKey, baseUrl: baseUrl);

  final file = File(resolvedPath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(next),
  );

  return mergeConfigMapIntoAppConfig(
    current.copyWith(configPath: resolvedPath),
    next,
  ).copyWith(configPath: resolvedPath);
}

ProviderSetupApplyResult applyProviderSetup({
  required AppConfig current,
  required ProviderKind provider,
  required String apiKey,
  String? baseUrl,
  String? model,
}) {
  final nextConfig = saveProviderSetup(
    current: current,
    provider: provider,
    apiKey: apiKey,
    baseUrl: baseUrl,
    model: model,
  );
  final hint = buildProviderSetupHint(nextConfig);
  final lines = <String>[
    'configured ${provider.name} -> ${nextConfig.configPath ?? defaultConfigPath(cwd: Directory.current.path)}',
    'provider=${nextConfig.provider.name}',
    'model=${nextConfig.model ?? 'default'}',
    ...providerConfigSummaryLines(nextConfig),
  ];
  lines.add(hint == null ? 'init complete.' : 'hint: $hint');
  return ProviderSetupApplyResult(
    config: nextConfig,
    status: hint ?? 'Initialized provider config.',
    lines: lines,
  );
}

String? buildProviderSetupHint(AppConfig config) {
  return providerStrategyFor(config.provider).buildSetupHint(config);
}

ProviderKind? parseProviderKind(String? value) {
  return parseProviderKindValue(value);
}
