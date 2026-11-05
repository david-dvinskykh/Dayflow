//
//  NotificationBadgeManager.swift
//  Dayflow
//
//  Manages badge state for Dock icon and sidebar indicator.
//

import AppKit
import SwiftUI

@MainActor
final class NotificationBadgeManager: ObservableObject {
  struct PendingDailyRecapContext {
    let targetDay: String?
  }

  static let shared = NotificationBadgeManager()

  /// Whether there's a visible Daily badge the user hasn't acknowledged yet.
  @Published private(set) var hasPendingDailyRecap: Bool = false

  private let defaults = UserDefaults.standard
  private let pendingDailyReadyKey = "notificationBadge.pendingDailyReady"
  private let pendingDailyVisibleKey = "notificationBadge.pendingDailyVisible"
  private let pendingDailyTargetDayKey = "notificationBadge.pendingDailyTargetDay"

  private var hasPendingDailyReady = false
  private var pendingDailyTargetDay: String?

  private init() {
    restoreDailyState()
    refreshDockBadge()
  }

  // MARK: - Public Methods

  /// Tracks that a Daily recap is ready and shows its visible badge.
  func registerDailyRecapReady(forDay day: String) {
    hasPendingDailyReady = true
    hasPendingDailyRecap = true
    pendingDailyTargetDay = day.isEmpty ? nil : day
    persistDailyState()
    refreshDockBadge()
  }

  /// Clears the visible Daily badge from both the Dock and sidebar.
  func clearDailyBadge() {
    hasPendingDailyRecap = false
    persistDailyState()
    refreshDockBadge()
  }

  /// Returns the pending Daily recap context, then marks it as consumed.
  func consumePendingDailyRecapContext() -> PendingDailyRecapContext? {
    guard hasPendingDailyReady else { return nil }

    let context = PendingDailyRecapContext(targetDay: pendingDailyTargetDay)
    clearPendingDailyRecap()
    return context
  }

  private func refreshDockBadge() {
    let count = hasPendingDailyRecap ? 1 : 0
    NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
  }

  private func clearPendingDailyRecap() {
    hasPendingDailyReady = false
    hasPendingDailyRecap = false
    pendingDailyTargetDay = nil
    persistDailyState()
    refreshDockBadge()
  }

  private func persistDailyState() {
    defaults.set(hasPendingDailyReady, forKey: pendingDailyReadyKey)
    defaults.set(hasPendingDailyRecap, forKey: pendingDailyVisibleKey)

    if let pendingDailyTargetDay {
      defaults.set(pendingDailyTargetDay, forKey: pendingDailyTargetDayKey)
    } else {
      defaults.removeObject(forKey: pendingDailyTargetDayKey)
    }
  }

  private func restoreDailyState() {
    hasPendingDailyReady = defaults.bool(forKey: pendingDailyReadyKey)
    hasPendingDailyRecap = defaults.bool(forKey: pendingDailyVisibleKey)
    pendingDailyTargetDay = defaults.string(forKey: pendingDailyTargetDayKey)
  }
}
