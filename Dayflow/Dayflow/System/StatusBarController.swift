import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private var cancellable: AnyCancellable?

  /// The live controller, so floating cards (like the Daily brief notice) can
  /// sit under the menu bar icon.
  private(set) static weak var current: StatusBarController?

  override init() {
    super.init()
    Self.current = self
    menu.delegate = self
    statusItem.menu = menu

    if let button = statusItem.button {
      button.imageScaling = .scaleProportionallyDown
      button.imagePosition = .imageOnly

      let isRecording = AppState.shared.isRecording
      button.image = menuBarIcon(isRecording: isRecording)
    }

    // Observe recording state changes and update icon
    cancellable = AppState.shared.$isRecording
      .removeDuplicates()
      .sink { [weak self] isRecording in
        self?.updateIcon(isRecording: isRecording)
      }
  }

  /// Where the menu bar icon is on screen, or nil when macOS is hiding it.
  func iconFrameOnScreen() -> NSRect? {
    guard let button = statusItem.button, let window = button.window, window.isVisible else {
      return nil
    }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  private func updateIcon(isRecording: Bool) {
    statusItem.button?.image = menuBarIcon(isRecording: isRecording)
  }

  private func menuBarIcon(isRecording: Bool) -> NSImage? {
    let name = isRecording ? "MenuBarOnIcon" : "MenuBarOffIcon"
    guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
    image.size = NSSize(width: 22, height: 18)
    return image
  }

  // MARK: - Menu

  // Rebuilt every time the menu opens, so it always reflects the current recording state.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    switch RecordingControl.currentMode() {
    case .active:
      menu.addItem(.sectionHeader(title: String(localized: "Pause Dayflow")))
      menu.addItem(pauseStripItem())
    case .pausedTimed(let endTime):
      let time = endTime.formatted(date: .omitted, time: .shortened)
      menu.addItem(infoItem(String(localized: "Paused until \(time)")))
      menu.addItem(resumeItem())
    case .pausedIndefinite, .stopped:
      menu.addItem(resumeItem())
    }

    menu.addItem(.separator())
    menu.addItem(
      actionItem(String(localized: "Open Dayflow"), #selector(openDayflow), symbol: "macwindow"))
    menu.addItem(actionItem(String(localized: "Open Recordings"), #selector(openRecordingsFolder)))
    menu.addItem(.separator())
    menu.addItem(
      actionItem(
        String(localized: "Quit Completely"), #selector(quitDayflow), keyEquivalent: "q",
        symbol: "power", tint: .systemRed))
  }

  private func resumeItem() -> NSMenuItem {
    actionItem(
      String(localized: "Resume Dayflow"), #selector(resumeRecording), symbol: "play.circle",
      tint: .systemBlue)
  }

  /// A plain menu item. Items without a symbol get a blank one, so every title
  /// lines up after the icon column the way the design lays them out.
  private func actionItem(
    _ title: String, _ action: Selector, keyEquivalent: String = "", symbol: String? = nil,
    tint: NSColor? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    if let symbol {
      let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      item.image =
        tint.flatMap { image?.withSymbolConfiguration(.init(paletteColors: [$0])) } ?? image
    } else {
      item.image = NSImage(size: NSSize(width: 15, height: 13))
    }
    // macOS 27 hides menu item images unless an item asks for them.
    #if compiler(>=6.4)
      if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    #endif
    return item
  }

  /// The horizontal row of pause lengths. Custom views don't close the menu on
  /// click the way normal items do, so the handler closes it first.
  private func pauseStripItem() -> NSMenuItem {
    let strip = StatusMenuPauseStrip(durations: PausePresets.durations) { [weak self] duration in
      self?.menu.cancelTracking()
      PauseManager.shared.pause(for: duration, source: .menuBar)
    }
    let host = NSHostingView(rootView: strip)
    host.frame = NSRect(x: 0, y: 0, width: 220, height: StatusMenuPauseStrip.height)
    host.autoresizingMask = [.width]

    let item = NSMenuItem()
    item.view = host
    return item
  }

  // No action, so the menu shows it greyed out as a status line.
  private func infoItem(_ title: String) -> NSMenuItem {
    NSMenuItem(title: title, action: nil, keyEquivalent: "")
  }

  // MARK: - Actions

  @objc private func resumeRecording() {
    if PauseManager.shared.isPaused {
      PauseManager.shared.resume(source: .userClickedMenuBar)
    } else {
      RecordingControl.start(reason: "user_menu_bar")
    }
  }

  @objc private func openDayflow() {
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if showDockIcon {
      NSApp.setActivationPolicy(.regular)
    }

    NSApp.unhide(nil)
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func openRecordingsFolder() {
    NSWorkspace.shared.open(StorageManager.shared.recordingsRoot)
  }

  @objc private func quitDayflow() {
    AppDelegate.permitTermination(reason: "menu_bar_quit")
    NSApp.terminate(nil)
  }
}
