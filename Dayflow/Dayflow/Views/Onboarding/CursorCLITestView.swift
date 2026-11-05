import AppKit
import Foundation
import SwiftUI

/// Asks the Cursor CLI a trivial question to check it is installed and signed in.
struct CursorCLITestView: View {
  let onTestComplete: (Bool) -> Void
  var usesOnboardingStyle: Bool = false

  @State private var isTesting = false
  @State private var success = false
  @State private var resultMessage: String?
  @State private var debugOutput: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("We'll ask the Cursor CLI a simple question to verify it's working and signed in.")
        .font(.custom("Figtree", size: usesOnboardingStyle ? 16 : 12))
        .foregroundColor(usesOnboardingStyle ? Color(hex: "898989") : SettingsStyle.secondary)
        .fixedSize(horizontal: false, vertical: true)

      SettingsPrimaryButton(
        title: isTesting ? String(localized: "Testing…") : String(localized: "Test Cursor CLI"),
        systemImage: "bolt.fill",
        isLoading: isTesting,
        isDisabled: isTesting,
        action: runTest
      )

      if success {
        SettingsStatusDot(state: .good, label: String(localized: "Test successful."))
      } else if let resultMessage {
        VStack(alignment: .leading, spacing: 8) {
          SettingsStatusDot(state: .bad, label: resultMessage)
          if let debugOutput {
            ScrollView {
              Text(debugOutput)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(SettingsStyle.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.03))
            )
          }
        }
      }
    }
  }

  private func runTest() {
    guard !isTesting else { return }
    isTesting = true
    success = false
    resultMessage = nil
    debugOutput = nil

    Task.detached {
      let outcome = Self.performTest()
      await MainActor.run {
        isTesting = false
        switch outcome {
        case .success:
          success = true
          AnalyticsService.shared.capture(
            "chat_cli_test_succeeded", ["tool": "cursor", "provider_id": "cursor"])
          onTestComplete(true)
        case .failure(let message, let debug):
          resultMessage = message
          debugOutput = debug
          AnalyticsService.shared.capture(
            "chat_cli_test_failed", ["tool": "cursor", "provider_id": "cursor"])
          onTestComplete(false)
        }
      }
    }
  }

  private enum Outcome {
    case success
    case failure(message: String, debug: String?)
  }

  private static func performTest() -> Outcome {
    guard CursorCLI.isInstalled() else {
      return .failure(
        message: String(
          localized:
            "Cursor CLI not found. Install it with '\(CursorCLI.installCommand)', then run '\(CursorCLI.loginCommand)'."
        ),
        debug: nil)
    }

    do {
      let run = try ChatCLIProcessRunner().run(
        tool: .cursor,
        prompt: String(localized: "What is 2+2? Answer with just the number."),
        workingDirectory: FileManager.default.temporaryDirectory,
        model: CursorCLI.configuredModel,
        timeoutSeconds: 120
      )
      let debug = [
        "Command: \(run.shellCommand ?? "-")",
        "Exit code: \(run.exitCode)",
        "Stdout:\n\(run.rawStdout)",
        "Stderr:\n\(run.stderr)",
      ].joined(separator: "\n")
      if run.exitCode == 0, run.stdout.contains("4") {
        return .success
      }
      let combined = (run.stdout + " " + run.stderr).lowercased()
      if combined.contains("login") || combined.contains("auth")
        || combined.contains("unauthorized") || combined.contains("not logged in")
      {
        return .failure(
          message: String(
            localized:
              "Cursor CLI is not signed in. Run '\(CursorCLI.loginCommand)' in Terminal."),
          debug: debug)
      }
      return .failure(
        message: String(localized: "Cursor CLI did not answer as expected."), debug: debug)
    } catch {
      return .failure(message: error.localizedDescription, debug: nil)
    }
  }
}
