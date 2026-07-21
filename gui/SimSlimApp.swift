import SwiftUI

@main
struct SimSlimApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
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
