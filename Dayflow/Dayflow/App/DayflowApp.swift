//
//  DayflowApp.swift
//  Dayflow
//

import Sparkle
import SwiftUI

struct AppRootView: View {
  @EnvironmentObject private var categoryStore: CategoryStore
  @State private var whatsNewNote: ReleaseNote? = nil
  @State private var activeWhatsNewVersion: String? = nil
  @State private var shouldMarkWhatsNewSeen = false
  @State private var goalFlowPresentation: DayGoalFlowPresentation? = nil
  @State private var isShowingGettingStartedTour = false
  @State private var isGettingStartedTourReplay = false

  var body: some View {
    ZStack {
      MainView(goalFlowPresentation: $goalFlowPresentation)
        .environmentObject(AppState.shared)
        .environmentObject(categoryStore)

      goalFlowOverlay

      gettingStartedTourOverlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      showGettingStartedTourIfPending()
      guard whatsNewNote == nil else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if let note = WhatsNewConfiguration.pendingReleaseForCurrentBuild() {
          whatsNewNote = note
          activeWhatsNewVersion = note.version
          shouldMarkWhatsNewSeen = true
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
      guard let release = WhatsNewConfiguration.latestRelease() else { return }
      whatsNewNote = release
      activeWhatsNewVersion = release.version
      shouldMarkWhatsNewSeen = release.version == currentAppVersion

      // Analytics: track manual view
      AnalyticsService.shared.capture(
        "whats_new_viewed_manual",
        [
          "version": release.version
        ])
    }
    .onReceive(NotificationCenter.default.publisher(for: .showGettingStartedTour)) { _ in
      isGettingStartedTourReplay = true
      withAnimation(.easeOut(duration: 0.25)) {
        isShowingGettingStartedTour = true
      }
    }
    .sheet(item: $whatsNewNote, onDismiss: handleWhatsNewDismissed) { note in
      ZStack {
        // Backdrop
        Color.black.opacity(0.4)
          .ignoresSafeArea()

        WhatsNewView(releaseNote: note) {
          closeWhatsNew()
        }
      }
      .resolveDayflowTheme()
    }
  }

  @ViewBuilder
  private var goalFlowOverlay: some View {
    if let goalFlowPresentation {
      DayGoalFlowOverlay(
        presentation: goalFlowPresentation,
        onDismiss: {
          withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            self.goalFlowPresentation = nil
          }
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
      .transition(.opacity.combined(with: .scale(scale: 0.985)))
      .zIndex(3)
    }
  }

  @ViewBuilder
  private var gettingStartedTourOverlay: some View {
    if isShowingGettingStartedTour {
      GettingStartedTourOverlay(
        isReplay: isGettingStartedTourReplay, onFinish: finishGettingStartedTour
      )
      .transition(.opacity)
      .zIndex(4)
    }
  }

  private func showGettingStartedTourIfPending() {
    guard UserDefaults.standard.bool(forKey: GettingStarted.Keys.tourPending) else { return }
    // Let the timeline's entrance animation land first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
      withAnimation(.easeOut(duration: 0.25)) {
        isShowingGettingStartedTour = true
      }
    }
  }

  private func finishGettingStartedTour() {
    UserDefaults.standard.set(false, forKey: GettingStarted.Keys.tourPending)
    withAnimation(.easeOut(duration: 0.2)) {
      isShowingGettingStartedTour = false
    }
    isGettingStartedTourReplay = false
  }

  private func closeWhatsNew() {
    whatsNewNote = nil
  }

  private func handleWhatsNewDismissed() {
    guard let version = activeWhatsNewVersion else { return }
    if shouldMarkWhatsNewSeen {
      WhatsNewConfiguration.markReleaseAsSeen(version: version)
      AnalyticsService.shared.capture(
        "whats_new_viewed",
        [
          "version": version,
          "source": "auto",
        ])
    }
    AnalyticsService.shared.capture(
      "whats_new_viewed",
      [
        "version": version,
        "source": "manual",
      ])
    activeWhatsNewVersion = nil
    shouldMarkWhatsNewSeen = false
  }

  private var currentAppVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }
}

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @AppStorage("didOnboard") private var didOnboard = false
  @StateObject private var systemAppearance = SystemAppearanceObserver()
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @AppStorage("useBlankUI") private var useBlankUI = false
  @State private var showVideoLaunch = true
  @State private var contentOpacity = 0.0
  @State private var contentScale = 0.98
  // Must be the shared instance: the agent bridge (AgentWriteHandlers) writes to
  // CategoryStore.shared, and a second in-memory copy here would overwrite those
  // edits on the next UI-triggered save (GitHub issue #375).
  @StateObject private var categoryStore = CategoryStore.shared

  init() {
    // Writing to stdout after its reader has gone away (app launched from a
    // terminal or wrapper that exited) raises SIGPIPE and kills the process.
    // Ignore it so the write simply fails with EPIPE instead.
    signal(SIGPIPE, SIG_IGN)

    // Comment out for production - only use for testing onboarding
    // UserDefaults.standard.set(false, forKey: "didOnboard")
  }

  // Sparkle updater manager
  private let updaterManager = UpdaterManager.shared

  var body: some Scene {
    Window("Dayflow", id: "main") {
      ZStack {
        // Main app UI or onboarding with entrance animation
        Group {
          if didOnboard {
            // Show UI after onboarding
            AppRootView()
            .environmentObject(categoryStore)
            .environmentObject(updaterManager)
          } else if !showVideoLaunch {
            // Onboarding is designed light-only.
            OnboardingFlow()
              .environmentObject(AppState.shared)
              .environmentObject(categoryStore)
              .environmentObject(updaterManager)
              .dayflowTheme(.light)
          }
        }
        .opacity(contentOpacity)
        .scaleEffect(contentScale)
        .animation(.easeOut(duration: 0.3).delay(0.15), value: contentOpacity)
        .animation(.easeOut(duration: 0.3).delay(0.15), value: contentScale)

        // Video overlay on top with scale + opacity exit
        if showVideoLaunch {
          VideoLaunchView()
            .onVideoComplete {
              // Overlapping animations for smooth handoff
              withAnimation(.easeOut(duration: 0.25)) {
                // Start revealing content while video fades
                contentOpacity = 1.0
                contentScale = 1.0
              }

              // Slightly delayed video exit for overlap
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.2)) {
                  showVideoLaunch = false
                }
              }

              dispatchPendingNotificationNavigation(after: 0.3)
            }
            .opacity(showVideoLaunch ? 1 : 0)
            .scaleEffect(showVideoLaunch ? 1 : 1.02)
            .animation(.easeIn(duration: 0.2), value: showVideoLaunch)
            .onAppear {
              // Skip video if opening via notification tap
              if hasPendingNotificationNavigation {
                showVideoLaunch = false
                contentOpacity = 1.0
                contentScale = 1.0
                dispatchPendingNotificationNavigation(after: 0.1)
              }
            }
        }

      }
      // Inline background behind the main app UI only
      .background {
        MainWindowRegistrationView()

        if didOnboard {
          DayflowWindowBackground()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      // Use an explicit scheme even for System; clearing an override can lag until focus changes.
      .preferredColorScheme(
        didOnboard ? appearance.colorScheme(system: systemAppearance.colorScheme) : .light
      )
      .resolveDayflowTheme()
      .resolveStylePreview()
      .onAppear {
        if !showVideoLaunch {
          dispatchPendingNotificationNavigation(after: 0.1)
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        if !showVideoLaunch {
          dispatchPendingNotificationNavigation(after: 0.1)
        }
      }
      .frame(minWidth: 900, maxWidth: .infinity, minHeight: 558, maxHeight: .infinity)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1195, height: 675)

    .commands {
      // Remove the "New Window" command if you want a single window app
      CommandGroup(replacing: .newItem) {}

      // Add custom menu items after the app info section
      CommandGroup(after: .appInfo) {
        Divider()
        Button("Reset Onboarding") {
          // Reset the onboarding flag
          UserDefaults.standard.set(false, forKey: "didOnboard")
          // Reset the saved onboarding step to start from beginning
          UserDefaults.standard.set(0, forKey: "onboardingStep")
          UserDefaults.standard.removeObject(forKey: "onboardingHasPaidAI")
          UserDefaults.standard.removeObject(forKey: CategoryStore.StoreKeys.onboardingSelectedRole)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingAppliedCategoryPreset)
          UserDefaults.standard.removeObject(
            forKey: CategoryStore.StoreKeys.onboardingCategoriesCustomized)
          UserDefaults.standard.removeObject(forKey: "onboardingSelectedProviderID")
          // Force quit and restart the app to show onboarding
          Task { @MainActor in
            AppDelegate.permitTermination(reason: "reset_onboarding")
            NSApp.terminate(nil)
          }
        }
        .keyboardShortcut("R", modifiers: [.command, .shift])
      }

      // Add Sparkle's update menu item
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          updaterManager.checkForUpdates(showUI: true)
        }

        Button("View Release Notes") {
          // Activate the app and bring to foreground
          NSApp.activate(ignoringOtherApps: true)

          // Post notification to show What's New modal
          NotificationCenter.default.post(name: .showWhatsNew, object: nil)
        }
        .keyboardShortcut("N", modifiers: [.command, .shift])
      }

    }
    .defaultSize(width: 1200, height: 800)

  }

  private var hasPendingNotificationNavigation: Bool {
    AppDelegate.pendingNotificationNavigationDestination != nil
  }

  private func dispatchPendingNotificationNavigation(after delay: TimeInterval) {
    guard hasPendingNotificationNavigation else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard let destination = AppDelegate.pendingNotificationNavigationDestination else { return }
      AppDelegate.pendingNotificationNavigationDestination = nil

      switch destination {
      case .daily(let day) where day?.isEmpty == false:
        NotificationCenter.default.post(
          name: .navigateToDaily,
          object: nil,
          userInfo: ["day": day]
        )
      case .daily:
        NotificationCenter.default.post(name: .navigateToDaily, object: nil)
      case .timeline:
        NotificationCenter.default.post(name: .navigateToTimeline, object: nil)
      case .weekly:
        NotificationCenter.default.post(name: .navigateToWeekly, object: nil)
      }
    }
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let analyticsPreferenceChanged = Notification.Name("analyticsPreferenceChanged")
  static let showWhatsNew = Notification.Name("showWhatsNew")
  static let showGettingStartedTour = Notification.Name("showGettingStartedTour")
  static let navigateToDaily = Notification.Name("navigateToDaily")
  static let navigateToWeekly = Notification.Name("navigateToWeekly")
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let hideTimelineFailureToast = Notification.Name("hideTimelineFailureToast")
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
  static let openAccountSettings = Notification.Name("openAccountSettings")
  static let navigateToTimeline = Notification.Name("navigateToTimeline")
}

@MainActor
final class MainWindowController {
  static let shared = MainWindowController()

  private var openWindowAction: OpenWindowAction?
  private var hasPendingOpenRequest = false

  func register(_ openWindowAction: OpenWindowAction) {
    self.openWindowAction = openWindowAction

    if hasPendingOpenRequest {
      hasPendingOpenRequest = false
      openWindowAction(id: "main")
    }
  }

  func showMainWindow() {
    guard let openWindowAction else {
      hasPendingOpenRequest = true
      return
    }

    openWindowAction(id: "main")
  }
}

/// Full-window gradient behind the main app (Figma: dark linear / light radial).
private struct DayflowWindowBackground: View {
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    GeometryReader { proxy in
      if theme.isDark {
        Image("DarkWindowBackground")
          .resizable()
          .interpolation(.high)
          .scaledToFill()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
      } else {
        LightWindowGradient()
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
  }
}

private struct MainWindowRegistrationView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        MainWindowController.shared.register(openWindow)
      }
  }
}
