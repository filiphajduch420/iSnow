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

/// How often the app looks at the windows (CGWindowList) and probes the Dock (Accessibility).
/// Every look wakes the window server, so the rate follows what is going on.
enum PollSchedule {
    static let slow = 1.0               // nothing animates (snow paused)
    static let fullscreen = 0.5         // every screen shows a full-screen app: only leaving it matters
    static let busy = 0.2               // 5× per second for a few seconds after something changed
    static let calm = 0.4               // 2.5× per second while the desktop is static
    static let pressed = 0.1            // a mouse button is down: a window drag may start any moment
    static let fast = 1.0 / 30          // a window is being dragged or the cursor is at a snowman
    /// How long `busy` is kept after the last change before backing off to `calm`.
    static let calmAfter = 3.0
    /// How long `fast` is kept after a window last moved.
    static let motionHold = 1.0

    /// Seconds until the next window poll.
    static func interval(now: Double, lastChange: Double, lastMotion: Double, buttonDown: Bool,
                         atSnowman: Bool, animating: Bool, allFullscreen: Bool) -> Double {
        if atSnowman || now - lastMotion < motionHold { return fast }
        if allFullscreen { return animating ? fullscreen : slow }
        if buttonDown { return pressed }
        if !animating { return slow }
        return now - lastChange < calmAfter ? busy : calm
    }

    /// Timer tolerance: lets the system coalesce the wake-up with the display link and other apps.
    /// The quick polls that follow a drag stay tight.
    static func tolerance(for interval: Double) -> Double {
        interval >= busy ? interval * 0.25 : interval * 0.1
    }

    /// Dock probe: every second, every 3 s once the Dock was the same in 5 probes in a row,
    /// every 5 s while nothing animates. Without Accessibility the probe only checks the permission
    /// (and uses the cached estimate) – every second, so a grant is noticed quickly.
    static let axStableProbes = 5
    static func axInterval(stableProbes: Int, animating: Bool, trusted: Bool = true) -> Double {
        if !animating { return 5 }
        return stableProbes >= axStableProbes && trusted ? 3 : 1
    }

    /// Backup check of the power source (the IOKit notification is the primary path).
    static let powerCheck = 60.0
    /// Screen metrics and display options are re-read at least this often (and on every change).
    static let metricsEvery = 1.0
}
