//
//  SentryHelper.swift
//  Dayflow
//
//  Crash reporting used to go to Sentry. This build keeps everything on the Mac:
//  these local stand-ins keep the breadcrumb call sites compiling, and nothing is sent.
//

import Foundation

enum SentryLevel {
  case debug
  case info
  case warning
  case error
  case fatal
}

/// A diagnostic note. Kept only so existing call sites compile; it is discarded.
final class Breadcrumb {
  var level: SentryLevel
  var category: String
  var message: String?
  var type: String?
  var data: [String: Any]?

  init(level: SentryLevel, category: String) {
    self.level = level
    self.category = category
  }
}

enum SentryHelper {
  static var isEnabled: Bool { false }

  static func setEnabled(_ enabled: Bool) {}

  static func startIfConfigured() {}

  static func addBreadcrumb(_ breadcrumb: Breadcrumb) {}
}
