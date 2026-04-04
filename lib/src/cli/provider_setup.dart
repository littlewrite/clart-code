import 'dart:convert';
import 'dart:io';

import '../core/app_config.dart';

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
  switch (config.provider) {
    case ProviderKind.local:
      return const ['auth=not required (local provider)'];
    case ProviderKind.claude:
      return [
        'claude.baseUrl=${config.claudeBaseUrl ?? 'https://api.anthropic.com'}',
        'claude.apiKey=${maskSecret(config.claudeApiKey)}',
      ];
    case ProviderKind.openai:
      return [
        'openai.baseUrl=${config.openAiBaseUrl ?? 'https://api.openai.com/v1'}',
        'openai.apiKey=${maskSecret(config.openAiApiKey)}',
      ];
  }
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
  if (provider == ProviderKind.local) {
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
  if (provider == ProviderKind.claude) {
    next['claudeApiKey'] = trimmedKey;
    if (baseUrl != null && baseUrl.trim().isNotEmpty) {
      next['claudeBaseUrl'] = baseUrl.trim();
    }
  } else {
    next['openAiApiKey'] = trimmedKey;
    if (baseUrl != null && baseUrl.trim().isNotEmpty) {
      next['openAiBaseUrl'] = baseUrl.trim();
    }
  }

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

String? buildProviderSetupHint(AppConfig config) {
  switch (config.provider) {
    case ProviderKind.local:
      return 'Not configured for real LLM. Run /init or clart_code init.';
    case ProviderKind.claude:
      if (config.claudeApiKey?.trim().isEmpty ?? true) {
        return 'Claude is not configured (missing API key). Run /init or clart_code init.';
      }
      return null;
    case ProviderKind.openai:
      if (config.openAiApiKey?.trim().isEmpty ?? true) {
        return 'OpenAI is not configured (missing API key). Run /init or clart_code init.';
      }
      return null;
  }
}

ProviderKind? parseProviderKind(String? value) {
  switch (value?.trim()) {
    case 'local':
      return ProviderKind.local;
    case 'claude':
      return ProviderKind.claude;
    case 'openai':
      return ProviderKind.openai;
    default:
      return null;
  }
}
