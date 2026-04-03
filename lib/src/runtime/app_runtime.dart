import '../providers/llm_provider.dart';
import '../services/security_guard.dart';
import '../services/telemetry.dart';
import '../tools/tool_executor.dart';

class AppRuntime {
  AppRuntime({
    required this.provider,
    this.telemetry = const TelemetryService(),
    this.securityGuard = const SecurityGuard(),
    ToolExecutor? toolExecutor,
  }) : toolExecutor = toolExecutor ?? ToolExecutor.minimal();

  final LlmProvider provider;
  final TelemetryService telemetry;
  final SecurityGuard securityGuard;
  final ToolExecutor toolExecutor;
}
