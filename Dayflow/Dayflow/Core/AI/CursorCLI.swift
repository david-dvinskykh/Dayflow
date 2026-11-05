import Foundation

/// Cursor's command-line agent (`cursor-agent`, also installed as `agent`).
///
/// Dayflow drives it the same way as Codex: one print-mode run per request, JSON output,
/// the account's default model unless the user picked another with `defaults write`.
enum CursorCLI {
  /// Logged as the model when Dayflow lets the CLI choose (no `--model` flag).
  static let defaultModelLabel = "cursor-default"
  /// Optional model id from `cursor-agent models`, e.g. `defaults write
  /// teleportlabs.com.Dayflow cursorCLIModel sonnet-4.5`.
  static let modelDefaultsKey = "cursorCLIModel"

  static let installCommand = "curl https://cursor.com/install -fsS | bash"
  static let loginCommand = "cursor-agent login"
  static let installURL = URL(string: "https://cursor.com/cli")

  /// Older installs only have `cursor-agent`; newer ones also (or only) have `agent`.
  static let executableExpression =
    #""$(command -v cursor-agent || command -v agent || echo cursor-agent)""#

  static var configuredModel: String? {
    let value =
      UserDefaults.standard.string(forKey: modelDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  static var modelLabel: String { configuredModel ?? defaultModelLabel }

  /// The `--model` value to pass, or nil to use the account default.
  static func cliModel(from model: String?) -> String? {
    guard let model, !model.isEmpty, model != defaultModelLabel else { return nil }
    return model
  }

  /// Version line of the installed CLI, or nil when neither name is on the PATH.
  static func installedVersion() -> String? {
    let result = LoginShellRunner.run(
      "cursor-agent --version 2>/dev/null || agent --version", timeout: 10)
    guard result.exitCode == 0 else { return nil }
    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
    return firstLine.isEmpty ? "Cursor CLI" : firstLine
  }

  static func isInstalled() -> Bool {
    installedVersion() != nil
  }

  // MARK: Images

  /// Screenshots copied into the agent's workspace. The CLI has no image flag, so the agent
  /// reads them with its file tool, which only reaches files inside the workspace.
  struct StagedImages {
    let directory: URL?
    let relativePaths: [String]

    func cleanup() {
      guard let directory else { return }
      try? FileManager.default.removeItem(at: directory)
    }
  }

  static func stageImages(_ imagePaths: [String], in workingDirectory: URL) throws
    -> StagedImages
  {
    guard !imagePaths.isEmpty else { return StagedImages(directory: nil, relativePaths: []) }
    let folderName = "cursor-images-\(UUID().uuidString)"
    let directory = workingDirectory.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var relativePaths: [String] = []
    for (index, path) in imagePaths.enumerated() {
      let source = URL(fileURLWithPath: path)
      let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
      let name = String(format: "frame_%02d.%@", index, ext)
      try FileManager.default.copyItem(
        at: source, to: directory.appendingPathComponent(name, isDirectory: false))
      relativePaths.append("\(folderName)/\(name)")
    }
    return StagedImages(directory: directory, relativePaths: relativePaths)
  }

  static func prompt(_ prompt: String, attaching relativePaths: [String]) -> String {
    guard !relativePaths.isEmpty else { return prompt }
    let list = relativePaths.map { "- " + $0 }.joined(separator: "\n")
    return prompt
      + "\n\nThe screenshots are image files in the workspace, in chronological order. "
      + "Open and look at every one of them with your file reading tool before answering. "
      + "Do not modify any files.\n" + list
  }
}
