//
//  ChatCLIRunner.swift
//  Dayflow
//
//  Process execution and JSONL parsing for ChatCLI providers.
//  Handles PTY allocation, shell execution, and streaming event parsing.
//

import AppKit
import Darwin
import Foundation

// MARK: - Core Types

enum ChatCLITool: String, Codable {
  case codex
  case claude
  case cursor

  var providerID: LLMProviderID {
    switch self {
    case .codex:
      return .chatGPT
    case .claude:
      return .claude
    case .cursor:
      return .cursor
    }
  }

  /// What the user runs in Terminal to sign the CLI in.
  var loginCommand: String {
    switch self {
    case .codex: return "codex login"
    case .claude: return "claude login"
    case .cursor: return CursorCLI.loginCommand
    }
  }
}

/// Events emitted during JSONL streaming from CLI tools
enum ChatStreamEvent: Sendable {
  /// Session started with ID (for session persistence)
  case sessionStarted(id: String)
  /// Thinking/reasoning content (shown in collapsible UI)
  case thinking(String)
  /// Tool/command execution started
  case toolStart(command: String)
  /// Tool/command execution completed
  case toolEnd(output: String, exitCode: Int?)
  /// Incremental text chunk from response
  case textDelta(String)
  /// Final complete response
  case complete(text: String)
  /// Error occurred
  case error(String)
}

struct ChatCLIRunResult {
  let exitCode: Int32
  let stdout: String  // Parsed/cleaned response
  let rawStdout: String  // Original stdout for thinking extraction
  let stderr: String
  let shellCommand: String?
  let environmentOverrides: [String: String]
  let startedAt: Date
  let finishedAt: Date
  let usage: TokenUsage?

  /// The CLI's own explanation of a failed run. Claude and Codex often print
  /// the real reason ("OAuth session expired", "usage limit") to stdout and
  /// leave stderr empty, so fall back to stdout before the bare exit code.
  func failureMessage(toolName: String) -> String {
    let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedStderr.isEmpty { return trimmedStderr }

    let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedStdout.isEmpty { return String(trimmedStdout.prefix(1_000)) }

    return "\(toolName) exited with code \(exitCode)"
  }
}

struct TokenUsage: Sendable {
  let input: Int
  let cachedInput: Int
  let cacheCreationInput: Int
  let output: Int

  init(input: Int, cachedInput: Int, cacheCreationInput: Int = 0, output: Int) {
    self.input = input
    self.cachedInput = cachedInput
    self.cacheCreationInput = cacheCreationInput
    self.output = output
  }

  static var zero: TokenUsage {
    TokenUsage(input: 0, cachedInput: 0, cacheCreationInput: 0, output: 0)
  }

  func adding(_ other: TokenUsage?) -> TokenUsage {
    guard let other else { return self }
    return TokenUsage(
      input: input + other.input, cachedInput: cachedInput + other.cachedInput,
      cacheCreationInput: cacheCreationInput + other.cacheCreationInput,
      output: output + other.output)
  }
}
