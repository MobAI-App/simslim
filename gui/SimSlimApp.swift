import AppKit
import SwiftUI

@main
struct SimSlimApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .background(ToolbarDisplayModeConfigurator().frame(width: 0, height: 0))
        .frame(minWidth: 1080, minHeight: 700)
        .task { await model.load() }
    }
    .defaultSize(width: 1260, height: 820)
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(after: .toolbar) {
        Button("Refresh Simulators") {
          Task { await model.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isBusy)
      }
    }
  }
}

private struct ToolbarDisplayModeConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> ToolbarDisplayModeView {
    ToolbarDisplayModeView()
  }

  func updateNSView(_ view: ToolbarDisplayModeView, context: Context) {
    view.applyDisplayMode()
  }
}

private final class ToolbarDisplayModeView: NSView {
  private weak var observedToolbar: NSToolbar?
  private var isArrangingToolbar = false
  private var arrangementIsScheduled = false

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyDisplayMode()
    DispatchQueue.main.async { [weak self] in
      self?.applyDisplayMode()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.applyDisplayMode()
    }
  }

  func applyDisplayMode() {
    guard let toolbar = window?.toolbar else { return }
    observeToolbarChanges(toolbar)
    toolbar.displayMode = .iconAndLabel
    scheduleArrangement(in: toolbar)
  }

  private func observeToolbarChanges(_ toolbar: NSToolbar) {
    guard observedToolbar !== toolbar else { return }

    NotificationCenter.default.removeObserver(self)
    observedToolbar = toolbar

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(toolbarItemsWillChange(_:)),
      name: NSToolbar.willAddItemNotification,
      object: toolbar
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(toolbarItemsDidChange(_:)),
      name: NSToolbar.didRemoveItemNotification,
      object: toolbar
    )
  }

  @objc private func toolbarItemsWillChange(_ notification: Notification) {
    guard !isArrangingToolbar, let toolbar = notification.object as? NSToolbar else { return }
    scheduleArrangement(in: toolbar)
  }

  @objc private func toolbarItemsDidChange(_ notification: Notification) {
    guard !isArrangingToolbar, let toolbar = notification.object as? NSToolbar else { return }
    scheduleArrangement(in: toolbar)
  }

  private func scheduleArrangement(in toolbar: NSToolbar) {
    guard !arrangementIsScheduled else { return }
    arrangementIsScheduled = true

    DispatchQueue.main.async { [weak self, weak toolbar] in
      guard let self else { return }
      self.arrangementIsScheduled = false
      guard let toolbar, toolbar === self.observedToolbar else { return }
      self.arrangeFlexibleSpaces(in: toolbar)
    }
  }

  private func arrangeFlexibleSpaces(in toolbar: NSToolbar) {
    guard !isArrangingToolbar else { return }
    guard toolbar.items.contains(where: { $0.label == "Rename" }) else { return }

    let boundaryLabels = [
      toolbar.items.contains(where: { $0.label == "Unslim" }) ? "Unslim" : "Clean Disk",
      "Delete",
      "Rename",
      "Selection",
    ]

    let spaceIndices = toolbar.items.indices.filter {
      let identifier = toolbar.items[$0].itemIdentifier
      return identifier == .flexibleSpace || identifier == .space
    }

    let spacesAreAlreadyCorrect =
      spaceIndices.count == boundaryLabels.count
      && boundaryLabels.allSatisfy { label in
        guard let index = toolbar.items.firstIndex(where: { $0.label == label }) else {
          return false
        }
        let spaceIndex = index + 1
        guard toolbar.items.indices.contains(spaceIndex) else { return false }
        return toolbar.items[spaceIndex].itemIdentifier == .flexibleSpace
      }
    guard !spacesAreAlreadyCorrect else { return }

    isArrangingToolbar = true
    defer { isArrangingToolbar = false }

    for index in spaceIndices.reversed() {
      toolbar.removeItem(at: index)
    }

    for label in boundaryLabels {
      guard let index = toolbar.items.firstIndex(where: { $0.label == label }) else { continue }
      toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: index + 1)
    }
  }
}
