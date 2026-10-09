import Foundation

public enum SystemPolicyVerification {
  public struct Receipt: Encodable {
    public let configuredServices: Int
    public let absentServices: Int
    public let preferences: Int
    public let runtimeVerified = true
  }

  public static func run(output: URL, cancellation: CancellationToken? = nil) throws -> Receipt {
    let policy = try JSON.read(
      OfflineSystemPolicy.Receipt.self,
      from: URL(fileURLWithPath: "/" + OfflineSystemPolicy.receiptPath), limit: 1 << 20)
    try policy.policy.validate()
    let journal = try ExecutionJournal(
      output: output, operation: "verify-system-policy", cancellation: cancellation)
    return try journal.perform {
      var disabled: [String: [String: Bool]] = [:]
      var processes: [String: [String: Int]] = [:]
      for (index, domain) in ["system", "gui/\(policy.uid)"].enumerated() {
        let overrides = try journal.run(
          "overrides-\(index)",
          NativeCommand("/bin/launchctl", arguments: ["print-disabled", domain], timeout: 30))
        disabled[domain] = parseOverrides(try String(contentsOf: overrides, encoding: .utf8))
        let state = try journal.run(
          "services-\(index)",
          NativeCommand("/bin/launchctl", arguments: ["print", domain], timeout: 30))
        processes[domain] = try serviceProcesses(String(contentsOf: state, encoding: .utf8))
      }
      for service in policy.services where service.status == "configured" {
        for domain in service.domains {
          guard disabled[domain]?[service.label] == (service.state == .disabled),
            service.state != .disabled || processes[domain]?[service.label, default: 0] == 0
          else {
            throw MisoError.invalid("System policy is not effective: \(domain)/\(service.label)")
          }
        }
        BuildProgress.write("Verified service \(service.label): \(service.state.rawValue)")
      }
      for service in policy.services where service.status == "not-present" {
        guard !processes.values.contains(where: { $0[service.label] != nil }) else {
          throw MisoError.invalid("Service skipped offline is registered: \(service.label)")
        }
      }
      for preference in policy.preferences {
        let relative = try SafeFile.relativePath(preference.path)
        let plist = try RestoreInspection.plist(
          SafeFile.read(URL(fileURLWithPath: "/" + relative), limit: 1 << 20))
        guard plist[preference.key] as? Bool == preference.value else {
          throw MisoError.invalid("System preference changed: \(relative)/\(preference.key)")
        }
      }
      if let enabled = policy.policy.settings["spotlightIndexing"] {
        for (index, volume) in ["/", "/System/Volumes/Data"].enumerated() {
          let result = try journal.run(
            "spotlight-\(index)",
            NativeCommand("/usr/bin/mdutil", arguments: ["-s", volume], timeout: 30))
          let text = try String(contentsOf: result, encoding: .utf8)
          guard text.contains(enabled ? "Indexing enabled." : "Indexing disabled.") else {
            throw MisoError.invalid("Unexpected Spotlight indexing state: \(volume)")
          }
        }
      }
      return Receipt(
        configuredServices: policy.services.filter { $0.status == "configured" }.count,
        absentServices: policy.services.filter { $0.status == "not-present" }.count,
        preferences: policy.preferences.count)
    }
  }

  static func parseOverrides(_ text: String) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.components(separatedBy: " => ")
      guard parts.count == 2 else { continue }
      let label = parts[0].trimmingCharacters(in: .whitespaces)
      let value = parts[1].trimmingCharacters(in: .whitespaces)
      guard label.first == "\"", label.last == "\"",
        ["true", "false", "disabled", "enabled"].contains(value)
      else { continue }
      result[String(label.dropFirst().dropLast())] = value == "true" || value == "disabled"
    }
    return result
  }

  static func serviceProcesses(_ text: String) throws -> [String: Int] {
    var result: [String: Int] = [:]
    var services = false
    var found = false
    for line in text.split(separator: "\n") {
      if line == "\tservices = {" {
        services = true
        found = true
        continue
      }
      if line == "\t}" { services = false }
      guard services else { continue }
      let parts = line.split(whereSeparator: \.isWhitespace)
      if parts.isEmpty { continue }
      guard parts.count == 3, let pid = parts[0] == "-" ? 0 : Int(parts[0]), pid >= 0 else {
        throw MisoError.invalid("Unrecognized launchd service row")
      }
      result[String(parts[2])] = pid
    }
    guard found, !result.isEmpty else {
      throw MisoError.invalid(
        "Unrecognized launchd service state; refusing to assume services are stopped")
    }
    return result
  }
}
