import 'dart:convert';
import 'dart:io';

enum ProviderKind { local, claude, openai }

ProviderKind? parseProviderKindValue(String? value) {
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

class AppConfig {
  const AppConfig({
    required this.provider,
    this.model,
    this.claudeApiKey,
    this.claudeBaseUrl,
    this.openAiApiKey,
    this.openAiBaseUrl,
    this.configPath,
  });

  final ProviderKind provider;
  final String? model;
  final String? claudeApiKey;
  final String? claudeBaseUrl;
  final String? openAiApiKey;
  final String? openAiBaseUrl;
  final String? configPath;

  AppConfig copyWith({
    ProviderKind? provider,
    String? model,
    String? claudeApiKey,
    String? claudeBaseUrl,
    String? openAiApiKey,
    String? openAiBaseUrl,
    String? configPath,
  }) {
    return AppConfig(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      claudeApiKey: claudeApiKey ?? this.claudeApiKey,
      claudeBaseUrl: claudeBaseUrl ?? this.claudeBaseUrl,
      openAiApiKey: openAiApiKey ?? this.openAiApiKey,
      openAiBaseUrl: openAiBaseUrl ?? this.openAiBaseUrl,
      configPath: configPath ?? this.configPath,
    );
  }
}

class ConfigLoadResult {
  const ConfigLoadResult({required this.config, this.error});

  final AppConfig? config;
  final String? error;

  bool get isOk => config != null && error == null;
}

class ConfigLoader {
  const ConfigLoader();

  ConfigLoadResult load({
    String? configPath,
    String? providerOverride,
    String? modelOverride,
    String? claudeApiKeyOverride,
    String? claudeBaseUrlOverride,
    String? openAiApiKeyOverride,
    String? openAiBaseUrlOverride,
  }) {
    final env = Platform.environment;
    final effectiveConfigPath = _resolveConfigPath(configPath);

    var config = AppConfig(
      provider:
          parseProviderKindValue(env['CLART_PROVIDER']) ?? ProviderKind.local,
      model: env['CLART_MODEL'],
      claudeApiKey: env['CLAUDE_API_KEY'],
      claudeBaseUrl: env['CLAUDE_BASE_URL'],
      openAiApiKey: env['OPENAI_API_KEY'],
      openAiBaseUrl: env['OPENAI_BASE_URL'],
      configPath: effectiveConfigPath,
    );

    if (effectiveConfigPath != null) {
      final fileResult = _loadFromFile(effectiveConfigPath, config);
      if (!fileResult.isOk) {
        return fileResult;
      }
      config = fileResult.config!;
    }

    final overrideProvider = parseProviderKindValue(providerOverride);
    if (providerOverride != null && overrideProvider == null) {
      return const ConfigLoadResult(
        config: null,
        error: 'invalid provider, expected: local|claude|openai',
      );
    }

    config = config.copyWith(
      provider: overrideProvider ?? config.provider,
      model: modelOverride ?? config.model,
      claudeApiKey: claudeApiKeyOverride ?? config.claudeApiKey,
      claudeBaseUrl: claudeBaseUrlOverride ?? config.claudeBaseUrl,
      openAiApiKey: openAiApiKeyOverride ?? config.openAiApiKey,
      openAiBaseUrl: openAiBaseUrlOverride ?? config.openAiBaseUrl,
    );

    return ConfigLoadResult(config: config);
  }

  String? _resolveConfigPath(String? explicitPath) {
    if (explicitPath != null && explicitPath.trim().isNotEmpty) {
      return explicitPath;
    }
    final fallback = defaultConfigPath();
    if (File(fallback).existsSync()) {
      return fallback;
    }
    return null;
  }

  ConfigLoadResult _loadFromFile(String path, AppConfig current) {
    final file = File(path);
    if (!file.existsSync()) {
      return ConfigLoadResult(
        config: null,
        error: 'config file not found: $path',
      );
    }

    final raw = file.readAsStringSync();
    final decoded = jsonDecode(raw);

    if (decoded is! Map<String, dynamic>) {
      return const ConfigLoadResult(
        config: null,
        error: 'config file must be a JSON object',
      );
    }

    final parsedProvider =
        parseProviderKindValue(decoded['provider'] as String?);
    if (decoded.containsKey('provider') && parsedProvider == null) {
      return const ConfigLoadResult(
        config: null,
        error: 'config provider must be local|claude|openai',
      );
    }

    return ConfigLoadResult(
      config: current.copyWith(
        provider: parsedProvider ?? current.provider,
        model: decoded['model'] as String? ?? current.model,
        claudeApiKey:
            decoded['claudeApiKey'] as String? ?? current.claudeApiKey,
        claudeBaseUrl:
            decoded['claudeBaseUrl'] as String? ?? current.claudeBaseUrl,
        openAiApiKey:
            decoded['openAiApiKey'] as String? ?? current.openAiApiKey,
        openAiBaseUrl:
            decoded['openAiBaseUrl'] as String? ?? current.openAiBaseUrl,
        configPath: path,
      ),
    );
  }
}

String defaultConfigPath({String? cwd}) {
  final base = cwd ?? Directory.current.path;
  return '$base/.clart/config.json';
}
