import Foundation

enum BackendError: LocalizedError {
  case executableMissing
  case commandFailed(arguments: [String], exitCode: Int32, output: String)
  case invalidResponse(command: String, detail: String)

  var errorDescription: String? {
    switch self {
    case .executableMissing:
      return
        "The bundled simslim command could not be found. Rebuild the app with scripts/build-app.sh."
    case .commandFailed(let arguments, let exitCode, let output):
      let command = (["simslim"] + arguments).joined(separator: " ")
      return "\(command) exited with status \(exitCode).\n\n\(output)"
    case .invalidResponse(let command, let detail):
      return "Could not read the response from simslim \(command): \(detail)"
    }
  }
}

struct SimSlimBackend {
  private let executableURL: URL

  init(bundle: Bundle = .main) throws {
    if let override = ProcessInfo.processInfo.environment["SIMSLIM_CLI"], !override.isEmpty {
      executableURL = URL(fileURLWithPath: override)
    } else if let bundled = bundle.url(forResource: "simslim", withExtension: nil) {
      executableURL = bundled
    } else {
      throw BackendError.executableMissing
    }

    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw BackendError.executableMissing
    }
  }

  func devices() async throws -> [SimulatorDevice] {
    try await decode([SimulatorDevice].self, arguments: ["list", "--json"])
  }

  func categories() async throws -> [SlimCategory] {
    try await decode([SlimCategory].self, arguments: ["profiles", "--json"])
  }

  func measure(udid: String) async throws -> SimulatorMeasurement {
    try await decode(SimulatorMeasurement.self, arguments: ["measure", "--json", udid])
  }

  func diskSize(udid: String) async throws -> SimulatorDiskMeasurement {
    try await decode(SimulatorDiskMeasurement.self, arguments: ["size", "--json", udid])
  }

  func diskCleanupCategories() async throws -> [DiskCleanupCategory] {
    try await decode([DiskCleanupCategory].self, arguments: ["disk-categories", "--json"])
  }

  func diskCleanupPlan(udid: String) async throws -> SimulatorDiskCleanupPlan {
    try await decode(SimulatorDiskCleanupPlan.self, arguments: ["disk-plan", "--json", udid])
  }

  func cleanDisk(
    udid: String,
    categoryIDs: Set<String>,
    preserveBootState: Bool
  ) async throws -> SimulatorDiskCleanupResult {
    var arguments = [
      "disk-clean",
      "--json",
      "--confirm",
      "--categories",
      categoryIDs.sorted().joined(separator: ","),
    ]
    if preserveBootState {
      arguments.append("--preserve-boot-state")
    }
    arguments.append(udid)
    return try await decode(SimulatorDiskCleanupResult.self, arguments: arguments)
  }

  func slim(udid: String, exceptCategories: Set<String>, preserveBootState: Bool) async throws
    -> String
  {
    var arguments = ["on"]
    if !exceptCategories.isEmpty {
      arguments.append(contentsOf: ["--except", exceptCategories.sorted().joined(separator: ",")])
    }
    if preserveBootState {
      arguments.append("--preserve-boot-state")
    }
    arguments.append(udid)
    return try await execute(arguments).text
  }

  func restore(udid: String, preserveBootState: Bool) async throws -> String {
    var arguments = ["off"]
    if preserveBootState {
      arguments.append("--preserve-boot-state")
    }
    arguments.append(udid)
    return try await execute(arguments).text
  }

  func clone(udid: String, name: String) async throws -> SimulatorMutationResult {
    try await decode(
      SimulatorMutationResult.self,
      arguments: ["clone", "--json", udid, name]
    )
  }

  func rename(udid: String, name: String) async throws -> String {
    try await execute(["rename", udid, name]).text
  }

  func erase(udid: String) async throws -> String {
    try await execute(["erase", udid]).text
  }

  func delete(udid: String) async throws -> String {
    try await execute(["delete", udid]).text
  }

  private func decode<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
    let output = try await execute(arguments)
    do {
      return try JSONDecoder().decode(type, from: output.data)
    } catch {
      throw BackendError.invalidResponse(
        command: arguments.first ?? "command",
        detail: "\(error.localizedDescription)\n\n\(output.text)"
      )
    }
  }

  private func execute(_ arguments: [String]) async throws -> CommandOutput {
    let executableURL = executableURL
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        let combinedOutput = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput

        do {
          try process.run()
          try? combinedOutput.fileHandleForWriting.close()
          let data = combinedOutput.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()

          let output = CommandOutput(data: data, exitCode: process.terminationStatus)
          if process.terminationStatus == 0 {
            continuation.resume(returning: output)
          } else {
            continuation.resume(
              throwing: BackendError.commandFailed(
                arguments: arguments,
                exitCode: process.terminationStatus,
                output: output.text
              ))
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

private struct CommandOutput {
  let data: Data
  let exitCode: Int32

  var text: String {
    String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
