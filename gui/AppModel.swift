import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var devices: [SimulatorDevice] = []
  @Published private(set) var categories: [SlimCategory] = []
  @Published private(set) var diskCleanupCategories: [DiskCleanupCategory] = []
  @Published private(set) var diskCleanupPlans: [String: SimulatorDiskCleanupPlan] = [:]
  @Published private(set) var measurements: [String: SimulatorMeasurement] = [:]
  @Published private(set) var diskSizes: [String: SimulatorDiskMeasurement] = [:]
  @Published private(set) var diskSizeLoadingUDIDs: Set<String> = []
  @Published private(set) var activeOperations: [String: String] = [:]
  @Published private(set) var activity: [ActivityEntry] = []
  @Published private(set) var isRefreshing = false
  @Published private(set) var batchProgress: BatchProgress?
  @Published private(set) var lastUpdated: Date?
  @Published var selectedUDIDs: Set<String> = []
  @Published var keptCategoryIDs: Set<String> = []
  @Published var keptServiceLabels: Set<String> = []
  @Published var selectedDiskCleanupCategoryIDs: Set<String> = []
  @Published var preserveBootState = true
  @Published var presentedError: PresentedError?

  private let backend: SimSlimBackend?
  private var hasLoaded = false
  private var lastKnownDisabled: [String: Int]
  private var diskSizeTask: Task<Void, Never>?
  private var diskReloadRequested = false
  private static let stateCacheKey = "lastKnownManagedDisabled"

  init() {
    lastKnownDisabled =
      UserDefaults.standard
      .dictionary(forKey: Self.stateCacheKey)?
      .compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:]

    do {
      backend = try SimSlimBackend()
    } catch {
      backend = nil
      presentedError = PresentedError(message: error.localizedDescription)
    }
  }

  var isBusy: Bool {
    isRefreshing || batchProgress != nil || !activeOperations.isEmpty
  }

  var disabledDaemonCount: Int {
    categories.reduce(0) { count, category in
      guard !categoryIsKept(category) else { return count }
      return count + category.labels.filter { !keptServiceLabels.contains($0) }.count
    }
  }

  var bootedCount: Int { devices.filter(\.isBooted).count }
  var selectionCount: Int { selectedUDIDs.count }

  var selectedDevices: [SimulatorDevice] {
    devices.filter { selectedUDIDs.contains($0.udid) }
  }

  var diskAnalysisCoversSelection: Bool {
    diskAnalysisCovers(selectedDevices)
  }

  var isAnalyzingDisk: Bool {
    batchProgress?.action == "Analyzing"
  }

  var selectedDiskCleanupBytes: Int64 {
    diskCleanupBytes(for: selectedDevices, categoryIDs: selectedDiskCleanupCategoryIDs)
  }

  var diskStorageRows: [SimulatorDiskStorageMeasurement] {
    guard let device = selectedDevices.first else { return [] }
    return diskCleanupPlans[device.udid]?.storage ?? []
  }

  var canCleanDiskSelection: Bool {
    canCleanDisk(selectedDevices)
  }

  func diskAnalysisCovers(_ devices: [SimulatorDevice]) -> Bool {
    !devices.isEmpty && devices.allSatisfy { diskCleanupPlans[$0.udid] != nil }
  }

  func canCleanDisk(_ devices: [SimulatorDevice]) -> Bool {
    let cleanableIDs = Set(diskCleanupCategories.filter(\.canClean).map(\.id))
    let selectedIDs = selectedDiskCleanupCategoryIDs.intersection(cleanableIDs)
    return diskAnalysisCovers(devices)
      && !selectedIDs.isEmpty
      && diskCleanupBytes(for: devices, categoryIDs: selectedIDs) > 0
  }

  func load() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await refresh(includeCategories: true)
  }

  func refresh(includeCategories: Bool = false) async {
    guard let backend, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      if includeCategories || categories.isEmpty || diskCleanupCategories.isEmpty {
        async let newDevices = backend.devices()
        async let newCategories = backend.categories()
        async let newDiskCleanupCategories = backend.diskCleanupCategories()
        let loaded = try await (newDevices, newCategories, newDiskCleanupCategories)
        devices = loaded.0
        categories = loaded.1
        let shouldSelectDefaults = diskCleanupCategories.isEmpty
        diskCleanupCategories = loaded.2
        if shouldSelectDefaults {
          selectedDiskCleanupCategoryIDs = Set(
            diskCleanupCategories
              .filter { $0.defaultSelected && $0.canClean }
              .map(\.id)
          )
        }
      } else {
        devices = try await backend.devices()
      }

      let available = Set(devices.map(\.udid))
      selectedUDIDs.formIntersection(available)
      diskCleanupPlans = diskCleanupPlans.filter { available.contains($0.key) }
      updateMeasurementsFromDevices()
      updateStateCacheFromLiveDevices()
      lastUpdated = Date()
      scheduleDiskSizeRefresh(for: devices)
    } catch {
      recordFailure("Refresh failed: \(error.localizedDescription)", present: true)
    }
  }

  func slimState(for device: SimulatorDevice) -> ServiceSlimState {
    let cachedOrLiveDisabled = device.managedDisabled ?? lastKnownDisabled[device.udid]
    guard let cachedOrLiveDisabled else { return .unknown }
    // Profile updates can remove a daemon from the slimmable set. Clamp an
    // older shutdown-state cache to the current total until the device boots
    // and supplies a fresh live count.
    let disabled = min(max(cachedOrLiveDisabled, 0), device.managedTotal)
    switch disabled {
    case 0:
      return .stock
    case device.managedTotal:
      return .full(total: device.managedTotal)
    default:
      return .partial(disabled: disabled, total: device.managedTotal)
    }
  }

  func stateIsCached(for device: SimulatorDevice) -> Bool {
    device.managedDisabled == nil && lastKnownDisabled[device.udid] != nil
  }

  func diskSizeText(for device: SimulatorDevice, loadingText: String = "…") -> String {
    if let size = diskSizes[device.udid] {
      return size.sizeText
    }
    return diskSizeLoadingUDIDs.contains(device.udid) ? loadingText : "—"
  }

  func toggleSelection(_ udid: String) {
    if selectedUDIDs.contains(udid) {
      selectedUDIDs.remove(udid)
    } else {
      selectedUDIDs.insert(udid)
    }
  }

  func select(_ udids: Set<String>) {
    selectedUDIDs = udids
  }

  func clearSelection() {
    selectedUDIDs.removeAll()
  }

  func setCategory(_ category: SlimCategory, keptEnabled: Bool) {
    if keptEnabled {
      keptCategoryIDs.insert(category.id)
      keptServiceLabels.subtract(category.labels)
    } else {
      keptCategoryIDs.remove(category.id)
      keptServiceLabels.subtract(category.labels)
    }
  }

  func categoryIsKept(_ category: SlimCategory) -> Bool {
    keptCategoryIDs.contains(category.id)
      || category.labels.allSatisfy { keptServiceLabels.contains($0) }
  }

  func serviceIsKept(_ label: String, in category: SlimCategory) -> Bool {
    categoryIsKept(category) || keptServiceLabels.contains(label)
  }

  func setService(_ label: String, in category: SlimCategory, keptEnabled: Bool) {
    guard category.labels.contains(label) else { return }

    if keptEnabled {
      keptServiceLabels.insert(label)
      if category.labels.allSatisfy({ keptServiceLabels.contains($0) }) {
        keptCategoryIDs.insert(category.id)
        keptServiceLabels.subtract(category.labels)
      }
      return
    }

    if keptCategoryIDs.remove(category.id) != nil {
      keptServiceLabels.formUnion(category.labels)
    }
    keptServiceLabels.remove(label)
  }

  func resetProfile() {
    keptCategoryIDs.removeAll()
    keptServiceLabels.removeAll()
  }

  func setDiskCleanupCategory(_ category: DiskCleanupCategory, selected: Bool) {
    guard category.canClean else { return }
    if selected {
      selectedDiskCleanupCategoryIDs.insert(category.id)
    } else {
      selectedDiskCleanupCategoryIDs.remove(category.id)
    }
  }

  func diskCleanupBytes(for categoryID: String) -> Int64? {
    guard diskAnalysisCoversSelection else { return nil }
    return selectedDevices.reduce(0) {
      $0 + (diskCleanupPlans[$1.udid]?.bytes(for: categoryID) ?? 0)
    }
  }

  func diskCleanupSizeText(for categoryID: String) -> String {
    guard !selectedDevices.isEmpty else { return "—" }
    guard !isAnalyzingDisk else { return "Analyzing…" }
    guard let bytes = diskCleanupBytes(for: categoryID) else {
      return "Pending"
    }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  func diskStorageSizeText(for storageID: String) -> String {
    guard diskAnalysisCoversSelection else { return isAnalyzingDisk ? "Analyzing…" : "Pending" }
    let bytes = selectedDevices.reduce(0) {
      $0 + (diskCleanupPlans[$1.udid]?.storageBytes(for: storageID) ?? 0)
    }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  func selectedDiskCleanupSizeText() -> String {
    guard !selectedDevices.isEmpty else { return "No selection" }
    guard !isAnalyzingDisk else { return "Analyzing…" }
    guard diskAnalysisCoversSelection else { return "Pending" }
    return ByteCountFormatter.string(fromByteCount: selectedDiskCleanupBytes, countStyle: .file)
  }

  func analyzeDiskSelectionIfNeeded() async {
    let missing = selectedDevices.filter { diskCleanupPlans[$0.udid] == nil }
    guard !missing.isEmpty else { return }
    await analyzeDisk(devices: missing)
  }

  func analyzeDiskSelection() async {
    await analyzeDisk(devices: selectedDevices)
  }

  func cleanDisk(_ devices: [SimulatorDevice], categoryIDs: Set<String>) async {
    guard let backend, batchProgress == nil, activeOperations.isEmpty, !devices.isEmpty else {
      return
    }
    let cleanableIDs = Set(diskCleanupCategories.filter(\.canClean).map(\.id))
    let selectedIDs = categoryIDs.intersection(cleanableIDs)
    guard !selectedIDs.isEmpty else { return }
    var failures = 0

    for (index, device) in devices.enumerated() {
      batchProgress = BatchProgress(
        completed: index,
        total: devices.count,
        currentName: device.name,
        action: "Cleaning"
      )
      setOperation("Cleaning disk data…", for: device.udid)
      record(.info, "Cleaning disk data from \(device.name)")

      do {
        let result = try await backend.cleanDisk(
          udid: device.udid,
          categoryIDs: selectedIDs,
          preserveBootState: preserveBootState
        )
        diskCleanupPlans.removeValue(forKey: device.udid)
        record(.success, "Cleaned \(device.name): reclaimed \(result.reclaimedText)")
      } catch {
        failures += 1
        recordFailure(
          "Could not clean \(device.name): \(error.localizedDescription)", present: false)
      }

      clearOperation(for: device.udid)
      batchProgress = BatchProgress(
        completed: index + 1,
        total: devices.count,
        currentName: device.name,
        action: "Cleaning"
      )
    }

    batchProgress = nil
    await refresh()
    finishBatch(action: "Disk cleanup", total: devices.count, failures: failures)
  }

  func measure(_ device: SimulatorDevice) async {
    guard let backend, device.isBooted, activeOperations[device.udid] == nil else { return }
    setOperation("Measuring memory…", for: device.udid)
    defer { clearOperation(for: device.udid) }

    do {
      let measurement = try await backend.measure(udid: device.udid)
      measurements[device.udid] = measurement
      record(
        .success,
        "Measured \(device.name): \(measurement.processes) processes, \(measurement.memoryText)")
    } catch {
      recordFailure(
        "Could not measure \(device.name): \(error.localizedDescription)", present: true)
    }
  }

  func applyProfileToSelection() async {
    await applyProfile(to: selectedDevices)
  }

  func applyProfile(to devices: [SimulatorDevice]) async {
    await runBatch(action: "Applying", devices: devices, restoreToStock: false)
  }

  func applyProfile(to device: SimulatorDevice) async {
    await applyProfile(to: [device])
  }

  func restoreSelection() async {
    await runBatch(action: "Restoring", devices: selectedDevices, restoreToStock: true)
  }

  func restoreOriginalServices(for device: SimulatorDevice) async {
    await runBatch(action: "Restoring", devices: [device], restoreToStock: true)
  }

  func cloneSimulator(_ device: SimulatorDevice, named rawName: String) async {
    guard let backend, batchProgress == nil, activeOperations.isEmpty else { return }
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    setOperation("Cloning simulator…", for: device.udid)
    record(.info, "Cloning \(device.name) as \(name)")
    defer { clearOperation(for: device.udid) }

    do {
      let result = try await backend.clone(udid: device.udid, name: name)
      if let disabled = device.managedDisabled ?? lastKnownDisabled[device.udid] {
        setCachedDisabled(disabled, for: result.udid)
      }
      measurements.removeValue(forKey: result.udid)
      record(.success, "Cloned \(device.name) as \(result.name ?? name)")
      selectedUDIDs = [result.udid]
      await refresh()
    } catch {
      await refresh()
      recordFailure("Could not clone \(device.name): \(error.localizedDescription)", present: true)
    }
  }

  func renameSimulator(_ device: SimulatorDevice, to rawName: String) async {
    guard let backend, batchProgress == nil, activeOperations.isEmpty else { return }
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    setOperation("Renaming simulator…", for: device.udid)
    record(.info, "Renaming \(device.name) to \(name)")
    defer { clearOperation(for: device.udid) }

    do {
      _ = try await backend.rename(udid: device.udid, name: name)
      record(.success, "Renamed \(device.name) to \(name)")
      await refresh()
      selectedUDIDs = [device.udid]
    } catch {
      recordFailure("Could not rename \(device.name): \(error.localizedDescription)", present: true)
    }
  }

  func eraseSimulators(_ devices: [SimulatorDevice]) async {
    await runManagementBatch(.erase, devices: devices)
  }

  func deleteSimulators(_ devices: [SimulatorDevice]) async {
    await runManagementBatch(.delete, devices: devices)
  }

  func bootSimulator(_ device: SimulatorDevice) async {
    guard let backend, batchProgress == nil, activeOperations.isEmpty else { return }
    setOperation("Booting simulator…", for: device.udid)
    record(.info, "Booting \(device.name)")
    defer { clearOperation(for: device.udid) }

    do {
      _ = try await backend.boot(udid: device.udid)
      record(.success, "Booted \(device.name)")
      await refresh()
    } catch {
      recordFailure("Could not boot \(device.name): \(error.localizedDescription)", present: true)
    }
  }

  func shutdownSimulator(_ device: SimulatorDevice) async {
    guard let backend, batchProgress == nil, activeOperations.isEmpty else { return }
    setOperation("Shutting down simulator…", for: device.udid)
    record(.info, "Shutting down \(device.name)")
    defer { clearOperation(for: device.udid) }

    do {
      _ = try await backend.shutdown(udid: device.udid)
      record(.success, "Shut down \(device.name)")
      await refresh()
    } catch {
      recordFailure(
        "Could not shut down \(device.name): \(error.localizedDescription)", present: true)
    }
  }

  func clearActivity() {
    activity.removeAll()
  }

  private func runBatch(action: String, devices snapshot: [SimulatorDevice], restoreToStock: Bool)
    async
  {
    guard batchProgress == nil, activeOperations.isEmpty, !snapshot.isEmpty else { return }
    var failures = 0

    for (index, device) in snapshot.enumerated() {
      batchProgress = BatchProgress(
        completed: index,
        total: snapshot.count,
        currentName: device.name,
        action: action
      )

      let succeeded: Bool
      if restoreToStock {
        succeeded = await restore(device, presentErrors: false)
      } else {
        succeeded = await slim(device, presentErrors: false)
      }
      if !succeeded { failures += 1 }

      batchProgress = BatchProgress(
        completed: index + 1,
        total: snapshot.count,
        currentName: device.name,
        action: action
      )
    }

    batchProgress = nil
    await refresh()
    finishBatch(
      action: restoreToStock ? "Restore" : "Profile update", total: snapshot.count,
      failures: failures)
  }

  private func diskCleanupBytes(
    for devices: [SimulatorDevice],
    categoryIDs: Set<String>
  ) -> Int64 {
    devices.reduce(0) { total, device in
      guard let plan = diskCleanupPlans[device.udid] else { return total }
      return total
        + categoryIDs.reduce(0) {
          $0 + plan.bytes(for: $1)
        }
    }
  }

  private func analyzeDisk(devices snapshot: [SimulatorDevice]) async {
    guard let backend, batchProgress == nil, activeOperations.isEmpty, !snapshot.isEmpty else {
      return
    }
    var failures = 0

    for (index, device) in snapshot.enumerated() {
      batchProgress = BatchProgress(
        completed: index,
        total: snapshot.count,
        currentName: device.name,
        action: "Analyzing"
      )

      do {
        diskCleanupPlans[device.udid] = try await backend.diskCleanupPlan(udid: device.udid)
      } catch {
        failures += 1
        recordFailure(
          "Could not analyze \(device.name): \(error.localizedDescription)", present: false)
      }

      batchProgress = BatchProgress(
        completed: index + 1,
        total: snapshot.count,
        currentName: device.name,
        action: "Analyzing"
      )
    }

    batchProgress = nil
    if failures == 0 {
      record(.success, "Disk analysis finished for all \(snapshot.count) selected simulators")
    } else {
      finishBatch(action: "Disk analysis", total: snapshot.count, failures: failures)
    }
  }

  private func runManagementBatch(
    _ action: SimulatorManagementBatch, devices snapshot: [SimulatorDevice]
  ) async {
    guard let backend, batchProgress == nil, activeOperations.isEmpty, !snapshot.isEmpty else {
      return
    }
    var failures = 0

    for (index, device) in snapshot.enumerated() {
      batchProgress = BatchProgress(
        completed: index,
        total: snapshot.count,
        currentName: device.name,
        action: action.progressTitle
      )
      setOperation(action.operationTitle, for: device.udid)
      record(.info, "\(action.progressTitle) \(device.name)")

      do {
        switch action {
        case .erase:
          _ = try await backend.erase(udid: device.udid)
          measurements.removeValue(forKey: device.udid)
          setCachedDisabled(0, for: device.udid)
        case .delete:
          _ = try await backend.delete(udid: device.udid)
          measurements.removeValue(forKey: device.udid)
          diskSizes.removeValue(forKey: device.udid)
          diskSizeLoadingUDIDs.remove(device.udid)
          removeCachedDisabled(for: device.udid)
          selectedUDIDs.remove(device.udid)
        }
        record(.success, "\(action.pastTenseTitle) \(device.name)")
      } catch {
        failures += 1
        recordFailure(
          "Could not \(action.verb) \(device.name): \(error.localizedDescription)", present: false)
      }

      clearOperation(for: device.udid)
      batchProgress = BatchProgress(
        completed: index + 1,
        total: snapshot.count,
        currentName: device.name,
        action: action.progressTitle
      )
    }

    batchProgress = nil
    await refresh()
    finishBatch(action: action.completionTitle, total: snapshot.count, failures: failures)
  }

  private func slim(_ device: SimulatorDevice, presentErrors: Bool) async -> Bool {
    guard let backend else { return false }
    setOperation("Applying service profile…", for: device.udid)
    record(.info, "Applying service profile to \(device.name)")
    defer { clearOperation(for: device.udid) }

    do {
      let output = try await backend.slim(
        udid: device.udid,
        exceptCategories: keptCategoryIDs,
        keepLabels: keptServiceLabels,
        preserveBootState: preserveBootState
      )
      setCachedDisabled(disabledDaemonCount, for: device.udid)
      record(.success, "Updated \(device.name): \(summaryLine(output))")
      return true
    } catch {
      recordFailure(
        "Could not slim \(device.name): \(error.localizedDescription)", present: presentErrors)
      return false
    }
  }

  private func restore(_ device: SimulatorDevice, presentErrors: Bool) async -> Bool {
    guard let backend else { return false }
    setOperation("Restoring stock services…", for: device.udid)
    record(.info, "Restoring \(device.name) to stock")
    defer { clearOperation(for: device.udid) }

    do {
      let output = try await backend.restore(
        udid: device.udid, preserveBootState: preserveBootState)
      setCachedDisabled(0, for: device.udid)
      record(.success, "Restored \(device.name): \(summaryLine(output))")
      return true
    } catch {
      recordFailure(
        "Could not restore \(device.name): \(error.localizedDescription)", present: presentErrors)
      return false
    }
  }

  private func finishBatch(action: String, total: Int, failures: Int) {
    if failures == 0 {
      record(.success, "\(action) finished for all \(total) selected simulators")
    } else {
      let message =
        "\(action) finished with \(failures) failure\(failures == 1 ? "" : "s") out of \(total). Check Activity for details."
      recordFailure(message, present: true)
    }
  }

  private func updateStateCacheFromLiveDevices() {
    var changed = false
    for device in devices {
      guard let managedDisabled = device.managedDisabled else { continue }
      if lastKnownDisabled[device.udid] != managedDisabled {
        lastKnownDisabled[device.udid] = managedDisabled
        changed = true
      }
    }
    if changed { persistStateCache() }
  }

  private func updateMeasurementsFromDevices() {
    measurements = Dictionary(
      uniqueKeysWithValues: devices.compactMap { device in
        guard device.isBooted, let memory = device.memory else { return nil }
        return (device.udid, memory)
      })
  }

  private func scheduleDiskSizeRefresh(for snapshot: [SimulatorDevice]) {
    guard let backend else { return }
    guard diskSizeTask == nil else {
      diskReloadRequested = true
      return
    }

    let available = Set(snapshot.map(\.udid))
    diskSizes = diskSizes.filter { available.contains($0.key) }
    diskSizeLoadingUDIDs = available
    diskSizeTask = Task { [weak self] in
      guard let self else { return }
      await self.loadDiskSizes(for: snapshot, backend: backend)
      self.diskSizeTask = nil
      if self.diskReloadRequested {
        self.diskReloadRequested = false
        self.scheduleDiskSizeRefresh(for: self.devices)
      }
    }
  }

  private func loadDiskSizes(for snapshot: [SimulatorDevice], backend: SimSlimBackend) async {
    await withTaskGroup(of: (String, SimulatorDiskMeasurement?).self) { group in
      var nextIndex = 0
      let concurrentMeasurements = min(3, snapshot.count)

      for _ in 0..<concurrentMeasurements {
        let device = snapshot[nextIndex]
        nextIndex += 1
        group.addTask {
          let measurement = try? await backend.diskSize(udid: device.udid)
          return (device.udid, measurement)
        }
      }

      while let (udid, measurement) = await group.next() {
        if devices.contains(where: { $0.udid == udid }), let measurement {
          diskSizes[udid] = measurement
        }
        diskSizeLoadingUDIDs.remove(udid)

        if nextIndex < snapshot.count {
          let device = snapshot[nextIndex]
          nextIndex += 1
          group.addTask {
            let measurement = try? await backend.diskSize(udid: device.udid)
            return (device.udid, measurement)
          }
        }
      }
    }

    let available = Set(devices.map(\.udid))
    diskSizes = diskSizes.filter { available.contains($0.key) }
    diskSizeLoadingUDIDs.formIntersection(available)
  }

  private func setCachedDisabled(_ count: Int, for udid: String) {
    lastKnownDisabled[udid] = count
    persistStateCache()
  }

  private func removeCachedDisabled(for udid: String) {
    lastKnownDisabled.removeValue(forKey: udid)
    persistStateCache()
  }

  private func persistStateCache() {
    UserDefaults.standard.set(lastKnownDisabled, forKey: Self.stateCacheKey)
  }

  private func setOperation(_ message: String, for udid: String) {
    activeOperations[udid] = message
  }

  private func clearOperation(for udid: String) {
    activeOperations.removeValue(forKey: udid)
  }

  private func record(_ level: ActivityEntry.Level, _ message: String) {
    activity.insert(ActivityEntry(level: level, message: message), at: 0)
    if activity.count > 100 {
      activity.removeLast(activity.count - 100)
    }
  }

  private func recordFailure(_ message: String, present: Bool) {
    record(.failure, message)
    if present {
      presentedError = PresentedError(message: message)
    }
  }

  private func summaryLine(_ output: String) -> String {
    output
      .split(separator: "\n")
      .last
      .map(String.init) ?? "Done"
  }
}

private enum SimulatorManagementBatch {
  case erase
  case delete

  var verb: String {
    switch self {
    case .erase: return "erase"
    case .delete: return "delete"
    }
  }

  var progressTitle: String {
    switch self {
    case .erase: return "Erasing"
    case .delete: return "Deleting"
    }
  }

  var operationTitle: String {
    switch self {
    case .erase: return "Erasing simulator…"
    case .delete: return "Deleting simulator…"
    }
  }

  var pastTenseTitle: String {
    switch self {
    case .erase: return "Erased"
    case .delete: return "Deleted"
    }
  }

  var completionTitle: String {
    switch self {
    case .erase: return "Erase"
    case .delete: return "Deletion"
    }
  }
}
