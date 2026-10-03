import Foundation
import Testing

@testable import EmberCore

/// Journal-integrity coverage for 0.5.0.
///
/// These exercise the real `RecoveryJournal` on disk in a temporary directory:
/// the point is the *file* behaviour, because the 0.4.0 defect was that the
/// last-known-good copy was written and never read.
@Suite("Journal integrity")
struct JournalIntegrityTests {

  private func makeJournal() -> (RecoveryJournal, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ember-journal-tests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("display-recovery-v1.json")
    return (RecoveryJournal(fileURL: url), directory)
  }

  private func record(
    table: GammaTable = .identity(sampleCount: 64),
    identity: DisplayIdentity = DisplayIdentity(
      uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      vendorNumber: 1, modelNumber: 2, serialNumber: 3, unitNumber: 0, isBuiltIn: true
    )
  ) -> RecoveryRecord {
    RecoveryRecord(
      appVersion: "0.5.0",
      displays: [
        DisplayRecoveryEntry(
          identity: identity,
          display: DisplayBaseline(displayID: 1, identity: identity, gammaTable: table)
        )
      ],
      intendedSettings: .default
    )
  }

  @Test("A torn primary journal is recovered from the last known good copy")
  func corruptJournalRecoversFromBackup() throws {
    let (journal, directory) = makeJournal()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = record()
    try journal.save(first)
    // A second save moves the first record into the backup beside the primary.
    try journal.save(record(table: .identity(sampleCount: 128)))
    #expect(FileManager.default.fileExists(atPath: journal.backupURL.path))

    // Simulate the torn write: valid JSON file, unreadable content.
    try Data("{ this is not a recovery record".utf8).write(to: journal.fileURL)

    guard case .corrupt = journal.loadOutcome() else {
      Issue.record("expected the torn journal to be reported as corrupt, not absent")
      return
    }

    let recovered = journal.recoverCorruptJournalFromBackup()
    #expect(recovered != nil, "the backup decodes and must be used")
    #expect(recovered?.displays.first?.display.gammaTable.sampleCount == 64)
    #expect(
      !FileManager.default.fileExists(atPath: journal.fileURL.path),
      "the unreadable file is quarantined, not deleted"
    )
    #expect(
      FileManager.default.fileExists(atPath: journal.quarantineURL.path),
      "the unreadable journal is preserved for inspection"
    )
  }

  @Test("Without a usable backup the unreadable journal is left in place")
  func noBackupLeavesJournalForQuarantine() throws {
    let (journal, directory) = makeJournal()
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json at all".utf8).write(to: journal.fileURL)

    #expect(journal.recoverCorruptJournalFromBackup() == nil)
    #expect(
      FileManager.default.fileExists(atPath: journal.fileURL.path),
      "the caller must still be able to quarantine it"
    )
  }

  @Test("A degenerate baseline table is rejected as corrupt, not written to a panel")
  func degenerateBaselineIsCorrupt() throws {
    let (journal, directory) = makeJournal()
    defer { try? FileManager.default.removeItem(at: directory) }

    // One sample resamples to a constant table: writing it would nail the panel
    // to a single value and destroy what the user actually had.
    let single = GammaTable(red: [0], green: [0], blue: [0])
    #expect(single.isValid == false, "a one-sample table cannot describe a display ramp")

    let constant = GammaTable(
      red: Array(repeating: 0.5, count: 16),
      green: Array(repeating: 0.5, count: 16),
      blue: Array(repeating: 0.5, count: 16)
    )
    #expect(constant.isValid, "shape alone is valid")
    #expect(constant.isPlausibleBaseline == false, "but a flat table is not a plausible original")
    #expect(record(table: constant).validationFailure() != nil)

    // Write a decodable-but-degenerate record straight to disk.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(record(table: GammaTable(red: [0], green: [0], blue: [0])))
      .write(to: journal.fileURL)

    guard case .corrupt(let reason) = journal.loadOutcome() else {
      Issue.record("a degenerate baseline must be treated as corrupt")
      return
    }
    #expect(reason.contains("colour table") || reason.contains("constant"))
  }

  @Test("A real display ramp still round-trips")
  func healthyRecordStillLoads() throws {
    let (journal, directory) = makeJournal()
    defer { try? FileManager.default.removeItem(at: directory) }

    try journal.save(record(table: .identity(sampleCount: 256)))
    guard case .loaded(let loaded) = journal.loadOutcome() else {
      Issue.record("a normal record must still load")
      return
    }
    #expect(loaded.displays.count == 1)
    #expect(loaded.displays.first?.display.gammaTable.sampleCount == 256)
    #expect(loaded.validationFailure() == nil)
  }

  @Test("An empty display list and a zero schema are rejected")
  func emptyAndZeroSchemaAreCorrupt() throws {
    let (journal, directory) = makeJournal()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Empty display list: recovery would otherwise report full success.
    let empty = RecoveryRecord(
      appVersion: "0.5.0", displays: [], intendedSettings: .default)
    #expect(empty.validationFailure() != nil)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(empty).write(to: journal.fileURL)
    guard case .corrupt = journal.loadOutcome() else {
      Issue.record("a record with no displays must be corrupt")
      return
    }

    // schemaVersion 0: there is no lower bound in 0.4.0's decoder.
    let zeroSchema = """
      {"schemaVersion":0,"appVersion":"0.5.0","createdAt":0,
       "displays":[],"intendedSettings":{"warmth":0,"apparentBrightness":1,
       "filterEnabled":false,"backlightLockEnabled":false,"launchAtLogin":false,
       "sunScheduleEnabled":false,"menuBarPrimaryAction":"openControls"}}
      """
    try Data(zeroSchema.utf8).write(to: journal.fileURL)
    guard case .corrupt(let reason) = journal.loadOutcome() else {
      Issue.record("schema v0 must be corrupt")
      return
    }
    #expect(reason.contains("schema") || reason.contains("no displays"))
  }

  @Test("A future schema is still rejected explicitly")
  func futureSchemaStillRejected() throws {
    let (journal, directory) = makeJournal()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let future = """
      {"schemaVersion":99,"appVersion":"9.9.9","createdAt":0,
       "displays":[],"intendedSettings":{"warmth":0,"apparentBrightness":1,
       "filterEnabled":false,"backlightLockEnabled":false,"launchAtLogin":false,
       "sunScheduleEnabled":false,"menuBarPrimaryAction":"openControls"}}
      """
    try Data(future.utf8).write(to: journal.fileURL)
    guard case .unsupportedFutureSchema(let version) = journal.loadOutcome() else {
      Issue.record("a future schema must not be decoded as if it were current")
      return
    }
    #expect(version == 99)
  }
}

/// The status-item gesture map is documented behaviour (README: "right-click
/// always opens controls"), so it is pinned here. 0.5.0 briefly moved the
/// alternate menu onto right-click and shadowed the gesture users had learned.
@Suite("Status item click routing")
struct StatusClickRoutingTests {

  @Test("Right-click, two-finger click and Control-click open the controls")
  func opensControls() {
    #expect(
      MenuBarRouting.statusClick(isRightClick: true, isControlClick: false, isOptionClick: false)
        == .openControls)
    #expect(
      MenuBarRouting.statusClick(isRightClick: false, isControlClick: true, isOptionClick: false)
        == .openControls)
    // Right-click wins even when Option is also held.
    #expect(
      MenuBarRouting.statusClick(isRightClick: true, isControlClick: false, isOptionClick: true)
        == .openControls)
  }

  @Test("Option-click opens the alternate menu, a plain click follows the preference")
  func alternateAndPrimary() {
    #expect(
      MenuBarRouting.statusClick(isRightClick: false, isControlClick: false, isOptionClick: true)
        == .showAlternateMenu)
    #expect(
      MenuBarRouting.statusClick(isRightClick: false, isControlClick: false, isOptionClick: false)
        == .primaryAction)
  }
}
