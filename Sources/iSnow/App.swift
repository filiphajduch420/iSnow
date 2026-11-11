import AppKit
import IOKit.ps
import SwiftUI

@main
struct ISnowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var settings = Settings.shared
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("iSnow", systemImage: settings.paused || state.hidden ? "snowflake.slash" : "snowflake") {
            MenuContent(settings: settings, state: state, delegate: delegate)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @Bindable var settings: Settings
    let state: AppState
    let delegate: AppDelegate

    private static let temperatures: [Double] = [-20, -10, -4, 0, 2, 6]

    var body: some View {
        if state.hidden {
            if let until = state.hiddenUntil {
                Button("Show Effects (until \(until.formatted(date: .omitted, time: .shortened)))") { delegate.showEffects() }
            } else {
                Button("Show Effects") { delegate.showEffects() }
            }
        } else {
            Menu("Hide Effects") {
                Button("For 15 Minutes") { delegate.hideEffects(until: Date().addingTimeInterval(15 * 60)) }
                Button("For 1 Hour") { delegate.hideEffects(until: Date().addingTimeInterval(3600)) }
                Button("Until Tomorrow") { delegate.hideEffects(until: AppState.nextMorning()) }
                Button("Until I Turn Them Back On") { delegate.hideEffects(until: nil) }
            }
        }
        if state.fullscreenPaused && !state.hidden {
            Text("Paused – full-screen app")
        }
        if state.batterySaverActive && !state.hidden {
            Text("Battery saver on")
        }
        Divider()
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
            let f = settings.config.fahrenheit
            ForEach(Self.temperatures, id: \.self) { Text(Temp.format($0, fahrenheit: f)).tag($0) }
            if !Self.temperatures.contains(settings.config.temperature.rounded()) {
                Text(Temp.format(settings.config.temperature, fahrenheit: f)).tag(settings.config.temperature.rounded())
            }
        }
        Divider()
        Toggle("Snow on Windows", isOn: $settings.config.onWindows)
        Toggle("Snow on Widgets", isOn: $settings.config.onWidgets)
        Toggle("Snow on the Dock", isOn: $settings.config.onDock)
        Toggle("Snowman", isOn: $settings.config.snowman)
        Toggle("Christmas Mode", isOn: $settings.config.christmas)
        Toggle("Cursor Scatters Snow", isOn: $settings.config.mouse)
        if !settings.axTrusted && (settings.config.onDock || settings.config.onIcons || settings.config.snowman) {
            Text("Dock position is estimated")
            Button("Allow Snow on the Dock and Icons…") { Tracker.requestAccessibility() }
        }
        Divider()
        if settings.config.christmas {
            Button("Send Santa") { delegate.launchSanta() }
                .disabled(state.hidden)
        }
        Button("Shake Off All Snow") { delegate.shakeAll() }
        Button("Shovel Snow at the Bottom") { delegate.shovelBottom() }
        Button("Settings…") { delegate.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit iSnow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let state = AppState.shared
    private let tracker = Tracker()
    private var renderer: Renderer?
    private var overlays: [Overlay] = []
    private var panels: [SnowmanPanel] = []
    private var pollTimer: Timer?
    private var axTimer: Timer?
    private var screenTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var axTick = 0
    private var settingsWindow: NSWindow?
    private var settingsHost: NSHostingController<AnyView>?
    private var settingsGeneration = 0
    private var onBattery = false
    private var lastDock: CGRect?
    /// For the IOKit power-source callback, which cannot capture anything.
    private static weak var current: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--promo"), i + 1 < CommandLine.arguments.count {
            // Render the README screenshots (desktop scenes and the settings window), then quit.
            Promo.run(dir: CommandLine.arguments[i + 1], delegate: self)
            return
        }
        if CommandLine.arguments.contains("--print-dock") {
            // Debug: show the Dock frame estimated without Accessibility.
            print("estimated Dock:", Tracker.estimatedDockFrame(includeMinimized: false).map { "\($0)" } ?? "none",
                  "safe area:", Tracker.estimatedDockFrame(includeMinimized: true).map { "\($0)" } ?? "none",
                  "minimized windows:", Tracker.minimizedWindowCount())
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(path: CommandLine.arguments[i + 1])
            exit(0)
        }
        guard let r = Renderer() else {
            NSLog("iSnow: Metal is not available")
            NSApp.terminate(nil)
            return
        }
        renderer = r
        Self.current = self
        checkAccessibilityAtLaunch()
        settings.onChange = { [weak self] in self?.settingsChanged() }
        startPowerMonitor()
        tracker.refreshWindows()
        rebuildOverlays()

        setPollInterval(Self.idlePoll)
        let ax = Timer(timeInterval: 1.0, repeats: true) { _ in MainActor.assumeIsolated { self.axTimerFired() } }
        ax.tolerance = 0.2
        RunLoop.main.add(ax, forMode: .common)
        axTimer = ax
        refreshAX()

        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.scheduleRebuild() }
        })
        observers.append(nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.refreshPower(); self.poll() }     // Low Power Mode → 30 fps
        })
        // Things that hide the desktop: display sleep, fast user switching, the lock screen, the screen saver.
        let pairs: [(Notification.Name, Notification.Name, String, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "sleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session", true),
        ]
        for (off, on, reason, clearsAll) in pairs {
            observers.append(ws.addObserver(forName: off, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.suspend(reason, true) }
            })
            observers.append(ws.addObserver(forName: on, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.suspend(reason, false, clearAll: clearsAll) }
            })
        }
        let distributed: [(String, String, String, Bool)] = [
            ("com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "lock", true),
            ("com.apple.screensaver.didstart", "com.apple.screensaver.didstop", "saver", false),
        ]
        for (off, on, reason, clearsAll) in distributed {
            observers.append(dnc.addObserver(forName: Notification.Name(off), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.suspend(reason, true) }
            })
            observers.append(dnc.addObserver(forName: Notification.Name(on), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.suspend(reason, false, clearAll: clearsAll) }
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Windows on the Space we left vanish from the list – they keep their snow.
                let now = CACurrentMediaTime()
                for o in self.overlays { o.sim.noteSpaceChange(now: now) }
                self.poll()
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        settings.saveNow()
    }

    /// Opening the app again (Finder, Spotlight) shows the settings – a way in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Polling

    private var suspendReasons: Set<String> = []
    private var suspended: Bool { !suspendReasons.isEmpty }
    private static let slowPoll = 1.0           // paused, full screen, effects hidden
    private static let idlePoll = 0.2           // 5× per second while windows sit still
    private static let fastPoll = 1.0 / 30      // while a window is being dragged or the cursor is at a snowman
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

    private func suspend(_ reason: String, _ on: Bool, clearAll: Bool = false) {
        let was = suspended
        if on { suspendReasons.insert(reason) } else if clearAll { suspendReasons.removeAll() } else { suspendReasons.remove(reason) }
        guard suspended != was else { return }
        for o in overlays { o.suspended = suspended }
        if suspended {
            pollTimer?.fireDate = .distantFuture
        } else {
            pollTimer?.fireDate = Date()
            refreshPower()
            poll()
        }
    }

    private func poll() {
        guard !suspended else { return }
        if state.hideExpired() { showEffects(); return }
        guard !state.hidden else {
            setPollInterval(Self.slowPoll)
            return
        }
        tracker.refreshWindows()
        let now = CACurrentMediaTime()
        let cfg = effectiveConfig()
        if tracker.dockFrame != lastDock {
            lastDock = tracker.dockFrame
            assignSnowmanHost()
        }
        let screens = screensByID()
        applyDisplayOptions(screens)
        for o in overlays {
            if let s = screens[o.screenID] {
                o.sim.updateMetrics(screenFrame: s.frame, visibleFrame: s.visibleFrame, safeTop: s.safeAreaInsets.top)
            }
            o.fps = cfg.fps
            if o.sim.sync(windows: tracker.windows, occluders: tracker.overlayOccluders, dock: tracker.dockFrame,
                          icons: tracker.icons, widgets: tracker.widgets, dockEstimated: tracker.dockEstimated,
                          dockAvoid: tracker.dockAvoid, menuBars: tracker.menuBars, activeWindow: tracker.activeWindow,
                          now: now, cfg: cfg) || o.sim.isAnimating {
                o.wake()
            }
        }
        let full = overlays.contains { $0.sim.isFullscreenPaused }
        if state.fullscreenPaused != full { state.fullscreenPaused = full }
        updatePanel()
        // Follow a dragged window closely so the snow visibly slides off, then calm down again.
        if overlays.contains(where: { $0.sim.windowMoving }) { lastMotion = now }
        let mouse = NSEvent.mouseLocation
        let atSnowman = panels.contains { $0.isDragging || $0.contains(mouse, margin: 8) }
        let animating = overlays.contains { $0.sim.isAnimating }
        setPollInterval(now - lastMotion < 1.0 || atSnowman ? Self.fastPoll : animating ? Self.idlePoll : Self.slowPoll)
    }

    private func axTimerFired() {
        guard !suspended, !state.hidden else { return }
        axTick += 1
        if axTick % 10 == 0 { refreshPower() }      // backup for the power-source notification
        // Nothing moves (paused, full screen): the Dock and the icons are checked less often.
        if !overlays.contains(where: { $0.sim.isAnimating }) && axTick % 5 != 0 { return }
        refreshAX()
    }

    private func refreshAX() {
        let c = settings.config
        // The Dock is checked every second; desktop icons barely move, so every 4 seconds.
        tracker.refreshAX(wantDock: true, wantIcons: c.onIcons && axTick % 4 == 1) { [weak self] in
            self?.poll()
        }
        noteAccessibilityGranted()
    }

    private func screensByID() -> [CGDirectDisplayID: NSScreen] {
        var out: [CGDirectDisplayID: NSScreen] = [:]
        for s in NSScreen.screens { out[Overlay.displayID(of: s)] = s }
        return out
    }

    // MARK: - Screens

    /// Display changes come in bursts (sleep/wake, plugging in a monitor): rebuild once things settle.
    private func scheduleRebuild() {
        screenTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated { self.rebuildOverlays() } }
        RunLoop.main.add(t, forMode: .common)
        screenTimer = t
    }

    /// One overlay per screen. Overlays of screens that did not change are kept with all their snow.
    private func rebuildOverlays() {
        guard let renderer else { return }
        var old = overlays
        var next: [Overlay] = []
        for s in NSScreen.screens {
            if let i = old.firstIndex(where: { $0.matches(s) }) {
                next.append(old.remove(at: i))
            } else {
                let o = Overlay(screen: s, renderer: renderer, hostsSnowman: false)
                o.suspended = suspended
                if state.hidden { o.setHidden(true) }
                next.append(o)
            }
        }
        for o in old { o.close() }
        overlays = next
        lastDock = tracker.dockFrame
        assignSnowmanHost()
        poll()
    }

    /// The snowmen and the tree live on the screen with the Dock. While the Dock's position is unknown
    /// (hidden, no Accessibility) they stay where they are.
    private func assignSnowmanHost() {
        guard !overlays.isEmpty else { return }
        func frame(_ o: Overlay) -> CGRect { CGRect(origin: o.sim.origin, size: o.sim.size) }
        var host: Int
        if let d = tracker.dockFrame, let i = overlays.firstIndex(where: { frame($0).intersects(d) }) {
            host = i
        } else if let i = overlays.firstIndex(where: { $0.sim.hostsSnowman }) {
            host = i
        } else {
            // The screen whose visible frame is inset at the bottom, otherwise the main screen.
            let screens = screensByID()
            host = overlays.firstIndex { o in
                screens[o.screenID].map { $0.visibleFrame.minY - $0.frame.minY > 8 } ?? false
            } ?? 0
        }
        for (i, o) in overlays.enumerated() where o.sim.hostsSnowman != (i == host) {
            o.sim.hostsSnowman = i == host
            o.wake()
        }
    }

    // MARK: - Power and rendering options

    private func startPowerMonitor() {
        let callback: IOPowerSourceCallbackType = { _ in
            MainActor.assumeIsolated { AppDelegate.current?.refreshPower() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        onBattery = AppState.onBatteryPower()
        state.batterySaverActive = onBattery && settings.config.batterySaver
    }

    private func refreshPower() {
        onBattery = AppState.onBatteryPower()
        let saver = onBattery && settings.config.batterySaver
        guard saver != state.batterySaverActive else { return }
        state.batterySaverActive = saver
        poll()
    }

    /// The settings as the simulations get them: lighter on battery and in Low Power Mode.
    private func effectiveConfig() -> SimConfig {
        var c = settings.config
        if state.batterySaverActive {
            c.fps = min(c.fps, 30)
            c.maxFlakes = min(c.maxFlakes, 500)
            c.density *= 0.6
            c.sparkle = false
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { c.fps = min(c.fps, 30) }
        return c
    }

    /// Render scale and screen-capture visibility follow the settings live.
    private func applyDisplayOptions(_ screens: [CGDirectDisplayID: NSScreen]) {
        let cfg = settings.config
        let retina = cfg.retina && !state.batterySaverActive
        for o in overlays {
            o.setRenderScale(retina ? (screens[o.screenID]?.backingScaleFactor ?? 2) : 1)
            o.setHiddenFromCapture(cfg.hideFromCapture)
        }
        for p in panels { p.setHiddenFromCapture(cfg.hideFromCapture) }
    }

    // MARK: - Hide effects

    /// Turn every effect off for a while (nil = until shown again). Nothing is lost.
    func hideEffects(until: Date?) {
        state.hide(until: until)
        for o in overlays { o.setHidden(true) }
        updatePanel()
        setPollInterval(Self.slowPoll)
    }

    func showEffects() {
        state.show()
        for o in overlays { o.setHidden(false) }
        refreshPower()
        poll()
    }

    // MARK: - Snowmen

    private var snowmanOverlay: Overlay? { overlays.first { $0.sim.hostsSnowman } }

    private func updatePanel() {
        let rects = state.hidden || suspended ? [] : snowmanOverlay?.sim.snowmanHitRects ?? []
        while panels.count < rects.count {
            let i = panels.count
            let p = SnowmanPanel()
            p.onClick = { [weak self] pt in self?.withSnowman { o, l in o.sim.snowmanClicked(i, at: l(pt)) } }
            p.onDrag = { [weak self] pt in self?.withSnowman { o, l in o.sim.dragSnowman(i, to: l(pt)) } }
            p.onDrop = { [weak self] _ in self?.withSnowman { o, _ in o.sim.dropSnowman(i) } }
            p.setHiddenFromCapture(settings.config.hideFromCapture)
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
        if state.batterySaverActive != (onBattery && settings.config.batterySaver) {
            state.batterySaverActive = onBattery && settings.config.batterySaver
        }
        poll()
        for o in overlays { o.wake() }
    }

    func buildSnowmanNow() {
        for o in overlays where o.sim.hostsSnowman { o.sim.buildSnowmanNow(); o.wake() }
    }

    func launchSanta() {
        for o in overlays where o.sim.hostsSnowman { o.sim.launchSanta(); o.wake() }
    }

    func shovelBottom() {
        for o in overlays { o.sim.shovelBottom(); o.wake() }
    }

    func shakeAll() {
        for o in overlays { o.sim.shakeAll(); o.wake() }
    }

    // MARK: - Settings window

    /// Opens the settings (or brings them to the front) on the given tab.
    func showSettings(tab: Int = 0) {
        settings.refreshLoginStatus()       // the user may have changed it in System Settings
        let window: NSWindow
        if let w = settingsWindow, let host = settingsHost {
            window = w
            // A new view only when asked for another tab or reopened – otherwise keep the user's tab.
            if !w.isVisible || tab != 0 {
                settingsGeneration += 1
                host.rootView = settingsRoot(tab: tab)
            }
        } else {
            let host = NSHostingController(rootView: settingsRoot(tab: tab))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.title = String(localized: "iSnow Settings")
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            settingsHost = host
            window = w
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func settingsRoot(tab: Int) -> AnyView {
        AnyView(SettingsView(settings: settings, delegate: self, tab: tab, activates: false).id(settingsGeneration))
    }

    // MARK: - Accessibility

    private static let axGrantedKey = "axGrantedOnce"

    private func noteAccessibilityGranted() {
        if settings.axTrusted && !UserDefaults.standard.bool(forKey: Self.axGrantedKey) {
            UserDefaults.standard.set(true, forKey: Self.axGrantedKey)
        }
    }

    private func checkAccessibilityAtLaunch() {
        settings.axTrusted = AXIsProcessTrusted()
        let d = UserDefaults.standard
        if settings.axTrusted {
            d.set(true, forKey: Self.axGrantedKey)
        } else if d.bool(forKey: Self.axGrantedKey) {
            // It worked before and now it doesn't: macOS dropped the permission (usually after an update),
            // although the switch in System Settings may still look on. Explain once per loss.
            d.set(false, forKey: Self.axGrantedKey)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.showAccessibilityLostAlert()
            }
        } else if settings.config.onDock || settings.config.onIcons, !d.bool(forKey: "askedAccessibility") {
            // Ask once for Accessibility (snow on the Dock and desktop icons).
            d.set(true, forKey: "askedAccessibility")
            Tracker.requestAccessibility()
        }
    }

    private func showAccessibilityLostAlert() {
        guard !AXIsProcessTrusted() else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "iSnow lost its Accessibility permission")
        alert.informativeText = String(localized: """
            macOS stopped recognizing iSnow, which usually happens after an update. The switch in System Settings \
            may still look on, but snow on the Dock and desktop icons no longer works.

            To fix it, open Privacy & Security › Accessibility, select iSnow, remove it with the − button, \
            then add it again with + and switch it on.
            """)
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
