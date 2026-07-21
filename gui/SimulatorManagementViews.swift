import SwiftUI

enum SimulatorManagementSheet: Identifiable {
  case clone(SimulatorDevice)
  case slimmingRecommendation([SimulatorDevice])
  case rename(SimulatorDevice)
  case erase([SimulatorDevice])
  case delete([SimulatorDevice])
  case diskCleanup([SimulatorDevice], [DiskCleanupCategory])

  var id: String {
    switch self {
    case .clone(let device): return "clone-\(device.udid)"
    case .slimmingRecommendation(let devices):
      return "slimming-recommendation-" + devices.map(\.udid).joined(separator: ",")
    case .rename(let device): return "rename-\(device.udid)"
    case .erase(let devices): return "erase-" + devices.map(\.udid).joined(separator: ",")
    case .delete(let devices): return "delete-" + devices.map(\.udid).joined(separator: ",")
    case .diskCleanup(let devices, let categories):
      return "disk-cleanup-"
        + devices.map(\.udid).joined(separator: ",")
        + "-"
        + categories.map(\.id).sorted().joined(separator: ",")
    }
  }
}

struct SlimmingRecommendationSheet: View {
  @Environment(\.dismiss) private var dismiss

  let devices: [SimulatorDevice]
  let onClone: (SimulatorDevice) -> Void
  let onContinue: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 13) {
        Image(systemName: "plus.square.on.square")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.blue)
          .frame(width: 44, height: 44)
          .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

        VStack(alignment: .leading, spacing: 4) {
          Text("Clone Before Slimming?")
            .font(.title2.bold())
          Text(
            "We recommend making a clone before applying a service profile, so your current apps, data, settings, and simulator state remain available if anything unexpected happens."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 7) {
        Label("Backup or general-purpose simulator", systemImage: "externaldrive.badge.timemachine")
          .font(.subheadline.weight(.semibold))
        Text(
          "The clone is an independent simulator. Keep it as a point-in-time backup, or continue using it normally for development and testing."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

      if devices.count > 1 {
        Label(
          "To create backups for multiple selections, clone each simulator from its row menu or select one simulator at a time in the toolbar.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        if let device = devices.first, devices.count == 1 {
          Button("Clone Simulator") {
            dismiss()
            onClone(device)
          }
        }
        Button("Continue Without Clone") {
          dismiss()
          onContinue()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 590)
  }
}

struct SimulatorNameSheet: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameIsFocused: Bool
  @State private var name: String

  let title: String
  let actionTitle: String
  let systemImage: String
  let explanation: String
  let device: SimulatorDevice
  let onSubmit: (String) -> Void

  init(
    title: String,
    actionTitle: String,
    systemImage: String,
    explanation: String,
    initialName: String,
    device: SimulatorDevice,
    onSubmit: @escaping (String) -> Void
  ) {
    self.title = title
    self.actionTitle = actionTitle
    self.systemImage = systemImage
    self.explanation = explanation
    self.device = device
    self.onSubmit = onSubmit
    _name = State(initialValue: initialName)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 13) {
        Image(systemName: systemImage)
          .font(.system(size: 25, weight: .semibold))
          .foregroundStyle(.blue)
          .frame(width: 44, height: 44)
          .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.title2.bold())
          Text(device.name)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      Text(explanation)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 7) {
        Text("Simulator name")
          .font(.subheadline.weight(.semibold))
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)
          .focused($nameIsFocused)
          .onSubmit(submit)
      }

      HStack(spacing: 6) {
        Text("iOS \(device.osVersion)")
        Text("·")
        Text(device.udid)
          .fontDesign(.monospaced)
          .textSelection(.enabled)
      }
      .font(.caption)
      .foregroundStyle(.tertiary)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(actionTitle, action: submit)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedName.isEmpty || trimmedName.unicodeScalars.count > 128)
      }
    }
    .padding(24)
    .frame(width: 470)
    .onAppear { nameIsFocused = true }
  }

  private func submit() {
    guard !trimmedName.isEmpty, trimmedName.unicodeScalars.count <= 128 else { return }
    let submittedName = trimmedName
    dismiss()
    onSubmit(submittedName)
  }
}

enum SimulatorDestructiveAction {
  case erase
  case delete

  var verb: String {
    switch self {
    case .erase: return "Erase"
    case .delete: return "Delete"
    }
  }

  var systemImage: String {
    switch self {
    case .erase: return "eraser.fill"
    case .delete: return "trash.fill"
    }
  }

  var warning: String {
    switch self {
    case .erase:
      return
        "All apps, data, settings, and service-slimming overrides will be removed. The simulator devices remain available, reset to stock, and shutdown. This cannot be undone."
    case .delete:
      return
        "The selected simulator devices and all of their apps, data, and settings will be permanently removed. This cannot be undone."
    }
  }
}

