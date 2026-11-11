import Foundation
import IOKit.ps
import Observation

/// Runtime state shown in the menu: hidden effects, battery saver, full-screen pause.
@MainActor @Observable
final class AppState {
    static let shared = AppState()

    /// All effects are temporarily hidden (the simulation is kept as it was).
    private(set) var hidden = false
    /// When hidden for a while: the moment the effects come back (nil = until turned back on).
    private(set) var hiddenUntil: Date?
    /// Running on battery with the battery saver enabled.
    var batterySaverActive = false
    /// Some screen is covered by a full-screen app, the snow there is paused.
    var fullscreenPaused = false

    private init() {}

    func hide(until: Date?) {
        hidden = true
        hiddenUntil = until
    }

    func show() {
        hidden = false
        hiddenUntil = nil
    }

    /// The effects should come back now (a timed hide has run out).
    func hideExpired(now: Date = Date()) -> Bool {
        guard hidden, let hiddenUntil else { return false }
        return now >= hiddenUntil
    }

    /// The next 8:00 at least an hour away ("until tomorrow").
    static func nextMorning(after now: Date = Date()) -> Date {
        let cal = Calendar.current
        var d = cal.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(12 * 3600)
        if d.timeIntervalSince(now) < 3600 { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    /// True when the Mac is running on its battery (IOKit power sources).
    nonisolated static func onBatteryPower() -> Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
