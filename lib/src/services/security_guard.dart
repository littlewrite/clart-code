class SecurityGuard {
  const SecurityGuard({
    this.enableHardening = false,
    this.enableMaliciousPromptFilter = false,
  });

  final bool enableHardening;
  final bool enableMaliciousPromptFilter;

  bool allowUserInput(String input) {
    if (!enableHardening) {
      return true;
    }

    if (!enableMaliciousPromptFilter) {
      return true;
    }

    // Placeholder policy: keep disabled by default.
    return input.trim().isNotEmpty;
  }
}