struct SimulatorDestructiveSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel

  let action: SimulatorDestructiveAction
  let devices: [SimulatorDevice]
  let onConfirm: () -> Void

  private var noun: String {
    devices.count == 1 ? "Simulator" : "Simulators"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 13) {
        Image(systemName: action.systemImage)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.red)
          .frame(width: 44, height: 44)
          .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

        VStack(alignment: .leading, spacing: 3) {
          Text("\(action.verb) \(devices.count) \(noun)?")
            .font(.title2.bold())
          Text(action.warning)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      ScrollView {
        VStack(spacing: 0) {
          ForEach(devices) { device in
            HStack(spacing: 10) {
              Image(systemName: "iphone")
                .foregroundStyle(device.isBooted ? Color.blue : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                  (device.isBooted ? Color.blue : Color.secondary).opacity(0.09),
                  in: RoundedRectangle(cornerRadius: 7)
                )
              VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                  .font(.subheadline.weight(.semibold))
                Text(device.udid)
                  .font(.system(size: 9, design: .monospaced))
                  .foregroundStyle(.tertiary)
                  .textSelection(.enabled)
              }
              Spacer()
              Text(model.diskSizeText(for: device, loadingText: "Calculating…"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
              Text(device.isBooted ? "Booted" : "Shutdown")
                .font(.caption)
                .foregroundStyle(device.isBooted ? Color.blue : Color.secondary)
              Text("iOS \(device.osVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)

            if device.id != devices.last?.id {
              Divider().padding(.leading, 47)
            }
          }
        }
      }
      .frame(maxHeight: 230)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

      if devices.contains(where: \.isBooted) {
        Label("Booted simulators will be shut down first.", systemImage: "power")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("\(action.verb) \(noun)", role: .destructive) {
          dismiss()
          onConfirm()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 640)
  }
}

struct DiskCleanupConfirmationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  @State private var confirmationText = ""

  let devices: [SimulatorDevice]
  let categories: [DiskCleanupCategory]
  let onClone: (SimulatorDevice) -> Void
  let onConfirm: (Set<String>) -> Void

  private var estimatedBytes: Int64 {
    devices.reduce(0) { total, device in
      guard let plan = model.diskCleanupPlans[device.udid] else { return total }
      return total + categories.reduce(0) { $0 + plan.bytes(for: $1.id) }
    }
  }

  private var estimatedSizeText: String {
    ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
  }

  private var isConfirmed: Bool {
    confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CLEAN"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 13) {
        Image(systemName: "externaldrive.badge.xmark")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(.red)
          .frame(width: 44, height: 44)
          .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

        VStack(alignment: .leading, spacing: 4) {
          Text("Permanently Clean \(devices.count) Simulator\(devices.count == 1 ? "" : "s")?")
            .font(.title2.bold())
          Text(
            "Approximately \(estimatedSizeText) will be removed immediately, not moved to Trash. Generated data stays deleted; on-demand language data can be downloaded again by iOS."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 7) {
        Label("Recommended: clone before cleaning", systemImage: "plus.square.on.square")
          .font(.subheadline.weight(.semibold))
        Text(
          "A clone preserves the simulator’s current apps, data, and settings before this permanent cleanup. It can be kept as a backup or used as a normal simulator."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if let device = devices.first, devices.count == 1 {
          Button("Clone Simulator First") {
            dismiss()
            onClone(device)
          }
          .controlSize(.small)
        } else {
          Text(
            "Clone each selected simulator individually from its row menu or the toolbar before continuing."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 8) {
        ForEach(categories) { category in
          HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.orange)
            Text(category.name)
              .font(.subheadline.weight(.medium))
            Spacer()
            Text(categorySizeText(category.id))
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(12)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 6) {
        Label(
          "Erase is not an undo for cleanup data",
          systemImage: "exclamationmark.arrow.triangle.2.circlepath"
        )
        .font(.subheadline.weight(.semibold))
        Text(
          "Deleted caches, logs, and temporary history do not come back. Downloaded language data may return when a feature needs it. Erase is only a way to create a usable fresh simulator if cleanup causes trouble; it also removes every remaining app, setting, and user-data container."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 6) {
        Text("Type CLEAN to continue")
          .font(.subheadline.weight(.semibold))
        TextField("CLEAN", text: $confirmationText)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Clean Disk Data", role: .destructive) {
          let categoryIDs = Set(categories.map(\.id))
          dismiss()
          onConfirm(categoryIDs)
        }
        .disabled(!isConfirmed)
      }
    }
    .padding(24)
    .frame(width: 620)
  }

  private func categorySizeText(_ categoryID: String) -> String {
    let bytes = devices.reduce(0) {
      $0 + (model.diskCleanupPlans[$1.udid]?.bytes(for: categoryID) ?? 0)
    }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
