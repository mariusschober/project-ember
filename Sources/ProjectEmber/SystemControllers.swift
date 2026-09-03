import ColorSync
import CoreGraphics
import Darwin
import EmberCore
import Foundation

struct DisplayTarget: Equatable {
  let displayID: CGDirectDisplayID
  let identity: DisplayIdentity
  let gammaCapacity: UInt32

  var supportsGamma: Bool {
    gammaCapacity >= 2
  }
}

final class GammaDisplayController {
  func displayTargets() throws -> [DisplayTarget] {
    var count: UInt32 = 0
    let countResult = CGGetOnlineDisplayList(0, nil, &count)
    guard countResult == .success else {
      throw EmberError.gammaReadFailed(Self.code(for: countResult))
    }
    guard count > 0 else { return [] }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let listResult = CGGetOnlineDisplayList(count, &displays, &count)
    guard listResult == .success else {
      throw EmberError.gammaReadFailed(Self.code(for: listResult))
    }

    var out: [DisplayTarget] = []
    let isVisualQA = CommandLine.arguments.contains("--snapshot-ui") || CommandLine.arguments.contains("--show-panel")
    for display in displays.prefix(Int(count)) {
      let online = CGDisplayIsOnline(display) != 0
      let active = CGDisplayIsActive(display) != 0
      let mirrored = CGDisplayMirrorsDisplay(display)
      let cap = CGDisplayGammaTableCapacity(display)
      guard online, (active || isVisualQA) else { continue }
      guard mirrored == kCGNullDirectDisplay else { continue }
      out.append(DisplayTarget(displayID: display, identity: identity(for: display), gammaCapacity: cap))
    }
    return out
  }

  func compatibleDisplayTargets() throws -> [DisplayTarget] {
    try displayTargets().filter(\.supportsGamma)
  }

  func builtInDisplayID() throws -> CGDirectDisplayID {
    guard let target = try displayTargets().first(where: { $0.identity.isBuiltIn }) else {
      throw EmberError.noBuiltInDisplay
    }
    return target.displayID
  }

  func captureBaseline(for target: DisplayTarget) throws -> DisplayBaseline {
    let table = try readTable(displayID: target.displayID, capacity: target.gammaCapacity)
    return DisplayBaseline(
      displayID: target.displayID,
      identity: target.identity,
      gammaTable: table
    )
  }

  func captureBaseline() throws -> DisplayBaseline {
    let display = try builtInDisplayID()
    guard let target = try displayTargets().first(where: { $0.displayID == display }) else {
      throw EmberError.noBuiltInDisplay
    }
    return try captureBaseline(for: target)
  }

  func apply(settings: EmberSettings, to baseline: DisplayBaseline, verify: Bool = true) throws {
    let gains = ColorCurve.gains(forWarmth: settings.warmth)
    let transformed = baseline.gammaTable.applying(
      gains: gains,
      apparentBrightness: settings.apparentBrightness
    )
    let target = try resolve(baseline: baseline)
    try write(transformed, to: target)
    if verify {
      let readback = try readTable(displayID: target.displayID, capacity: target.gammaCapacity)
      guard readback.maximumAbsoluteDifference(from: transformed) < 0.004 else {
        throw EmberError.gammaVerificationFailed
      }
    }
  }

  func restore(_ baseline: DisplayBaseline) throws {
    let target = try resolve(baseline: baseline)
    try write(baseline.gammaTable, to: target)
  }

  /// Verified restore: writes the saved table and reads back within tolerance.
  /// Recovery entries are removed only after this succeeds.
  func restoreVerified(_ baseline: DisplayBaseline, tolerance: Float = 0.004) throws {
    let target = try resolve(baseline: baseline)
    try write(baseline.gammaTable, to: target)
    let readback = try readTable(displayID: target.displayID, capacity: target.gammaCapacity)
    let delta = readback.maximumAbsoluteDifference(from: baseline.gammaTable)
    guard delta < tolerance else { throw EmberError.gammaVerificationFailed }
  }

  func verifyTransform(settings: EmberSettings, baseline: DisplayBaseline, tolerance: Float = 0.004) throws -> GammaTable {
    let gains = ColorCurve.gains(forWarmth: settings.warmth)
    let expected = baseline.gammaTable.applying(
      gains: gains,
      apparentBrightness: settings.apparentBrightness
    )
    let target = try resolve(baseline: baseline)
    let current = try readTable(displayID: target.displayID, capacity: target.gammaCapacity)
    let delta = current.maximumAbsoluteDifference(from: expected)
    guard delta < tolerance else { throw EmberError.gammaVerificationFailed }
    return current
  }

