import 'clart_code_agent.dart';
import 'sdk_models.dart';

Stream<ClartCodeSdkMessage> query({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
}) async* {
  final agent = ClartCodeAgent(options);
  try {
    yield* agent.query(prompt, model: model);
  } finally {
    await agent.close();
  }
}

Future<ClartCodePromptResult> prompt({
  required String prompt,
  ClartCodeAgentOptions options = const ClartCodeAgentOptions(),
  String? model,
}) async {
  final agent = ClartCodeAgent(options);
  try {
    return await agent.prompt(prompt, model: model);
  } finally {
    await agent.close();
  }
}
