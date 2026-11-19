import AppKit
import SwiftUI

/// Window restoration can add AppKit's toggle after SwiftUI builds its toolbar.
struct WorkspaceToolbarPolicy: NSViewRepresentable {
  static let sidebarID = "toggle-sidebar"
  static let settingsID = "settings"
  // NavigationSplitView uses its own item in restored WindowGroup windows.
  static let splitSidebarID = NSToolbarItem.Identifier(
    "com.apple.SwiftUI.navigationSplitView.toggleSidebar")

  func makeNSView(context: Context) -> ToolbarPolicyView { ToolbarPolicyView() }
  func updateNSView(_ view: ToolbarPolicyView, context: Context) { view.refresh() }
  static func dismantleNSView(_ view: ToolbarPolicyView, coordinator: ()) {
    view.policy.attach(to: nil)
  }
}

@MainActor final class ToolbarPolicyView: NSView {
  let policy = WorkspaceToolbarController()
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refresh()
  }
  func refresh() {
    policy.attach(to: window)
    policy.scheduleEnforcement()
  }
}

@MainActor final class WorkspaceToolbarController {
  private weak var window: NSWindow?
  private weak var toolbar: NSToolbar?
  private var windowObserver: NSObjectProtocol?
  private var toolbarObservers: [NSObjectProtocol] = []
  private var scheduled = false
  private var applying = false

  func attach(to window: NSWindow?) {
    if self.window !== window {
      if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
      windowObserver = nil
      removeToolbarObservers()
      self.window = window
      if let window {
        windowObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.observeToolbarIfNeeded() }
        }
      }
    }
    observeToolbarIfNeeded()
  }

  private func observeToolbarIfNeeded() {
    guard toolbar !== window?.toolbar else { return }
    removeToolbarObservers()
    toolbar = window?.toolbar
    guard let toolbar else { return }
    for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
      toolbarObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: toolbar, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, !self.applying else { return }
            self.scheduleEnforcement()
          }
        })
    }
    scheduleEnforcement()
  }

  func scheduleEnforcement() {
    guard !scheduled else { return }
    scheduled = true
    // willAddItem is posted before the item appears in toolbar.items.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.scheduled = false
      self.observeToolbarIfNeeded()
      self.enforce()
    }
  }

  private func enforce() {
    guard let toolbar, toolbar === window?.toolbar else { return }
    let sidebar = NSToolbarItem.Identifier(WorkspaceToolbarPolicy.sidebarID)
    let settings = NSToolbarItem.Identifier(WorkspaceToolbarPolicy.settingsID)
    let current = toolbar.items.map(\.itemIdentifier)
    guard current.contains(sidebar) else { return }
    var desired =
      [sidebar]
      + current.filter {
        $0 != .toggleSidebar && $0 != WorkspaceToolbarPolicy.splitSidebarID && $0 != sidebar
          && $0 != settings
      }
    if current.contains(settings) {
      if desired.last != .flexibleSpace { desired.append(.flexibleSpace) }
      desired.append(settings)
    }
    guard current != desired else { return }
    applying = true
    defer { applying = false }
    if #available(macOS 15, *) {
      // AppKit diffs the identifiers, retaining unrelated restored items.
      toolbar.itemIdentifiers = desired
    } else {
      for index in toolbar.items.indices.reversed()
      where toolbar.items[index].itemIdentifier == .toggleSidebar
        || toolbar.items[index].itemIdentifier == WorkspaceToolbarPolicy.splitSidebarID
      {
        toolbar.removeItem(at: index)
      }
      move(sidebar, to: 0, in: toolbar)
      if current.contains(settings) {
        move(settings, to: toolbar.items.count - 1, in: toolbar)
        let last = toolbar.items.count - 1
        if last == 0 || toolbar.items[last - 1].itemIdentifier != .flexibleSpace {
          toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: last)
        }
      }
    }
  }

  private func move(_ identifier: NSToolbarItem.Identifier, to target: Int, in toolbar: NSToolbar) {
    guard let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }),
      index != target
    else { return }
    toolbar.removeItem(at: index)
    toolbar.insertItem(withItemIdentifier: identifier, at: target)
  }

  private func removeToolbarObservers() {
    toolbarObservers.forEach { NotificationCenter.default.removeObserver($0) }
    toolbarObservers = []
    toolbar = nil
  }

  deinit {
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    toolbarObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }
}