  func isTransformInstalled(settings: EmberSettings, baseline: DisplayBaseline, tolerance: Float = 0.004) -> Bool {
    (try? verifyTransform(settings: settings, baseline: baseline, tolerance: tolerance)) != nil
  }

  func forceColorSyncRestore() {
    CGDisplayRestoreColorSyncSettings()
  }

  func currentTable(for baseline: DisplayBaseline) throws -> GammaTable {
    let target = try resolve(baseline: baseline)
    return try readTable(displayID: target.displayID, capacity: target.gammaCapacity)
  }

  func currentTable() throws -> GammaTable {
    try captureBaseline().gammaTable
  }

  func target(matching identity: DisplayIdentity) throws -> DisplayTarget? {
    let targets = try displayTargets()
    if let legacyID = identity.legacyDisplayID {
      // Legacy v1 records are built-in-only. Never resolve onto an unrelated
      // external display whose transient display ID was reused.
      if let exact = targets.first(where: { $0.displayID == legacyID }) {
        // Exact ID hit: accept only if it is still the built-in panel or the
        // identity also matches; otherwise refuse an unsafe match.
        if exact.identity.isBuiltIn || identity.matches(exact.identity) { return exact }
        return targets.first(where: { $0.identity.isBuiltIn })
      }
      // No exact hit: prefer the current built-in display for legacy built-in
      // records; refuse if there is no built-in target.
      guard identity.isBuiltIn else { return nil }
      return targets.first(where: { $0.identity.isBuiltIn })
    }
    let candidates = targets.filter { identity.matches($0.identity) }
    // Ambiguity means no mutation: identical zero-serial displays must not
    // resolve to the first match.
    guard candidates.count <= 1 else { return nil }
    return candidates.first
  }

  /// Returns ambiguity keys for the current enumeration (identity key → count>1).
  func ambiguousIdentityKeys() throws -> Set<String> {
    let targets = try displayTargets()
    var counts: [String: Int] = [:]
    for t in targets {
      let key: String
      if let uuid = t.identity.uuid, !uuid.isEmpty { key = "uuid:\(uuid.lowercased())" }
      else {
        key =
          "hw:\(t.identity.vendorNumber):\(t.identity.modelNumber):\(t.identity.serialNumber):\(t.identity.unitNumber):\(t.identity.isBuiltIn)"
      }
      counts[key, default: 0] += 1
    }
    return Set(counts.filter { $0.value > 1 }.map(\.key))
  }

  private func resolve(baseline: DisplayBaseline) throws -> DisplayTarget {
    let identity = baseline.identity ?? .legacy(displayID: baseline.displayID)
    guard let target = try target(matching: identity) else {
      throw EmberError.displayUnavailable
    }
    if identity.legacyDisplayID == nil, !identity.matches(target.identity) {
      throw EmberError.displayIdentityMismatch
    }
    return target
  }

  private func identity(for display: CGDirectDisplayID) -> DisplayIdentity {
    let uuidString: String?
    if let uuid = CGDisplayCreateUUIDFromDisplayID(display) {
      uuidString = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    } else {
      uuidString = nil
    }
    return DisplayIdentity(
      uuid: uuidString,
      vendorNumber: CGDisplayVendorNumber(display),
      modelNumber: CGDisplayModelNumber(display),
      serialNumber: CGDisplaySerialNumber(display),
      unitNumber: CGDisplayUnitNumber(display),
      isBuiltIn: CGDisplayIsBuiltin(display) != 0
    )
  }

