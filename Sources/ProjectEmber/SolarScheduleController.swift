import AppKit
@preconcurrency import CoreLocation
import EmberCore
import Foundation

enum SolarLocationAuthorization: Equatable {
  case notDetermined
  case authorized
  case denied
  case restricted
  case unavailable
}

struct SolarRuntimeSnapshot: Equatable {
  let authorization: SolarLocationAuthorization
  let schedule: SolarSchedule?
  let locationUpdatedAt: Date?
  let isRefreshing: Bool
  let errorMessage: String?

  static let inactive = SolarRuntimeSnapshot(
    authorization: .notDetermined,
    schedule: nil,
    locationUpdatedAt: nil,
    isRefreshing: false,
    errorMessage: nil
  )
}

@MainActor
final class SolarScheduleController: NSObject, @preconcurrency CLLocationManagerDelegate {
  var onSnapshot: ((SolarRuntimeSnapshot) -> Void)?
  var onSchedule: ((SolarSchedule) -> Void)?
  var onAuthorizationFailure: ((String) -> Void)?

  private let locationStore: SolarLocationStore
  private let now: () -> Date
  private var enabled = false
  // Timers are MainActor-bound but need deinit cleanup. Mark as nonisolated(unsafe)
  // and ensure invalidation happens on the main thread where they were scheduled.
  nonisolated(unsafe) private var transitionTimer: Timer?
  nonisolated(unsafe) private var retryTimer: Timer?
  private var snapshot = SolarRuntimeSnapshot.inactive

  deinit {
    // Invalidate on main thread to match RunLoop scheduling.
    if Thread.isMainThread {
      transitionTimer?.invalidate()
      retryTimer?.invalidate()
    } else {
      DispatchQueue.main.sync {
        self.transitionTimer?.invalidate()
        self.retryTimer?.invalidate()
      }
    }
  }

  private lazy var locationManager: CLLocationManager = {
    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    return manager
  }()

  init(
    locationStore: SolarLocationStore = SolarLocationStore(),
    now: @escaping () -> Date = Date.init
  ) {
    self.locationStore = locationStore
    self.now = now
    super.init()
  }

  func start(enabled: Bool) {
    self.enabled = enabled
    guard enabled else {
      stop()
      return
    }
    let auth = Self.authorization(from: locationManager.authorizationStatus)
    if auth == .notDetermined {
      refresh(forceLocation: false, requestPermission: true)
    } else {
      refresh(forceLocation: false, requestPermission: false)
    }
  }

  func setEnabledByUser(_ enabled: Bool) {
    self.enabled = enabled
    if enabled {
      refresh(forceLocation: true, requestPermission: true)
    } else {
      stop()
    }
  }

  func refresh(forceLocation: Bool = false) {
    refresh(forceLocation: forceLocation, requestPermission: false)
  }

  func currentSnapshot() -> SolarRuntimeSnapshot {
    snapshot
  }

  private func refresh(forceLocation: Bool, requestPermission: Bool) {
    guard enabled else { return }
    guard CLLocationManager.locationServicesEnabled() else {
      failAuthorization(
        authorization: .unavailable,
        message: "Location Services are turned off on this Mac."
      )
      return
    }

    let cached = locationStore.load()
    let authorization = Self.authorization(from: locationManager.authorizationStatus)
    switch authorization {
    case .authorized:
      if let cached {
        reconcile(using: cached)
      }
      let stale = cached.map { now().timeIntervalSince($0.capturedAt) >= 86_400 } ?? true
      if forceLocation || stale {
        requestOneLocation()
      }
    case .notDetermined:
      publish(
        authorization: .notDetermined,
        schedule: nil,
        locationUpdatedAt: nil,
        isRefreshing: requestPermission,
        errorMessage: "Location permission is needed for Sun scheduling."
      )
      if requestPermission {
        NSApp.activate(ignoringOtherApps: true)
        locationManager.requestWhenInUseAuthorization()
      }
    case .denied:
      failAuthorization(
        authorization: .denied,
        message: "Location access is denied. Open Location Settings to enable Sun scheduling."
      )
    case .restricted:
      failAuthorization(
        authorization: .restricted,
        message: "Location access is restricted on this Mac."
      )
    case .unavailable:
      failAuthorization(
        authorization: .unavailable,
        message: "Location is unavailable on this Mac."
      )
    }
  }

  private func requestOneLocation() {
    publish(
      authorization: .authorized,
      schedule: snapshot.schedule,
      locationUpdatedAt: snapshot.locationUpdatedAt,
      isRefreshing: true,
      errorMessage: nil
    )
    locationManager.requestLocation()
  }

