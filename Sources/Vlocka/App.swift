import AppKit
import SwiftUI

@main
struct VlockaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var settings = Settings.shared

    var body: some Scene {
        MenuBarExtra("Vločka", systemImage: settings.paused ? "snowflake.slash" : "snowflake") {
            MenuContent(settings: settings, delegate: delegate)
        }
        .menuBarExtraStyle(.menu)

        SwiftUI.Settings {
            SettingsView(settings: settings, delegate: delegate)
        }
    }
}

struct MenuContent: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate

    var body: some View {
        Toggle("Snowing", isOn: Binding(get: { !settings.paused }, set: { settings.paused = !$0 }))
            .keyboardShortcut("s")
        Picker("Intensity", selection: Binding<Intensity?>(
            get: { settings.config.preset },
            set: { if let p = $0 { settings.config.apply(p) } })) {
            ForEach(Intensity.allCases) { Text($0.title).tag(Optional($0)) }
        }
        Picker("Temperature", selection: Binding<Double>(
            get: { settings.config.temperature.rounded() },
            set: { settings.config.temperature = $0 })) {
            ForEach([-20.0, -10, -4, 0, 2, 6], id: \.self) { Text(String(format: "%+.0f °C", $0)).tag($0) }
            if ![-20.0, -10, -4, 0, 2, 6].contains(settings.config.temperature.rounded()) {
                Text(String(format: "%+.0f °C", settings.config.temperature)).tag(settings.config.temperature.rounded())
            }
        }
        Divider()
        Toggle("Snow on Windows", isOn: $settings.config.onWindows)
        Toggle("Snowman", isOn: $settings.config.snowman)
        Toggle("Cursor Scatters Snow", isOn: $settings.config.mouse)
        if !settings.axTrusted && (settings.config.onDock || settings.config.onIcons) {
            Button("Allow Snow on the Dock and Icons…") { Tracker.requestAccessibility() }
        }
        Divider()
        Button("Shake Off All Snow") { delegate.shakeAll() }
        Button("Shovel Snow at the Bottom") { delegate.shovelBottom() }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Vločka") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let tracker = Tracker()
    private var renderer: Renderer?
    private var overlays: [Overlay] = []
    private var panels: [SnowmanPanel] = []
    private var pollTimer: Timer?
    private var axTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var axTick = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(path: CommandLine.arguments[i + 1])
            exit(0)
        }
        guard let r = Renderer() else {
            NSLog("Vločka: Metal is not available")
            NSApp.terminate(nil)
            return
        }
        renderer = r
        settings.axTrusted = AXIsProcessTrusted()
        settings.onChange = { [weak self] in self?.settingsChanged() }
        tracker.refreshWindows()
        rebuildOverlays()

        setPollInterval(Self.idlePoll)
        let ax = Timer(timeInterval: 1.0, repeats: true) { _ in MainActor.assumeIsolated { self.refreshAX() } }
        RunLoop.main.add(ax, forMode: .common)
        axTimer = ax
        refreshAX()

        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.rebuildOverlays() }
        })
        observers.append(nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.applyPower() }
        })
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.suspend(true) }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.suspend(false) }
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.poll() }
        })
    }

    private var suspended = false
    private static let idlePoll = 0.2           // 5× per second while windows sit still
    private static let fastPoll = 1.0 / 30      // while a window is being dragged
    private var pollInterval = 0.0
    private var lastMotion = 0.0

    private func setPollInterval(_ t: Double) {
        guard t != pollInterval else { return }
        pollInterval = t
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: t, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
        timer.tolerance = t * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func suspend(_ on: Bool) {
        suspended = on
        pollTimer?.fireDate = on ? .distantFuture : Date()
        for o in overlays { if on { o.sleep() } else { o.wake() } }
    }

    private func applyPower() {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        for o in overlays { o.lowPower = low }
    }

    private func rebuildOverlays() {
        guard let renderer else { return }
        for o in overlays { o.close() }
        overlays = []
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let dockScreen = dockScreenIndex(screens)
        for (i, s) in screens.enumerated() {
            overlays.append(Overlay(screen: s, renderer: renderer, hostsSnowman: i == dockScreen))
        }
        applyPower()
        poll()
    }

    /// Screen hosting the Dock: the one whose visibleFrame is inset at the bottom, otherwise the main screen.
    private func dockScreenIndex(_ screens: [NSScreen]) -> Int {
        if let d = tracker.dockFrame, let i = screens.firstIndex(where: { $0.frame.intersects(d) }) { return i }
        return screens.firstIndex(where: { $0.visibleFrame.minY - $0.frame.minY > 8 }) ?? 0
    }

    private func poll() {
        guard !suspended else { return }
        tracker.refreshWindows()
        let now = CACurrentMediaTime()
        let cfg = settings.config
        for o in overlays {
            o.fps = cfg.fps
            if o.sim.sync(windows: tracker.windows, occluders: tracker.overlayOccluders, dock: tracker.dockFrame,
                          icons: tracker.icons, now: now, cfg: cfg) || o.sim.isAnimating {
                o.wake()
            }
        }
        updatePanel()
        // Follow a dragged window closely so the snow visibly slides off, then calm down again.
        if overlays.contains(where: { $0.sim.windowMoving }) { lastMotion = now }
        setPollInterval(now - lastMotion < 1.0 ? Self.fastPoll : Self.idlePoll)
    }

    private func refreshAX() {
        let c = settings.config
        axTick += 1
        // The Dock is checked every second; desktop icons barely move, so every 4 seconds.
        tracker.refreshAX(wantDock: true, wantIcons: c.onIcons && axTick % 4 == 1) { [weak self] in
            self?.poll()
        }
    }

    private var snowmanOverlay: Overlay? { overlays.first { $0.sim.hostsSnowman } }

    private func updatePanel() {
        let rects = snowmanOverlay?.sim.snowmanHitRects ?? []
        while panels.count < rects.count {
            let i = panels.count
            let p = SnowmanPanel()
            p.onClick = { [weak self] pt in self?.withSnowman { o, l in o.sim.snowmanClicked(i, at: l(pt)) } }
            p.onDrag = { [weak self] pt in self?.withSnowman { o, l in o.sim.dragSnowman(i, to: l(pt)) } }
            p.onDrop = { [weak self] _ in self?.withSnowman { o, _ in o.sim.dropSnowman(i) } }
            panels.append(p)
        }
        while panels.count > rects.count { panels.removeLast().close() }
        guard let o = snowmanOverlay, settings.config.snowman else {
            panels.forEach { $0.update(nil) }
            return
        }
        for (i, r) in rects.enumerated() {
            panels[i].update(r.map { $0.offsetBy(dx: o.sim.origin.x, dy: o.sim.origin.y) })
        }
    }

    /// Runs `body` with the overlay that hosts the snowmen and a global→local point converter.
    private func withSnowman(_ body: (Overlay, (CGPoint) -> CGPoint) -> Void) {
        guard let o = snowmanOverlay else { return }
        let origin = o.sim.origin
        body(o) { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        o.wake()
    }

    func resetSnowmen() {
        withSnowman { o, _ in o.sim.resetSnowmen() }
    }

    private func settingsChanged() {
        poll()
        for o in overlays { o.wake() }
    }

    func buildSnowmanNow() {
        for o in overlays where o.sim.hostsSnowman { o.sim.buildSnowmanNow(); o.wake() }
    }

    func shovelBottom() {
        for o in overlays { o.sim.shovelBottom(); o.wake() }
    }

    func shakeAll() {
        for o in overlays { o.sim.shakeAll(); o.wake() }
    }
}