  func readTable(displayID: CGDirectDisplayID, capacity: UInt32) throws -> GammaTable {
    guard capacity >= 2 else { throw EmberError.invalidGammaTable }
    var red = [CGGammaValue](repeating: 0, count: Int(capacity))
    var green = [CGGammaValue](repeating: 0, count: Int(capacity))
    var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
    var sampleCount: UInt32 = 0

    let result = red.withUnsafeMutableBufferPointer { redBuffer in
      green.withUnsafeMutableBufferPointer { greenBuffer in
        blue.withUnsafeMutableBufferPointer { blueBuffer in
          CGGetDisplayTransferByTable(
            displayID,
            capacity,
            redBuffer.baseAddress,
            greenBuffer.baseAddress,
            blueBuffer.baseAddress,
            &sampleCount
          )
        }
      }
    }
    guard result == .success else {
      throw EmberError.gammaReadFailed(Self.code(for: result))
    }
    guard sampleCount >= 2 else { throw EmberError.invalidGammaTable }

    let table = GammaTable(
      red: Array(red.prefix(Int(sampleCount))),
      green: Array(green.prefix(Int(sampleCount))),
      blue: Array(blue.prefix(Int(sampleCount)))
    )
    guard table.isValid else { throw EmberError.invalidGammaTable }
    return table
  }

  private func write(_ table: GammaTable, to target: DisplayTarget) throws {
    guard table.isValid else { throw EmberError.invalidGammaTable }
    guard CGDisplayIsOnline(target.displayID) != 0, CGDisplayIsActive(target.displayID) != 0 else {
      throw EmberError.displayUnavailable
    }
    let currentIdentity = identity(for: target.displayID)
    guard target.identity.matches(currentIdentity) else {
      throw EmberError.displayIdentityMismatch
    }

    let capacity = Int(CGDisplayGammaTableCapacity(target.displayID))
    guard capacity >= 2 else { throw EmberError.invalidGammaTable }
    let output = table.resampled(to: min(capacity, max(table.sampleCount, 2)))
    let result = output.red.withUnsafeBufferPointer { redBuffer in
      output.green.withUnsafeBufferPointer { greenBuffer in
        output.blue.withUnsafeBufferPointer { blueBuffer in
          CGSetDisplayTransferByTable(
            target.displayID,
            UInt32(output.sampleCount),
            redBuffer.baseAddress,
            greenBuffer.baseAddress,
            blueBuffer.baseAddress
          )
        }
      }
    }
    guard result == .success else {
      throw EmberError.gammaWriteFailed(Self.code(for: result))
    }
  }

  private static func code(for error: CGError) -> Int32 {
    Int32(error.rawValue)
  }
}

final class DisplayServicesBacklightController {
  struct Capability: Equatable {
    let brightnessControl: Bool
    let ambientLightControl: Bool
  }

  private typealias GetBrightness =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
  private typealias GetAmbientLightCompensation =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
  private typealias SetAmbientLightCompensation = @convention(c) (CGDirectDisplayID, Bool) -> Int32

  private let handle: UnsafeMutableRawPointer?
  private let getBrightness: GetBrightness?
  private let setBrightness: SetBrightness?
  private let getAmbientLightCompensation: GetAmbientLightCompensation?
  private let setAmbientLightCompensation: SetAmbientLightCompensation?

  init() {
    let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
    getBrightness = Self.load("DisplayServicesGetBrightness", from: handle)
    setBrightness = Self.load("DisplayServicesSetBrightness", from: handle)
    getAmbientLightCompensation = Self.load(
      "DisplayServicesAmbientLightCompensationEnabled",
      from: handle
    )
    setAmbientLightCompensation = Self.load(
      "DisplayServicesEnableAmbientLightCompensation",
      from: handle
    )
  }

  deinit {
    if let handle { dlclose(handle) }
  }

  func capability(for display: CGDirectDisplayID) -> Capability {
    // Built-in-only: never report capability for an external display, even if
    // the private symbols happen to answer.
    guard CGDisplayIsBuiltin(display) != 0 else {
      return Capability(brightnessControl: false, ambientLightControl: false)
    }
    var brightness: Float = 0
    let brightnessReady = getBrightness?(display, &brightness) == 0 && setBrightness != nil
    var ambient = false
    let ambientReady =
      getAmbientLightCompensation?(display, &ambient) == 0
      && setAmbientLightCompensation != nil
    return Capability(brightnessControl: brightnessReady, ambientLightControl: ambientReady)
  }

  func captureBaseline(for display: CGDirectDisplayID) throws -> HardwareBaseline {
    // Backlight Lock is built-in-only and reversible: never engage the private
    // DisplayServices path on an external display, even if symbols resolve.
    guard CGDisplayIsBuiltin(display) != 0 else { throw EmberError.backlightUnavailable }
    guard let getBrightness else { throw EmberError.backlightUnavailable }
    var brightness: Float = 0
    let brightnessResult = getBrightness(display, &brightness)
    guard brightnessResult == 0 else {
      throw EmberError.backlightReadFailed(brightnessResult)
    }

    var ambientValue: Bool?
    if let getAmbientLightCompensation {
      var enabled = false
      let ambientResult = getAmbientLightCompensation(display, &enabled)
      if ambientResult == 0 {
        ambientValue = enabled
      }
    }
    return HardwareBaseline(
      brightness: min(max(brightness, 0), 1),
      ambientLightCompensationEnabled: ambientValue
    )
  }