  private func reconcile(using cached: CachedSolarLocation) {
    guard enabled else { return }
    let schedule = SolarCalculator.schedule(at: now(), coordinate: cached.coordinate)
    scheduleTransition(for: schedule.nextEvent)
    publish(
      authorization: .authorized,
      schedule: schedule,
      locationUpdatedAt: cached.capturedAt,
      isRefreshing: false,
      errorMessage: nil
    )
    onSchedule?(schedule)
  }

  private func scheduleTransition(for event: SolarEvent?) {
    transitionTimer?.invalidate()
    transitionTimer = nil
    retryTimer?.invalidate()
    retryTimer = nil
    guard let event else { return }
    let timer = Timer(fire: event.date.addingTimeInterval(0.5), interval: 0, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        self?.refresh(forceLocation: false, requestPermission: false)
      }
    }
    timer.tolerance = 1
    RunLoop.main.add(timer, forMode: .common)
    transitionTimer = timer
  }

  private func stop() {
    transitionTimer?.invalidate()
    transitionTimer = nil
    retryTimer?.invalidate()
    retryTimer = nil
    locationManager.stopUpdatingLocation()
    publish(
      authorization: Self.authorization(from: locationManager.authorizationStatus),
      schedule: nil,
      locationUpdatedAt: locationStore.load()?.capturedAt,
      isRefreshing: false,
      errorMessage: nil
    )
  }

  private func failAuthorization(
    authorization: SolarLocationAuthorization,
    message: String
  ) {
    transitionTimer?.invalidate()
    transitionTimer = nil
    retryTimer?.invalidate()
    retryTimer = nil
    locationStore.clear()
    publish(
      authorization: authorization,
      schedule: nil,
      locationUpdatedAt: nil,
      isRefreshing: false,
      errorMessage: message
    )
    onAuthorizationFailure?(message)
  }

  private func publish(
    authorization: SolarLocationAuthorization,
    schedule: SolarSchedule?,
    locationUpdatedAt: Date?,
    isRefreshing: Bool,
    errorMessage: String?
  ) {
    snapshot = SolarRuntimeSnapshot(
      authorization: authorization,
      schedule: schedule,
      locationUpdatedAt: locationUpdatedAt,
      isRefreshing: isRefreshing,
      errorMessage: errorMessage
    )
    onSnapshot?(snapshot)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard enabled else { return }
    let authorization = Self.authorization(from: manager.authorizationStatus)
    switch authorization {
    case .authorized:
      requestOneLocation()
    case .denied:
      failAuthorization(
        authorization: .denied,
        message: "Location access is denied. Open Location Settings to enable Sun scheduling."
      )
    case .restricted:
      failAuthorization(
        authorization: .restricted,
        message: "Location access is restricted on this Mac."
      )
    case .notDetermined, .unavailable:
      break
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard enabled,
      let location = locations.last(where: { $0.horizontalAccuracy >= 0 })
    else { return }
    let coordinate = SolarCoordinate(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude
    ).rounded(to: 1)
    let cached = CachedSolarLocation(coordinate: coordinate, capturedAt: now())
    do {
      try locationStore.save(cached)
      reconcile(using: cached)
    } catch {
      publish(
        authorization: .authorized,
        schedule: snapshot.schedule,
        locationUpdatedAt: snapshot.locationUpdatedAt,
        isRefreshing: false,
        errorMessage: "The local Sun schedule could not be saved."
      )
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard enabled else { return }
    if let cached = locationStore.load() {
      reconcile(using: cached)
      publish(
        authorization: .authorized,
        schedule: snapshot.schedule,
        locationUpdatedAt: cached.capturedAt,
        isRefreshing: false,
        errorMessage: "Using the last saved approximate location."
      )
    } else {
      publish(
        authorization: Self.authorization(from: manager.authorizationStatus),
        schedule: nil,
        locationUpdatedAt: nil,
        isRefreshing: false,
        errorMessage: "A current location could not be determined. Try again later."
      )
      scheduleLocationRetry()
    }
  }

  private func scheduleLocationRetry() {
    retryTimer?.invalidate()
    let timer = Timer(fire: now().addingTimeInterval(15 * 60), interval: 0, repeats: false) {
      [weak self] _ in
      Task { @MainActor in
        self?.refresh(forceLocation: true, requestPermission: false)
      }
    }
    timer.tolerance = 30
    RunLoop.main.add(timer, forMode: .common)
    retryTimer = timer
  }

  private static func authorization(
    from status: CLAuthorizationStatus
  ) -> SolarLocationAuthorization {
    switch status {
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    case .denied:
      .denied
    case .authorizedAlways, .authorizedWhenInUse:
      .authorized
    @unknown default:
      .unavailable
    }
  }
}
