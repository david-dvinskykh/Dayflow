import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Imports the usage CSV exported from cursor.com and shows what Cursor charged, and how
/// much of it was Dayflow's own requests (matched against Dayflow's logged CLI runs).
@MainActor
final class CursorUsageViewModel: ObservableObject {
  @Published private(set) var summary: CursorUsageSummary?
  @Published private(set) var errorMessage: String?
  @Published private(set) var isLoading = false
  @Published private(set) var importedAt: Date?

  /// The last imported export is kept here so the numbers come back after a restart.
  static var storedCSVURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayflow", isDirectory: true)
      .appendingPathComponent("cursor-usage.csv", isDirectory: false)
  }

  private var didLoadStored = false

  func loadStoredIfNeeded() {
    guard !didLoadStored else { return }
    didLoadStored = true
    let url = Self.storedCSVURL
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    load(from: url, keepCopy: false)
  }

  func chooseFile() {
    let panel = NSOpenPanel()
    panel.title = String(localized: "Import Cursor usage CSV")
    panel.allowedContentTypes = [.commaSeparatedText, .plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    load(from: url, keepCopy: true)
  }

  func clear() {
    try? FileManager.default.removeItem(at: Self.storedCSVURL)
    summary = nil
    importedAt = nil
    errorMessage = nil
  }

  private func load(from url: URL, keepCopy: Bool) {
    isLoading = true
    errorMessage = nil
    let destination = Self.storedCSVURL

    Task.detached(priority: .userInitiated) {
      let outcome: Result<(CursorUsageSummary, Date), Error>
      do {
        let text = try String(contentsOf: url, encoding: .utf8)
        let events = try CursorUsageCSV.parse(text)
        if keepCopy {
          try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? FileManager.default.removeItem(at: destination)
          try? text.write(to: destination, atomically: true, encoding: .utf8)
        }
        let first = events.map(\.date).min() ?? Date()
        let last = events.map(\.date).max() ?? Date()
        let calls = StorageManager.shared.fetchChatCLICallWindows(
          from: first.addingTimeInterval(-86_400), to: last.addingTimeInterval(86_400))
        guard let summary = CursorUsageMatcher.summarize(events: events, dayflowCalls: calls)
        else { throw CursorUsageCSV.ParseError.empty }
        let modified =
          (try? FileManager.default.attributesOfItem(atPath: (keepCopy ? destination : url).path))?[
            .modificationDate] as? Date ?? Date()
        outcome = .success((summary, modified))
      } catch {
        outcome = .failure(error)
      }

      await MainActor.run {
        self.isLoading = false
        switch outcome {
        case .success(let (summary, importedAt)):
          self.summary = summary
          self.importedAt = importedAt
          AnalyticsService.shared.capture(
            "cursor_usage_imported",
            ["requests": summary.requests, "dayflow_requests": summary.dayflowRequests])
        case .failure(let error):
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }
}

struct CursorUsageSettingsSection: View {
  @StateObject private var model = CursorUsageViewModel()

  var body: some View {
    SettingsSection(
      title: String(localized: "Cursor usage"),
      subtitle: String(
        localized:
          "Import the CSV from cursor.com → Dashboard → Usage → Export to see what Cursor charged and how much of it was Dayflow."
      ),
      trailing: {
        HStack(spacing: 8) {
          if model.summary != nil {
            SettingsSecondaryButton(title: String(localized: "Clear")) { model.clear() }
          }
          SettingsSecondaryButton(
            title: model.isLoading
              ? String(localized: "Importing…") : String(localized: "Import CSV…"),
            systemImage: "square.and.arrow.down",
            isDisabled: model.isLoading
          ) {
            model.chooseFile()
          }
        }
      }
    ) {
      VStack(alignment: .leading, spacing: 0) {
        if let error = model.errorMessage {
          SettingsStatusDot(state: .bad, label: error)
            .padding(.bottom, 10)
        }
        if let summary = model.summary {
          summaryRows(summary)
          dayTable(summary)
          modelRows(summary)
        } else if model.errorMessage == nil {
          SettingsMetadata(text: String(localized: "No usage imported yet."))
        }
      }
    }
    .onAppear { model.loadStoredIfNeeded() }
  }

  @ViewBuilder
  private func summaryRows(_ summary: CursorUsageSummary) -> some View {
    SettingsRow(label: String(localized: "Period")) {
      SettingsMetadata(
        text: "\(Self.dateText(summary.firstDate)) – \(Self.dateText(summary.lastDate))")
    }
    SettingsRow(
      label: String(localized: "All Cursor usage"),
      subtitle: String(localized: "Everything in the file, including your own work in Cursor.")
    ) {
      SettingsMetadata(
        text:
          "\(Self.money(summary.costUSD)) · \(summary.requests) \(String(localized: "requests")) · \(Self.tokens(summary.tokens))"
      )
    }
    SettingsRow(
      label: String(localized: "Dayflow"),
      subtitle: String(
        localized: "Requests made while Dayflow was running the Cursor CLI for your timeline.")
    ) {
      SettingsMetadata(
        text:
          "\(Self.money(summary.dayflowCostUSD)) · \(summary.dayflowRequests) \(String(localized: "requests")) · \(Self.tokens(summary.dayflowTokens))"
      )
    }
    if let current = summary.currentModel {
      SettingsRow(
        label: String(localized: "Dayflow forecast"),
        subtitle: String(
          localized:
            "Only \(current.model), the model Dayflow uses now: per hour Dayflow ran, an 8-hour day, and 22 such days a month."
        )
      ) {
        SettingsMetadata(
          text:
            "\(Self.money(current.costPerHour))/\(String(localized: "hour")) · \(Self.money(current.costPerHour * 8))/\(String(localized: "day")) · ≈\(Self.money(current.costPerHour * 8 * 22))/\(String(localized: "month"))"
        )
      }
    }
    if let importedAt = model.importedAt {
      SettingsRow(label: String(localized: "Imported"), showsDivider: false) {
        SettingsMetadata(text: Self.dateTimeText(importedAt))
      }
    }
  }

  @ViewBuilder
  private func dayTable(_ summary: CursorUsageSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("By day")
        .font(.custom("Figtree", size: 13))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)
        .padding(.top, 14)
      HStack {
        Text("Day").frame(width: 100, alignment: .leading)
        Text("Requests").frame(width: 80, alignment: .trailing)
        Text("Cost").frame(width: 80, alignment: .trailing)
        Text("Dayflow").frame(width: 120, alignment: .trailing)
      }
      .font(.custom("Figtree", size: 12))
      .foregroundColor(SettingsStyle.secondary)
      ForEach(summary.days.prefix(31)) { day in
        HStack {
          Text(day.id).frame(width: 100, alignment: .leading)
          Text("\(day.requests)").frame(width: 80, alignment: .trailing)
          Text(Self.money(day.costUSD)).frame(width: 80, alignment: .trailing)
          Text(
            day.dayflowRequests > 0
              ? "\(Self.money(day.dayflowCostUSD)) (\(day.dayflowRequests))" : "–"
          )
          .frame(width: 120, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(SettingsStyle.text)
      }
    }
  }

  @ViewBuilder
  private func modelRows(_ summary: CursorUsageSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("By model")
        .font(.custom("Figtree", size: 13))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)
        .padding(.top, 14)
      HStack {
        Text("Model").frame(width: 180, alignment: .leading)
        Text("Requests").frame(width: 80, alignment: .trailing)
        Text("Cost").frame(width: 80, alignment: .trailing)
        Text("Dayflow").frame(width: 120, alignment: .trailing)
      }
      .font(.custom("Figtree", size: 12))
      .foregroundColor(SettingsStyle.secondary)
      ForEach(summary.models) { model in
        let dayflow = summary.dayflowModels.first { $0.id == model.id }
        HStack {
          Text(model.id).frame(width: 180, alignment: .leading)
          Text("\(model.requests)").frame(width: 80, alignment: .trailing)
          Text(Self.money(model.costUSD)).frame(width: 80, alignment: .trailing)
          Text(dayflow.map { "\(Self.money($0.costUSD)) (\($0.requests))" } ?? "–")
            .frame(width: 120, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(SettingsStyle.text)
      }
      Text(
        "A model you also use yourself in Cursor can't be split exactly: requests made while Dayflow was running it count as Dayflow."
      )
      .font(.custom("Figtree", size: 11))
      .foregroundColor(SettingsStyle.secondary)
      .padding(.top, 4)
    }
  }

  private static func money(_ value: Double) -> String {
    String(format: "$%.2f", value)
  }

  private static func tokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM tokens", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.0fk tokens", Double(value) / 1_000) }
    return "\(value) tokens"
  }

  private static func dateText(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .omitted)
  }

  private static func dateTimeText(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }
}