  func engage(on display: CGDirectDisplayID) throws {
    // Built-in-only gate: refuse external displays outright.
    guard CGDisplayIsBuiltin(display) != 0 else { throw EmberError.backlightUnavailable }
    guard let setBrightness, let getBrightness else { throw EmberError.backlightUnavailable }

    // Never change what cannot be restored: only disable automatic brightness
    // when its current value was read successfully and captured by the caller.
    // Here we read first; if the getter fails we leave it untouched and only
    // manage brightness (reduced capability, not failure).
    if let getAmbient = getAmbientLightCompensation,
      let setAmbient = setAmbientLightCompensation
    {
      var ambient = false
      if getAmbient(display, &ambient) == 0, ambient {
        let ambientResult = setAmbient(display, false)
        guard ambientResult == 0 else {
          throw EmberError.ambientLightWriteFailed(ambientResult)
        }
      }
    }

    // Read before writing: only write when below threshold.
    var current: Float = 0
    if getBrightness(display, &current) == 0, current >= 0.97 {
      return
    }
    let writeResult = setBrightness(display, 1)
    guard writeResult == 0 else {
      throw EmberError.backlightWriteFailed(writeResult)
    }

    var verified: Float = 0
    let readResult = getBrightness(display, &verified)
    guard readResult == 0 else { throw EmberError.backlightReadFailed(readResult) }
    guard verified >= 0.97 else { throw EmberError.backlightWriteFailed(1) }
  }

  /// Read-only drift check for the guard: returns true when a corrective write is needed.
  func needsEngagement(on display: CGDirectDisplayID) -> Bool {
    guard CGDisplayIsBuiltin(display) != 0, let getBrightness else { return false }
    var current: Float = 0
    guard getBrightness(display, &current) == 0 else { return false }
    if current < 0.97 { return true }
    if let getAmbient = getAmbientLightCompensation {
      var ambient = false
      if getAmbient(display, &ambient) == 0, ambient { return true }
    }
    return false
  }

  func readBrightness(_ display: CGDirectDisplayID) throws -> Float {
    guard CGDisplayIsBuiltin(display) != 0, let getBrightness else {
      throw EmberError.backlightUnavailable
    }
    var value: Float = 0
    let result = getBrightness(display, &value)
    guard result == 0 else { throw EmberError.backlightReadFailed(result) }
    return value
  }

  func restore(_ baseline: HardwareBaseline, on display: CGDirectDisplayID) throws {
    guard CGDisplayIsBuiltin(display) != 0 else { throw EmberError.backlightUnavailable }
    if let brightness = baseline.brightness {
      guard let setBrightness, let getBrightness else { throw EmberError.backlightUnavailable }
      let result = setBrightness(display, min(max(brightness, 0), 1))
      guard result == 0 else { throw EmberError.backlightWriteFailed(result) }
      // Verify hardware restoration whenever a value was captured.
      var readback: Float = 0
      guard getBrightness(display, &readback) == 0 else {
        throw EmberError.backlightReadFailed(-1)
      }
      guard abs(readback - min(max(brightness, 0), 1)) < 0.05 else {
        throw EmberError.backlightWriteFailed(2)
      }
    }

    if let ambient = baseline.ambientLightCompensationEnabled {
      guard let setAmbientLightCompensation, let getAmbientLightCompensation else {
        throw EmberError.backlightUnavailable
      }
      let result = setAmbientLightCompensation(display, ambient)
      guard result == 0 else { throw EmberError.ambientLightWriteFailed(result) }
      var readback = false
      guard getAmbientLightCompensation(display, &readback) == 0,
        readback == ambient
      else {
        throw EmberError.ambientLightWriteFailed(2)
      }
    }
  }

  private static func load<T>(_ symbol: String, from handle: UnsafeMutableRawPointer?) -> T? {
    guard let handle, let address = dlsym(handle, symbol) else { return nil }
    return unsafeBitCast(address, to: T.self)
  }
}
