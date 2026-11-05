import Foundation

/// One row of the usage export from cursor.com (Dashboard → Usage → Export CSV).
struct CursorUsageEvent: Equatable, Sendable {
  let date: Date
  let kind: String
  let model: String
  let cacheWriteTokens: Int
  let inputTokens: Int
  let cacheReadTokens: Int
  let outputTokens: Int
  let totalTokens: Int
  /// Charged amount in dollars; 0 for rows Cursor marks "Free".
  let costUSD: Double
}

/// A Dayflow call to an agent CLI, from the `llm_calls` table.
struct CursorUsageCallWindow: Equatable, Sendable {
  let start: Date
  let end: Date
  let model: String?
}

enum CursorUsageCSV {
  enum ParseError: LocalizedError, Equatable {
    case empty
    case missingColumns([String])

    var errorDescription: String? {
      switch self {
      case .empty:
        return String(localized: "The file has no usage rows.")
      case .missingColumns(let columns):
        return String(
          localized:
            "This doesn't look like a Cursor usage export. Missing columns: \(columns.joined(separator: ", "))."
        )
      }
    }
  }

  static func parse(_ text: String) throws -> [CursorUsageEvent] {
    let table = rows(text).filter { row in !row.allSatisfy { $0.isEmpty } }
    guard let header = table.first else { throw ParseError.empty }

    var index: [String: Int] = [:]
    for (position, name) in header.enumerated() {
      index[normalized(name)] = position
    }
    let required = ["date", "model", "cost"]
    let missing = required.filter { index[$0] == nil }
    guard missing.isEmpty else { throw ParseError.missingColumns(missing) }

    func value(_ row: [String], _ column: String) -> String {
      guard let position = index[column], position < row.count else { return "" }
      return row[position].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func int(_ row: [String], _ column: String) -> Int {
      Int(value(row, column).replacingOccurrences(of: ",", with: "")) ?? 0
    }

    let events = table.dropFirst().compactMap { row -> CursorUsageEvent? in
      guard let date = parseDate(value(row, "date")) else { return nil }
      return CursorUsageEvent(
        date: date,
        kind: value(row, "kind"),
        model: value(row, "model"),
        cacheWriteTokens: int(row, "input (w/ cache write)"),
        inputTokens: int(row, "input (w/o cache write)"),
        cacheReadTokens: int(row, "cache read"),
        outputTokens: int(row, "output tokens"),
        totalTokens: int(row, "total tokens"),
        costUSD: parseCost(value(row, "cost"))
      )
    }
    guard !events.isEmpty else { throw ParseError.empty }
    return events
  }

  /// RFC 4180 rows: quoted fields may hold commas, line breaks and doubled quotes.
  static func rows(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var iterator = text.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = nil

    func next() -> Unicode.Scalar? {
      if let scalar = pending {
        pending = nil
        return scalar
      }
      return iterator.next()
    }

    while let scalar = next() {
      if inQuotes {
        if scalar == "\"" {
          if let following = next() {
            if following == "\"" {
              field.unicodeScalars.append("\"")
            } else {
              inQuotes = false
              pending = following
            }
          } else {
            inQuotes = false
          }
        } else {
          field.unicodeScalars.append(scalar)
        }
        continue
      }
      switch scalar {
      case "\"":
        inQuotes = true
      case ",":
        row.append(field)
        field = ""
      case "\r":
        if let following = next(), following != "\n" { pending = following }
        row.append(field)
        rows.append(row)
        row = []
        field = ""
      case "\n":
        row.append(field)
        rows.append(row)
        row = []
        field = ""
      default:
        field.unicodeScalars.append(scalar)
      }
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }

  static func parseCost(_ raw: String) -> Double {
    let cleaned = raw.replacingOccurrences(of: "$", with: "")
      .replacingOccurrences(of: ",", with: "")
      .trimmingCharacters(in: .whitespaces)
    return Double(cleaned) ?? 0
  }

  static func parseDate(_ raw: String) -> Date? {
    guard !raw.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
  }

  private static func normalized(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
      .lowercased()
  }
}

struct CursorUsageSummary: Equatable, Sendable {
  struct Day: Identifiable, Equatable, Sendable {
    /// Local calendar day, "yyyy-MM-dd".
    let id: String
    var requests = 0
    var costUSD = 0.0
    var tokens = 0
    var dayflowRequests = 0
    var dayflowCostUSD = 0.0
  }

  struct ModelTotal: Identifiable, Equatable, Sendable {
    let id: String
    var requests = 0
    var costUSD = 0.0
  }

  let firstDate: Date
  let lastDate: Date
  let requests: Int
  let costUSD: Double
  let tokens: Int
  let dayflowRequests: Int
  let dayflowCostUSD: Double
  let dayflowTokens: Int
  /// Newest first.
  let days: [Day]
  /// Most expensive first.
  let models: [ModelTotal]

  var dayflowAverageCostPerRequest: Double? {
    dayflowRequests > 0 ? dayflowCostUSD / Double(dayflowRequests) : nil
  }

  var dayflowActiveDays: Int { days.filter { $0.dayflowRequests > 0 }.count }

  var dayflowAverageCostPerActiveDay: Double? {
    dayflowActiveDays > 0 ? dayflowCostUSD / Double(dayflowActiveDays) : nil
  }
}

enum CursorUsageMatcher {
  /// Cursor stamps a request when it is billed, which can fall a little before or after the
  /// span Dayflow logged for the CLI run.
  static let tolerance: TimeInterval = 120

  static func isDayflowEvent(_ event: CursorUsageEvent, calls: [CursorUsageCallWindow]) -> Bool {
    calls.contains { call in
      guard
        event.date >= call.start.addingTimeInterval(-tolerance),
        event.date <= call.end.addingTimeInterval(tolerance)
      else { return false }
      guard let model = call.model, !model.isEmpty else { return true }
      return model == CursorCLI.defaultModelLabel
        || model.caseInsensitiveCompare(event.model) == .orderedSame
    }
  }

  static func summarize(
    events: [CursorUsageEvent],
    dayflowCalls: [CursorUsageCallWindow],
    calendar: Calendar = .current
  ) -> CursorUsageSummary? {
    guard let first = events.map(\.date).min(), let last = events.map(\.date).max() else {
      return nil
    }

    let dayFormatter = DateFormatter()
    dayFormatter.calendar = calendar
    dayFormatter.timeZone = calendar.timeZone
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.dateFormat = "yyyy-MM-dd"

    var days: [String: CursorUsageSummary.Day] = [:]
    var models: [String: CursorUsageSummary.ModelTotal] = [:]
    var totals = (requests: 0, cost: 0.0, tokens: 0)
    var dayflow = (requests: 0, cost: 0.0, tokens: 0)

    for event in events {
      let key = dayFormatter.string(from: event.date)
      var day = days[key] ?? CursorUsageSummary.Day(id: key)
      day.requests += 1
      day.costUSD += event.costUSD
      day.tokens += event.totalTokens

      let modelKey = event.model.isEmpty ? "unknown" : event.model
      var model = models[modelKey] ?? CursorUsageSummary.ModelTotal(id: modelKey)
      model.requests += 1
      model.costUSD += event.costUSD
      models[modelKey] = model

      totals.requests += 1
      totals.cost += event.costUSD
      totals.tokens += event.totalTokens

      if isDayflowEvent(event, calls: dayflowCalls) {
        day.dayflowRequests += 1
        day.dayflowCostUSD += event.costUSD
        dayflow.requests += 1
        dayflow.cost += event.costUSD
        dayflow.tokens += event.totalTokens
      }
      days[key] = day
    }

    return CursorUsageSummary(
      firstDate: first,
      lastDate: last,
      requests: totals.requests,
      costUSD: totals.cost,
      tokens: totals.tokens,
      dayflowRequests: dayflow.requests,
      dayflowCostUSD: dayflow.cost,
      dayflowTokens: dayflow.tokens,
      days: days.values.sorted { $0.id > $1.id },
      models: models.values.sorted { $0.costUSD > $1.costUSD }
    )
  }
}
