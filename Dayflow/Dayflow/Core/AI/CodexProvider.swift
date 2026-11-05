import Foundation

/// Runs batches through a print-mode agent CLI: Codex by default, or the Cursor CLI, which
/// takes the same prompts but picks its own model unless the user configured one.
final class CodexProvider: AgentCLISupporting {
  let cliTool: ChatCLITool
  var providerID: LLMProviderID { cliTool.providerID }
  let runner = ChatCLIProcessRunner()
  let config = ChatCLIConfigManager.shared

  init(tool: ChatCLITool = .codex) {
    precondition(tool != .claude, "Claude runs through ClaudeProvider")
    self.cliTool = tool
    config.ensureWorkingDirectory()
  }

  var cliDisplayName: String {
    cliTool == .cursor ? "Cursor CLI" : "Codex CLI"
  }

  /// The Codex model for Codex, or Cursor's configured/default model for Cursor.
  func cliModel(_ codexModel: String) -> String {
    cliTool == .cursor ? CursorCLI.modelLabel : codexModel
  }

  func resolvedModelConfiguration(
    _ codexConfiguration: (model: String, reasoningEffort: String?)
  ) -> (model: String, reasoningEffort: String?) {
    guard cliTool == .cursor else { return codexConfiguration }
    return (model: CursorCLI.modelLabel, reasoningEffort: nil)
  }

  static func availabilityFallback(for model: String, error: Error, stderr: String? = nil)
    -> String?
  {
    let nsError = error as NSError
    let text = [
      error.localizedDescription, stderr ?? "",
      nsError.userInfo["partialStderr"] as? String ?? "",
    ].joined(separator: "\n").lowercased()
    guard
      ![
        "invalid_api_key", "insufficient_quota", "usage limit", "country, region",
        "failed to refresh token",
      ].contains(where: { text.contains($0) })
    else { return nil }
    let pattern =
      #"model_not_found|unsupported_model|unknown model|model not found|\bmodel\b[^\r\n]{0,160}(?:does not exist|not available|not supported|(?:do not|don't|not) have access)"#
    guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
    switch model {
    case "gpt-6.1-sol": return "gpt-5.6-sol"
    case "gpt-6-luna": return "gpt-5.6-luna"
    default: return nil
    }
  }

  static func recordModelFallback(from: String, to: String, operation: String) {
    AnalyticsService.shared.capture(
      "llm_model_fallback",
      [
        "provider": "chat_cli", "provider_id": LLMProviderID.chatGPT.rawValue,
        "operation": operation, "from_model": from, "to_model": to,
        "reason": "model_unavailable",
      ])
  }
}
