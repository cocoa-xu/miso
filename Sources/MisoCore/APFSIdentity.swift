import Foundation

public enum APFSIdentity {
  public static func rawVolume(_ device: String) throws -> String {
    guard
      device.range(of: #"\A(?:/dev/)?r?disk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil
    else {
      throw MisoError.invalid("Expected an APFS volume device node")
    }
    let name = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
    return "/dev/r" + (name.hasPrefix("r") ? String(name.dropFirst()) : name)
  }

  public struct SnapshotChange: Encodable, Equatable, Sendable {
    public let snapshot: String
    public let before: Bool
    public let after: Bool
  }

  public static func verifySnapshots(before: [[String: JSONValue]], after: [[String: JSONValue]])
    throws -> [SnapshotChange]
  {
    guard before.count == after.count else {
      throw MisoError.invalid("Snapshot count changed during reseal")
    }
    return try zip(before, after).compactMap { old, new in
      guard case .bool(let previous) = old["LimitingContainerShrink"],
        case .bool(let current) = new["LimitingContainerShrink"],
        case .string(let name) = old["SnapshotName"], !name.isEmpty
      else {
        throw MisoError.invalid("Invalid snapshot allocation marker or name")
      }
      guard
        old.filter({ $0.key != "LimitingContainerShrink" })
          == new.filter({ $0.key != "LimitingContainerShrink" })
      else {
        throw MisoError.invalid("Snapshot identity or boot policy changed during reseal")
      }
      return previous == current
        ? nil : SnapshotChange(snapshot: name, before: previous, after: current)
    }
  }

  public struct Volume: Hashable, Sendable {
    public let device: String
    public let identifier: UUID
    public let roles: [String]

    public init(device: String, identifier: UUID, roles: [String]) throws {
      _ = try rawVolume(device)
      guard !device.hasPrefix("/"), !device.hasPrefix("r"), Set(roles).count == roles.count else {
        throw MisoError.invalid("Invalid APFS volume identity")
      }
      self.device = device
      self.identifier = identifier
      self.roles = roles
    }
  }

  public struct Container: Sendable {
    public let identifier: UUID
    public let volumes: [Volume]

    public init(identifier: UUID, volumes: [Volume]) throws {
      guard Set(volumes.map(\.device)).count == volumes.count,
        Set(volumes.map(\.identifier)).count == volumes.count
      else {
        throw MisoError.invalid("Ambiguous APFS volume identities")
      }
      self.identifier = identifier
      self.volumes = volumes
    }
  }

  public static func resealedSystem(before: Container, after: Container, system: Volume) throws
    -> Volume
  {
    guard before.identifier == after.identifier, system.roles == ["System"],
      before.volumes.contains(system),
      let updated = after.volumes.first(where: { $0.device == system.device }),
      updated.roles == ["System"]
    else {
      throw MisoError.invalid("Container or System device changed during reseal")
    }
    guard
      Set(before.volumes.filter { $0.device != system.device })
        == Set(after.volumes.filter { $0.device != system.device })
    else {
      throw MisoError.invalid("Unrelated volume changed during reseal")
    }
    return updated
  }
}
