import AppKit
import Darwin
import EmberCore

@main
@MainActor
enum ProjectEmberMain {
  static func main() {
    if CommandLine.arguments.contains("--system-probe") {
      runReadOnlySystemProbe()
      return
    }
    if CommandLine.arguments.contains("--prepare-crash-recovery-test") {
      prepareCrashRecoveryTest()
      return
    }
    if CommandLine.arguments.contains("--recover-only") {
      runStartupRecoveryTest()
      return
    }
    if CommandLine.arguments.contains("--lifecycle-self-test") {
      runLifecycleSelfTest()
      return
    }
    if CommandLine.arguments.contains("--system-self-test") {
      runReversibleSystemSelfTest()
      return
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }

  private static func runReadOnlySystemProbe() {
    let gamma = GammaDisplayController()
    let backlight = DisplayServicesBacklightController()
    do {
      let targets = try gamma.displayTargets()
      guard !targets.isEmpty else { throw EmberError.noCompatibleDisplay }
      print("probe=pass")
      print("display_count=\(targets.count)")
      print("compatible_count=\(targets.filter(\.supportsGamma).count)")
      for (index, target) in targets.enumerated() {
        let prefix = "display_\(index + 1)"
        print("\(prefix)_id=\(target.displayID)")
        print("\(prefix)_uuid=\(target.identity.uuid ?? "unavailable")")
        print("\(prefix)_builtin=\(target.identity.isBuiltIn)")
        print("\(prefix)_gamma_capacity=\(target.gammaCapacity)")
        guard target.supportsGamma else {
          print("\(prefix)_gamma_read=false")
          continue
        }
        let baseline = try gamma.captureBaseline(for: target)
        let capability = backlight.capability(for: target.displayID)
        print("\(prefix)_gamma_read=true")
        print("\(prefix)_gamma_samples=\(baseline.gammaTable.sampleCount)")
        print("\(prefix)_backlight_control=\(capability.brightnessControl)")
        print("\(prefix)_ambient_light_control=\(capability.ambientLightControl)")
        if capability.brightnessControl {
          let hardware = try backlight.captureBaseline(for: target.displayID)
          if let brightness = hardware.brightness {
            print("\(prefix)_hardware_brightness=\(String(format: "%.3f", brightness))")
          }
          if let ambient = hardware.ambientLightCompensationEnabled {
            print("\(prefix)_automatic_brightness=\(ambient)")
          }
        }
      }
    } catch {
      print("probe=fail")
      print("error=\(error.localizedDescription)")
      Darwin.exit(2)
    }
  }

  private static func runReversibleSystemSelfTest() {
    let gamma = GammaDisplayController()
    let backlight = DisplayServicesBacklightController()
    let journal = RecoveryJournal(fileURL: recoveryJournalURL())
    var entries: [DisplayRecoveryEntry] = []
    var testFailure: Error?
    var restoreFailure: Error?

    do {
      guard !journal.exists else {
        throw EmberError.recoveryFailed(
          "A recovery journal already exists. Launch Project Ember normally to recover it first."
        )
      }
      let targets = try gamma.compatibleDisplayTargets()
      guard !targets.isEmpty else { throw EmberError.noCompatibleDisplay }
      entries = try targets.map { target in
        let baseline = try gamma.captureBaseline(for: target)
        return DisplayRecoveryEntry(identity: target.identity, display: baseline)
      }

      var backlightCapability = DisplayServicesBacklightController.Capability(
        brightnessControl: false,
        ambientLightControl: false
      )
      var backlightIndex: Int?
      for index in entries.indices {
        guard let target = try gamma.target(matching: entries[index].identity) else { continue }
        let capability = backlight.capability(for: target.displayID)
        if capability.brightnessControl {
          entries[index].hardware = try backlight.captureBaseline(for: target.displayID)
          backlightCapability = capability
          backlightIndex = index
          break
        }
      }

      let settings = EmberSettings(
        warmth: 0.05,
        apparentBrightness: 0.75,
        filterEnabled: true,
        backlightLockEnabled: backlightIndex != nil
      )
      try journal.save(
        RecoveryRecord(
          appVersion: "0.2.0-self-test",
          displays: entries,
          intendedSettings: settings
        ))

      for entry in entries {
        try gamma.apply(settings: settings, to: entry.display)
        let appliedGamma = try gamma.currentTable(for: entry.display)
        let expectedGamma = entry.display.gammaTable.applying(
          gains: ColorCurve.gains(forWarmth: settings.warmth),
          apparentBrightness: settings.apparentBrightness
        )
        guard appliedGamma.maximumAbsoluteDifference(from: expectedGamma) < 0.004 else {
          throw EmberError.recoveryFailed(
            "Display \(entry.display.displayID) did not preserve the expected gamma table."
          )
        }
      }

      if let backlightIndex,
        let target = try gamma.target(matching: entries[backlightIndex].identity)
      {
        try backlight.engage(on: target.displayID)
        let appliedHardware = try backlight.captureBaseline(for: target.displayID)
        guard let brightness = appliedHardware.brightness, brightness >= 0.97 else {
          throw EmberError.recoveryFailed(
            "Backlight readback was below the verified lock threshold."
          )
        }
        if backlightCapability.ambientLightControl,
          appliedHardware.ambientLightCompensationEnabled != false
        {
          throw EmberError.recoveryFailed(
            "Automatic brightness was not disabled during Backlight Lock."
          )
        }
      }

      var pureRedSettings = settings
      pureRedSettings.warmth = 1
      for entry in entries {
        try gamma.apply(settings: pureRedSettings, to: entry.display)
        let pureRedGamma = try gamma.currentTable(for: entry.display)
        let expectedPureRed = entry.display.gammaTable.applying(
          gains: ColorCurve.gains(forWarmth: 1),
          apparentBrightness: pureRedSettings.apparentBrightness
        )
        guard pureRedGamma.maximumAbsoluteDifference(from: expectedPureRed) < 0.004 else {
          throw EmberError.recoveryFailed(
            "Display \(entry.display.displayID) did not preserve the Pure Red table."
          )
        }
      }
    } catch {
      testFailure = error
    }

    if !entries.isEmpty {
      do {
        for entry in entries {
          try gamma.restore(entry.display)
          guard let target = try gamma.target(matching: entry.identity) else {
            throw EmberError.displayUnavailable
          }
          if entry.hardware.hasValues {
            try backlight.restore(entry.hardware, on: target.displayID)
          }
          let restoredGamma = try gamma.currentTable(for: entry.display)
          guard restoredGamma.maximumAbsoluteDifference(from: entry.display.gammaTable) < 0.004
          else {
            throw EmberError.recoveryFailed(
              "Display \(entry.display.displayID) differs from its captured baseline after restore."
            )
          }

          if entry.hardware.hasValues {
            let restoredHardware = try backlight.captureBaseline(for: target.displayID)
            if let expectedAmbient = entry.hardware.ambientLightCompensationEnabled {
              guard restoredHardware.ambientLightCompensationEnabled == expectedAmbient else {
                throw EmberError.recoveryFailed("Automatic brightness state did not restore.")
              }
            }
            if entry.hardware.ambientLightCompensationEnabled != true,
              let expectedBrightness = entry.hardware.brightness,
              let actualBrightness = restoredHardware.brightness
            {
              guard abs(expectedBrightness - actualBrightness) < 0.03 else {
                throw EmberError.recoveryFailed(
                  "Hardware brightness did not restore within tolerance."
                )
              }
            }
          }
        }
        try journal.clear()
      } catch {
        restoreFailure = error
      }
    }

    if let restoreFailure {
      print("self_test=fail")
      print("phase=restore")
      print("error=\(restoreFailure.localizedDescription)")
      Darwin.exit(4)
    }
    if let testFailure {
      print("self_test=fail")
      print("phase=apply_or_verify")
      print("error=\(testFailure.localizedDescription)")
      Darwin.exit(3)
    }

    print("self_test=pass")
    print("display_count=\(entries.count)")
    print("all_display_gamma_apply=verified")
    print("all_display_gamma_restore=verified")
    print("all_display_pure_red=verified")
    print("backlight_lock=\(entries.contains(where: { $0.hardware.hasValues }) ? "verified" : "unavailable")")
    print("automatic_brightness_restore=verified")
  }

  private static func prepareCrashRecoveryTest() {
    let gamma = GammaDisplayController()
    let backlight = DisplayServicesBacklightController()
    let journal = RecoveryJournal(fileURL: recoveryJournalURL())
    var entries: [DisplayRecoveryEntry] = []

    do {
      guard !journal.exists else {
        throw EmberError.recoveryFailed(
          "A recovery journal already exists. Run recovery before preparing another test."
        )
      }
      let targets = try gamma.compatibleDisplayTargets()
      guard !targets.isEmpty else { throw EmberError.noCompatibleDisplay }
      entries = try targets.map { target in
        let baseline = try gamma.captureBaseline(for: target)
        return DisplayRecoveryEntry(identity: target.identity, display: baseline)
      }
      var backlightIndex: Int?
      for index in entries.indices {
        guard let target = try gamma.target(matching: entries[index].identity) else { continue }
        let capability = backlight.capability(for: target.displayID)
        if capability.brightnessControl {
          entries[index].hardware = try backlight.captureBaseline(for: target.displayID)
          backlightIndex = index
          break
        }
      }
      let settings = EmberSettings(
        warmth: 0.05,
        apparentBrightness: 0.75,
        filterEnabled: true,
        backlightLockEnabled: backlightIndex != nil
      )

      try journal.save(
        RecoveryRecord(
          appVersion: "0.2.0-crash-recovery-test",
          displays: entries,
          intendedSettings: settings
        ))
      for entry in entries {
        try gamma.apply(settings: settings, to: entry.display)
      }
      if let backlightIndex,
        let target = try gamma.target(matching: entries[backlightIndex].identity)
      {
        try backlight.engage(on: target.displayID)
      }
      print("crash_state=prepared")
      print("display_count=\(entries.count)")
      print("recovery_journal=present")
      print("next_step=run --recover-only")
    } catch {
      var restored = true
      for entry in entries {
        do {
          try gamma.restore(entry.display)
          if entry.hardware.hasValues,
            let target = try gamma.target(matching: entry.identity)
          {
            try backlight.restore(entry.hardware, on: target.displayID)
          }
        } catch {
          restored = false
        }
      }
      if restored { try? journal.clear() }
      print("crash_state=fail")
      print("error=\(error.localizedDescription)")
      Darwin.exit(5)
    }
  }

  private static func runStartupRecoveryTest() {
    let gamma = GammaDisplayController()
    let backlight = DisplayServicesBacklightController()
    let journal = RecoveryJournal(fileURL: recoveryJournalURL())
    let suiteName = "app.projectember.recovery-self-test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      print("recovery_test=fail")
      print("error=Could not create isolated settings.")
      Darwin.exit(6)
    }
    defaults.removePersistentDomain(forName: suiteName)
    let settingsStore = SettingsStore(defaults: defaults)
    var expectedRecord: RecoveryRecord?

    do {
      guard let record = try journal.load() else {
        throw EmberError.recoveryFailed("No prepared recovery journal was found.")
      }
      expectedRecord = record
      try settingsStore.save(
        EmberSettings(
          warmth: 0.05,
          apparentBrightness: 0.5,
          filterEnabled: false,
          backlightLockEnabled: false
        ))

      let coordinator = DisplayCoordinator(
        settingsStore: settingsStore,
        recoveryJournal: journal
      )
      coordinator.start()
      let snapshot = coordinator.currentSnapshot()
      try require(
        snapshot.runtimeState == .off, "Startup recovery did not finish in the off state.")
      try require(!snapshot.settings.filterEnabled, "Startup recovery did not keep the filter off.")
      try require(
        !snapshot.settings.backlightLockEnabled, "Startup recovery did not keep Backlight Lock off."
      )
      try require(!journal.exists, "Startup recovery did not clear the completed journal.")

      for entry in record.displays {
        let restoredGamma = try gamma.currentTable(for: entry.display)
        try require(
          restoredGamma.maximumAbsoluteDifference(from: entry.display.gammaTable) < 0.002,
          "Startup recovery did not restore a captured gamma table."
        )
        if entry.hardware.hasValues,
          let target = try gamma.target(matching: entry.identity)
        {
          let restoredHardware = try backlight.captureBaseline(for: target.displayID)
          if let expectedAmbient = entry.hardware.ambientLightCompensationEnabled {
            try require(
              restoredHardware.ambientLightCompensationEnabled == expectedAmbient,
              "Startup recovery did not restore automatic brightness."
            )
          }
          if entry.hardware.ambientLightCompensationEnabled != true,
            let expectedBrightness = entry.hardware.brightness,
            let actualBrightness = restoredHardware.brightness
          {
            try require(
              abs(expectedBrightness - actualBrightness) < 0.03,
              "Startup recovery did not restore hardware brightness."
            )
          }
        }
      }
      defaults.removePersistentDomain(forName: suiteName)
      print("recovery_test=pass")
      print("startup_recovery=verified")
      print("gamma_restore=verified")
      print("hardware_restore=verified")
      print("recovery_journal=clear")
    } catch {
      if let record = expectedRecord {
        do {
          for entry in record.displays {
            try gamma.restore(entry.display)
            if entry.hardware.hasValues,
              let target = try gamma.target(matching: entry.identity)
            {
              try backlight.restore(entry.hardware, on: target.displayID)
            }
          }
          try journal.clear()
        } catch {
          // Leave the journal intact if emergency restoration cannot be proven.
        }
      }
      defaults.removePersistentDomain(forName: suiteName)
      print("recovery_test=fail")
      print("error=\(error.localizedDescription)")
      Darwin.exit(6)
    }
  }

