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
        Toggle("Sněží", isOn: Binding(get: { !settings.paused }, set: { settings.paused = !$0 }))
            .keyboardShortcut("s")
        Picker("Intenzita", selection: Binding<Intensity?>(
            get: { settings.config.preset },
            set: { if let p = $0 { settings.config.apply(p) } })) {
            ForEach(Intensity.allCases) { Text($0.title).tag(Optional($0)) }
        }
        Divider()
        Toggle("Sníh na oknech", isOn: $settings.config.onWindows)
        Toggle("Sněhulák", isOn: $settings.config.snowman)
        Toggle("Kurzor rozhání sníh", isOn: $settings.config.mouse)
        if !settings.axTrusted && (settings.config.onDock || settings.config.onIcons) {
            Button("Povolit sníh na Docku a ikonách…") { Tracker.requestAccessibility() }
        }
        Divider()
        Button("Setřást všechen sníh") { delegate.shakeAll() }
        SettingsLink { Text("Nastavení…") }
            .keyboardShortcut(",")
        Divider()
        Button("Ukončit Vločku") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let tracker = Tracker()
    private var renderer: Renderer?
    private var overlays: [Overlay] = []
    private let panel = SnowmanPanel()
    private var pollTimer: Timer?
    private var axTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(path: CommandLine.arguments[i + 1])
            exit(0)
        }
        guard let r = Renderer() else {
            NSLog("Vločka: Metal není k dispozici")
            NSApp.terminate(nil)
            return
        }
        renderer = r
        settings.axTrusted = AXIsProcessTrusted()
        settings.onChange = { [weak self] in self?.settingsChanged() }
        panel.onClick = { [weak self] p in self?.snowmanClicked(p) }
        tracker.refreshWindows()
        rebuildOverlays()

        let poll = Timer(timeInterval: 0.12, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
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

    /// Obrazovka s Dockem: ta, kde se visibleFrame liší dole/vlevo/vpravo, jinak hlavní.
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
    }

    private func refreshAX() {
        let c = settings.config
        tracker.refreshAX(wantDock: c.onDock || c.snowman, wantIcons: c.onIcons) { [weak self] in
            self?.poll()
        }
    }

    private func updatePanel() {
        guard let o = overlays.first(where: { $0.sim.hostsSnowman }), settings.config.snowman,
              let r = o.sim.snowmanHitRect else {
            panel.update(nil)
            return
        }
        panel.update(r.offsetBy(dx: o.sim.origin.x, dy: o.sim.origin.y))
    }

    private func snowmanClicked(_ p: CGPoint) {
        guard let o = overlays.first(where: { $0.sim.hostsSnowman }) else { return }
        o.sim.snowmanClicked(at: CGPoint(x: p.x - o.sim.origin.x, y: p.y - o.sim.origin.y))
        o.wake()
    }

    private func settingsChanged() {
        poll()
        for o in overlays { o.wake() }
    }

    func buildSnowmanNow() {
        for o in overlays where o.sim.hostsSnowman { o.sim.buildSnowmanNow(); o.wake() }
    }

    func shakeAll() {
        for o in overlays { o.sim.shakeAll(); o.wake() }
    }
}
