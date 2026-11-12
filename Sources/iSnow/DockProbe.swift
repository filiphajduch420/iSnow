import AppKit
import ApplicationServices

/// Debug: `iSnow --dock-probe` prints the Dock's frame from Accessibility 20 times a second for a few
/// seconds (ISNOW_PROBE_SECONDS, default 6). With ISNOW_PROBE_MOUSE=1 it moves the cursor to the bottom
/// edge after 1 s and away again after 3 s, so an auto-hiding Dock shows and hides while it watches.
@MainActor
enum DockProbe {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        let seconds = Double(env["ISNOW_PROBE_SECONDS"] ?? "") ?? 6
        let moveMouse = env["ISNOW_PROBE_MOUSE"] == "1"
        let h = Tracker.primaryHeight
        let screen = NSScreen.screens.first?.frame ?? .zero
        print("trusted:", AXIsProcessTrusted(), "autohide:", DockEstimator.autohide(), "screen:", screen)
        let start = CFAbsoluteTimeGetCurrent()
        var movedIn = false, movedOut = false
        _ = movedIn
        var last = ""
        while CFAbsoluteTimeGetCurrent() - start < seconds {
            let t = CFAbsoluteTimeGetCurrent() - start
            if moveMouse && t > 1 && t < 2.2 {
                // Push against the bottom edge for a while, like a real mouse does.
                movedIn = true
                post(CGPoint(x: screen.midX, y: screen.height - 1), dy: 6)
            }
            if moveMouse && !movedOut && t > 3 {
                movedOut = true
                post(CGPoint(x: screen.midX, y: screen.height / 2))
            }
            let r = AXProbe.dockFrame(primaryHeight: h, deadline: CFAbsoluteTimeGetCurrent() + 0.3)
            let line: String
            switch r {
            case .found(let f): line = "found \(f.integral)"
            case .missing: line = "missing"
            case .timedOut: line = "timed out"
            }
            if line != last { print(String(format: "%.2f", t), line); last = line }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// A mouse move at a point in global top-left (Quartz) coordinates, as a real mouse would send it.
    private static func post(_ p: CGPoint, dy: Int64 = 0) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        else { return }
        if dy != 0 { e.setIntegerValueField(.mouseEventDeltaY, value: dy) }
        e.post(tap: .cghidEventTap)
    }
}