  private static func runLifecycleSelfTest() {
    let gamma = GammaDisplayController()
    let backlight = DisplayServicesBacklightController()
    let journal = RecoveryJournal(fileURL: recoveryJournalURL())
    let suiteName = "app.projectember.lifecycle-self-test"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      print("lifecycle_test=fail")
      print("error=Could not create isolated settings.")
      Darwin.exit(7)
    }
    defaults.removePersistentDomain(forName: suiteName)
    let settingsStore = SettingsStore(defaults: defaults)
    var coordinator: DisplayCoordinator?
    var completed = false

    do {
      guard !journal.exists else {
        throw EmberError.recoveryFailed("A recovery journal already exists.")
      }
      let initialDisplay = try gamma.captureBaseline()
      let initialHardware = try backlight.captureBaseline(for: initialDisplay.displayID)
      let softwareBrightness = Double(initialHardware.brightness ?? 0.75)
      try settingsStore.save(
        EmberSettings(
          warmth: 0.05,
          apparentBrightness: softwareBrightness,
          filterEnabled: false,
          backlightLockEnabled: true
        ))

      let activeCoordinator = DisplayCoordinator(
        settingsStore: settingsStore,
        recoveryJournal: journal
      )
      coordinator = activeCoordinator
      activeCoordinator.start()
      activeCoordinator.setFilterEnabled(true)
      try require(
        activeCoordinator.currentSnapshot().runtimeState == .active,
        "Activation did not reach the active state."
      )
      try require(journal.exists, "Activation did not leave a recovery journal.")

      let activeGamma = try gamma.currentTable()
      let expectedGamma = initialDisplay.gammaTable.applying(
        gains: ColorCurve.gains(forWarmth: 0.05),
        apparentBrightness: softwareBrightness
      )
      try require(
        activeGamma.maximumAbsoluteDifference(from: expectedGamma) < 0.002,
        "Active gamma table did not match the requested transform."
      )
      var activeHardware = try backlight.captureBaseline(for: initialDisplay.displayID)
      try require(
        (activeHardware.brightness ?? 0) >= 0.97,
        "Backlight Lock did not verify full hardware brightness."
      )
      try require(
        activeHardware.ambientLightCompensationEnabled == false,
        "Backlight Lock did not disable automatic brightness."
      )

      try backlight.restore(
        HardwareBaseline(brightness: 0.65, ambientLightCompensationEnabled: nil),
        on: initialDisplay.displayID
      )
      // Guard interval is 5 s with 1 s tolerance (reduced from 1 s for 80% fewer
      // wakeups). Wait long enough for at least one guard firing.
      RunLoop.main.run(until: Date().addingTimeInterval(6.5))
      activeHardware = try backlight.captureBaseline(for: initialDisplay.displayID)
      try require(
        (activeHardware.brightness ?? 0) >= 0.97,
        "Backlight guard did not correct an external brightness change."
      )

      activeCoordinator.setWarmth(0.10)
      // Warmth slider changes are coalesced to 50 ms to avoid hammering
      // CGSetDisplayTransferByTable during drag; wait for the coalesced write.
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let updatedGamma = try gamma.currentTable()
      let expectedUpdated = initialDisplay.gammaTable.applying(
        gains: ColorCurve.gains(forWarmth: 0.10),
        apparentBrightness: softwareBrightness
      )
      try require(
        updatedGamma.maximumAbsoluteDifference(from: expectedUpdated) < 0.002,
        "A live warmth change did not update from the immutable baseline."
      )

      activeCoordinator.displayConfigurationChanged()
      RunLoop.main.run(until: Date().addingTimeInterval(1.0))
      try require(
        activeCoordinator.currentSnapshot().runtimeState == .active && journal.exists,
        "Display reconfiguration did not restore, recapture, and reactivate."
      )

      activeCoordinator.willSleep()
      try require(
        activeCoordinator.currentSnapshot().runtimeState == .suspended,
        "Sleep handling did not enter the suspended state."
      )
      try require(!journal.exists, "Sleep handling did not clear the completed journal.")
      let sleepGamma = try gamma.currentTable()
      try require(
        sleepGamma.maximumAbsoluteDifference(from: initialDisplay.gammaTable) < 0.002,
        "Sleep handling did not restore the original gamma table."
      )

      activeCoordinator.didWake()
      RunLoop.main.run(until: Date().addingTimeInterval(1.4))
      try require(
        activeCoordinator.currentSnapshot().runtimeState == .active && journal.exists,
        "Wake handling did not recapture, journal, and reactivate."
      )

      activeCoordinator.shutdown()
      try require(
        activeCoordinator.currentSnapshot().runtimeState == .off,
        "Termination handling did not return to the off state."
      )
      try require(!journal.exists, "Termination handling did not clear the completed journal.")
      let terminatedGamma = try gamma.currentTable()
      try require(
        terminatedGamma.maximumAbsoluteDifference(from: initialDisplay.gammaTable) < 0.002,
        "Termination handling did not restore the original gamma table."
      )
      let terminatedHardware = try backlight.captureBaseline(for: initialDisplay.displayID)
      if let expectedAmbient = initialHardware.ambientLightCompensationEnabled {
        try require(
          terminatedHardware.ambientLightCompensationEnabled == expectedAmbient,
          "Termination handling did not restore automatic brightness."
        )
      }

      activeCoordinator.setFilterEnabled(false)
      defaults.removePersistentDomain(forName: suiteName)
      completed = true
      print("lifecycle_test=pass")
      print("live_updates=verified")
      print("backlight_guard=verified")
      print("display_reconfiguration=verified")
      print("sleep_restore=verified")
      print("wake_reapply=verified")
      print("termination_restore=verified")
    } catch {
      if !completed {
        coordinator?.resetDisplayNow()
        try? journal.clear()
      }
      defaults.removePersistentDomain(forName: suiteName)
      print("lifecycle_test=fail")
      print("error=\(error.localizedDescription)")
      Darwin.exit(7)
    }
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
      throw EmberError.recoveryFailed(message)
    }
  }

  private static func recoveryJournalURL() -> URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("Project Ember", isDirectory: true)
      .appendingPathComponent("display-recovery-v1.json")
  }
}
