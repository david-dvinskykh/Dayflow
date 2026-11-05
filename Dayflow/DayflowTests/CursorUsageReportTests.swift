import XCTest

@testable import Dayflow

final class CursorUsageReportTests: XCTestCase {
  private let header =
    "Date,User,PR Author,Repo,PR Number,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,"
    + "Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost"

  private func row(_ date: String, model: String = "composer-2.5", cost: String) -> String {
    "\"\(date)\",\"me@example.com\",\"\",\"\",\"\",\"\",\"\",\"On-Demand\",\"\(model)\",\"No\","
      + "\"0\",\"19600\",\"392034\",\"3434\",\"415068\",\"\(cost)\""
  }

  func testParsesCursorExportRows() throws {
    let csv = [
      header,
      row("2026-11-05T09:14:38.137Z", cost: "0.09"),
      row("2026-11-04T11:35:05.905Z", cost: "Free"),
    ].joined(separator: "\n")

    let events = try CursorUsageCSV.parse(csv)

    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0].model, "composer-2.5")
    XCTAssertEqual(events[0].inputTokens, 19600)
    XCTAssertEqual(events[0].cacheReadTokens, 392_034)
    XCTAssertEqual(events[0].outputTokens, 3434)
    XCTAssertEqual(events[0].totalTokens, 415_068)
    XCTAssertEqual(events[0].costUSD, 0.09, accuracy: 0.0001)
    XCTAssertEqual(events[1].costUSD, 0)
  }

  func testQuotedFieldsKeepCommasQuotesAndCRLF() {
    let rows = CursorUsageCSV.rows("a,\"b,c\",\"say \"\"hi\"\"\"\r\n1,2,3\r\n")
    XCTAssertEqual(rows, [["a", "b,c", "say \"hi\""], ["1", "2", "3"]])
  }

  func testRejectsFilesThatAreNotCursorExports() {
    XCTAssertThrowsError(try CursorUsageCSV.parse("foo,bar\n1,2")) { error in
      XCTAssertEqual(
        error as? CursorUsageCSV.ParseError, .missingColumns(["date", "model", "cost"]))
    }
  }

  func testAttributesOnlyRequestsInsideDayflowRuns() throws {
    let csv = [
      header,
      row("2026-11-05T09:14:38.000Z", cost: "0.09"),  // during a Dayflow run
      row("2026-11-05T12:00:00.000Z", cost: "1.50"),  // the user's own work
    ].joined(separator: "\n")
    let events = try CursorUsageCSV.parse(csv)
    let runEnd = try XCTUnwrap(CursorUsageCSV.parseDate("2026-11-05T09:14:30Z"))
    let calls = [
      CursorUsageCallWindow(
        start: runEnd.addingTimeInterval(-60), end: runEnd, model: "composer-2.5")
    ]

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let summary = try XCTUnwrap(
      CursorUsageMatcher.summarize(events: events, dayflowCalls: calls, calendar: calendar))

    XCTAssertEqual(summary.requests, 2)
    XCTAssertEqual(summary.costUSD, 1.59, accuracy: 0.0001)
    XCTAssertEqual(summary.dayflowRequests, 1)
    XCTAssertEqual(summary.dayflowCostUSD, 0.09, accuracy: 0.0001)
    XCTAssertEqual(summary.days.map(\.id), ["2026-11-05"])
    XCTAssertEqual(summary.models.first?.id, "composer-2.5")
  }

  func testDifferentModelInsideARunIsNotDayflow() throws {
    let events = try CursorUsageCSV.parse(
      [header, row("2026-11-05T09:14:38.000Z", model: "gpt-5.5", cost: "0.40")]
        .joined(separator: "\n"))
    let runEnd = try XCTUnwrap(CursorUsageCSV.parseDate("2026-11-05T09:14:40Z"))
    let calls = [
      CursorUsageCallWindow(
        start: runEnd.addingTimeInterval(-30), end: runEnd, model: "composer-2.5")
    ]
    XCTAssertFalse(CursorUsageMatcher.isDayflowEvent(events[0], calls: calls))
  }

  func testForecastUsesOnlyTheModelDayflowRunsNow() throws {
    let csv = [
      header,
      // Morning: Dayflow on composer, 1 request in its run window.
      row("2026-11-05T09:37:00.000Z", model: "composer-2.5", cost: "0.90"),
      // Afternoon: Dayflow on luna, two hours with one request each.
      row("2026-11-05T12:10:00.000Z", model: "gpt-5.6-luna-low", cost: "0.20"),
      row("2026-11-05T13:10:00.000Z", model: "gpt-5.6-luna-low", cost: "0.40"),
      // The user's own work, outside any Dayflow run.
      row("2026-11-05T15:00:00.000Z", model: "composer-2.5", cost: "5.00"),
    ].joined(separator: "\n")
    let events = try CursorUsageCSV.parse(csv)
    func window(_ end: String, _ model: String) throws -> CursorUsageCallWindow {
      let end = try XCTUnwrap(CursorUsageCSV.parseDate(end))
      return CursorUsageCallWindow(start: end.addingTimeInterval(-120), end: end, model: model)
    }
    let calls = [
      try window("2026-11-05T09:37:30Z", "composer-2.5"),
      try window("2026-11-05T12:10:30Z", "gpt-5.6-luna-low"),
      try window("2026-11-05T13:10:30Z", "gpt-5.6-luna-low"),
    ]

    let summary = try XCTUnwrap(CursorUsageMatcher.summarize(events: events, dayflowCalls: calls))

    XCTAssertEqual(summary.dayflowRequests, 3)
    XCTAssertEqual(summary.dayflowCostUSD, 1.50, accuracy: 0.0001)
    XCTAssertEqual(summary.dayflowModels.map(\.id), ["composer-2.5", "gpt-5.6-luna-low"])
    let current = try XCTUnwrap(summary.currentModel)
    XCTAssertEqual(current.model, "gpt-5.6-luna-low")
    XCTAssertEqual(current.requests, 2)
    XCTAssertEqual(current.activeHours, 2)
    XCTAssertEqual(current.costPerHour, 0.30, accuracy: 0.0001)
  }
}
