import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["MISO_SPOTLIGHT_TEST_OUTPUT"] != nil))
func nativeSpotlightVolumePolicy() throws {
  try #require(geteuid() == 0)
  let output = URL(
    fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MISO_SPOTLIGHT_TEST_OUTPUT"])
  )
  let journal = try ExecutionJournal(output: output, operation: "native-spotlight-policy")
  var phase = "create disposable image"
  do {
    _ = try journal.perform {
      let image = output.appendingPathComponent("spotlight.sparseimage")
      let systemRoot = output.appendingPathComponent("system")
      try SafeFile.makeDirectory(systemRoot)
      let system = try GuestVolume(systemRoot)
      let offlineStores = BaseSystemSettings.spotlightStores.filter { $0.0 != "Data" }
      try journal.run(
        "create-image",
        NativeCommand(
          .diskImages,
          arguments: [
            "create", "-size", "256m", "-fs", "APFS", "-volname", "MISO-Spotlight-Test",
            "-type", "SPARSE", "-layout", "GPTSPUD", image.path,
          ]))
      for cycle in 0..<3 {
        phase = "attach cycle \(cycle)"
        let session = try DiskImageSession(image: image, readOnly: false, journal: journal)
        try session.withAttachment { session in
          if cycle == 0 {
            let volumes = try session.containers().flatMap(\.volumes)
            let volume = try #require(volumes.count == 1 ? volumes.first : nil)
            try journal.run(
              "set-data-role",
              NativeCommand(.disks, arguments: ["apfs", "changeVolumeRole", volume.device, "D"]))
          }
          let volumes = try session.containers().flatMap(\.volumes)
          let volume = try #require(volumes.first { $0.roles == ["Data"] })
          let data = try ImageMounts.mount(
            volume, session: session, journal: journal, name: "data-\(cycle)", readOnly: false)
          phase = "prepare fixtures for cycle \(cycle)"
          if cycle == 0 {
            try data.mergePlist(
              "private/var/db/dslocal/nodes/Default/users/admin.plist",
              values: ["uid": ["501"], "gid": ["20"], "home": ["/Users/admin"]], uid: 0, gid: 0)
            for (_, directory) in offlineStores {
              try data.mergePlist(
                directory + "/VolumeConfiguration.plist",
                values: [
                  "Stores": ["fixture": ["PolicyLevel": "kMDConfigSearchLevelFSSearchOnly"]]
                ],
                uid: 0, gid: 0)
            }
          }
          phase = "verify persisted state for cycle \(cycle)"
          if cycle > 0 {
            let status = try journal.run(
              "persisted-spotlight",
              NativeCommand("/usr/bin/mdutil", arguments: ["-s", data.root.path], timeout: 30))
            let expected = cycle == 1 ? "Indexing enabled." : "Indexing disabled."
            #expect(try String(contentsOf: status, encoding: .utf8).contains(expected))
          }
          phase = "reject invalid targets"
          if cycle == 0 {
            try data.makeDirectories("nested", uid: 0, gid: 0)
            let nested = try GuestVolume(data.path("nested"))
            #expect(throws: MisoError.self) {
              try OfflineSystemPolicy.configureSpotlight(
                enabled: false, volume: volume, data: nested, session: session, journal: journal)
            }
            let foreign = APFSTopology.Volume(
              device: volume.device, identifier: UUID(), roles: ["Data"], name: nil, mountPoint: nil
            )
            #expect(throws: MisoError.self) {
              try OfflineSystemPolicy.configureSpotlight(
                enabled: false, volume: foreign, data: data, session: session, journal: journal)
            }
          }
          phase = "apply policy for cycle \(cycle)"
          var policy = SystemPolicy()
          policy.settings["spotlightIndexing"] = cycle == 0
          let receipt = try OfflineSystemPolicy.apply(
            policy, system: system, data: data,
            account: BaseImageStage.Account("admin", data: data),
            cancellation: journal.cancellation,
            configureDataSpotlight: { enabled in
              try OfflineSystemPolicy.configureSpotlight(
                enabled: enabled, volume: volume, data: data, session: session, journal: journal)
            })
          phase = "read offline stores for cycle \(cycle)"
          #expect(receipt.spotlightPaths.count == 3)
          for (_, directory) in offlineStores {
            phase = "read \(directory) for cycle \(cycle)"
            let plist = try data.plist(directory + "/VolumeConfiguration.plist")
            let stores = try #require(plist["Stores"] as? [String: [String: Any]])
            let expected =
              cycle == 0 ? "kMDConfigSearchLevelReadWrite" : "kMDConfigSearchLevelFSSearchOnly"
            #expect(stores["fixture"]?["PolicyLevel"] as? String == expected)
          }
        }
      }
      phase = "verify detach and remove disposable image"
      try BaseStageWorkspace.requireUnmounted(output)
      try FileManager.default.removeItem(at: image)
      return true
    }
  } catch {
    throw MisoError.invalid(
      "Spotlight integration test failed during \(phase): \(error.localizedDescription)")
  }
}
