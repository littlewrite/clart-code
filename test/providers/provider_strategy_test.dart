import 'package:clart_code/src/core/app_config.dart';
import 'package:clart_code/src/providers/llm_provider.dart';
import 'package:clart_code/src/providers/provider_strategy.dart';
import 'package:test/test.dart';

void main() {
  test('openai strategy builds provider and exposes effective base url', () {
    const config = AppConfig(
      provider: ProviderKind.openai,
      openAiApiKey: 'sk-test-1234',
      openAiBaseUrl: 'https://www.dmxapi.com/v1',
      model: 'qwen3.5-plus-2026-02-15',
    );

    final strategy = providerStrategyFor(ProviderKind.openai);
    final provider = strategy.build(config);

    expect(provider, isA<OpenAiApiProvider>());
    expect(strategy.apiKey(config), 'sk-test-1234');
    expect(strategy.configuredBaseUrl(config), 'https://www.dmxapi.com/v1');
    expect(strategy.effectiveBaseUrl(config), 'https://www.dmxapi.com/v1');
    expect(strategy.buildSetupHint(config), isNull);
  });

  test('local strategy reports init hint and local summary', () {
    const config = AppConfig(provider: ProviderKind.local);
    final strategy = providerStrategyFor(ProviderKind.local);

    expect(strategy.buildSetupHint(config), contains('Run /init'));
    expect(strategy.buildStartupHint(config), contains('Run /init'));
    expect(
      strategy.buildConfigSummaryLines(config),
      const ['auth=not required (local provider)'],
    );
  });
}
