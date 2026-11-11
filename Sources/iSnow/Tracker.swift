import AppKit
import ApplicationServices
import Darwin

/// Another app's window in global Cocoa coordinates (origin at the main screen's bottom left).
struct TrackedWindow: Sendable {
    let id: Int
    let frame: CGRect
}

/// Finds where windows, the Dock and desktop icons are. Reads positions only, never contents or titles.
@MainActor
final class Tracker {
    private(set) var windows: [TrackedWindow] = []      // front to back, layer-0 windows of regular apps
    private(set) var overlayOccluders: [CGRect] = []     // menus, popovers, notifications…
    private(set) var dockFrame: CGRect?                  // nil when unknown (also when the Dock auto-hides)
    private(set) var dockEstimated = false        // frame guessed from the Dock's preferences (no AX)
    private(set) var dockAvoid: CGRect?           // area kept free of other snow (wider when guessed)
    private(set) var icons: [CGRect] = []
    private(set) var widgets: [TrackedWindow] = []     // desktop widgets (WidgetKit, macOS 14+)
    private(set) var menuBars: [CGRect] = []           // visible menu bars (hidden in full-screen spaces)
    /// Front-most layer-0 window of the frontmost regular app; nil if it has none or iSnow is frontmost.
    private(set) var activeWindow: CGRect?
    /// Whether the Dock's own window is in the on-screen list. It is missing in a full-screen Space
    /// (see BUGS H1), so this is a hint for full-screen detection. Only meaningful if the Dock does not auto-hide.
    private(set) var dockWindowOnScreen = false

    private var axBusy = false
    private var dockFromAX = false                // dockFrame came from Accessibility, not the estimate
    private let ownPID = getpid()

    // Window levels (CGWindowLevelKey): Dock 20, main menu 24, status items 25.
    private static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    private static let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
    private static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

    // Cached process information, refreshed on app launch/terminate/hide/unhide or every `appsMaxAge` seconds
    // (activation policies can change at run time).
    private var regularPIDs = Set<pid_t>()
    private var widgetHostPID: pid_t?              // com.apple.notificationcenterui
    private var dockPID: pid_t?                    // com.apple.dock
    private var appsTime: CFAbsoluteTime = 0
    private var appsDirty = true
    private static let appsMaxAge: CFAbsoluteTime = 2
    private var windowServerPID: pid_t?
    private var notWindowServer = Set<pid_t>()

    // The Dock estimate (no Accessibility) is computed off the main thread and cached.
    private static var estimate: DockEstimate?
    private static var estimateTime: CFAbsoluteTime = 0
    private static let estimateMaxAge: CFAbsoluteTime = 10
    private var estimateDirty = true
    private var estimating = false
    private static let estimateQueue = DispatchQueue(label: "iSnow.dock-estimate", qos: .utility)

    /// Lives as long as the app; the observers are never removed.
    private var observers: [NSObjectProtocol] = []

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appsChanged() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.estimateDirty = true }
        })
    }

    private func appsChanged() {
        appsDirty = true
        estimateDirty = true
    }

    private func refreshAppsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard appsDirty || now - appsTime > Self.appsMaxAge else { return }
        appsDirty = false
        appsTime = now
        var regular = Set<pid_t>()
        var widgetHost: pid_t?
        var dock: pid_t?
        for a in NSWorkspace.shared.runningApplications {
            if a.activationPolicy == .regular { regular.insert(a.processIdentifier) }
            switch a.bundleIdentifier {
            case "com.apple.notificationcenterui": widgetHost = a.processIdentifier
            case "com.apple.dock": dock = a.processIdentifier
            default: break
            }
        }
        regularPIDs = regular
        widgetHostPID = widgetHost
        dockPID = dock
    }

    /// The window server's own windows (menu bar backdrop, cursor…) are not occluders. Found by process
    /// name, because the owner name in the window list is a display name.
    private func isWindowServer(_ pid: pid_t) -> Bool {
        if let windowServerPID { return pid == windowServerPID }
        if notWindowServer.contains(pid) { return false }
        if Self.processName(pid) == "WindowServer" {
            windowServerPID = pid
            notWindowServer = []
            return true
        }
        notWindowServer.insert(pid)
        return false
    }

    private nonisolated static func processName(_ pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Cheap window query (CGWindowList, no permission needed), called ~5× per second.
    /// Also finds desktop widgets and the active window.
    func refreshWindows() {
        refreshAppsIfNeeded()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let h = Self.primaryHeight
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontPID = front == ownPID ? nil : front
        var ws: [TrackedWindow] = []
        var occ: [CGRect] = []
        var wid: [TrackedWindow] = []
        var bars: [CGRect] = []
        var active: CGRect?
        var dockSeen = false
        ws.reserveCapacity(list.count)
        for d in list {
            guard let pid = d[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let raw = d[kCGWindowBounds as String],
                  let b = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { continue }
            if (d[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            let r = CGRect(x: b.minX, y: h - b.maxY, width: b.width, height: b.height)
            if layer < 0 {
                // Desktop widgets live in Notification Center's desktop-level windows. The window is
                // the widget's grid cell; the visible widget is inset by about 11 points.
                if let widgetHostPID, pid == widgetHostPID,
                   b.width >= 100, b.height >= 100, b.width < 1000,
                   let id = d[kCGWindowNumber as String] as? Int {
                    wid.append(TrackedWindow(id: id, frame: r.insetBy(dx: 11, dy: 11)))
                }
            } else if layer == 0 {
                // Only regular apps: accessory apps keep invisible helper windows (annotation, dimmers…).
                guard regularPIDs.contains(pid), b.width >= 60, b.height >= 40,
                      let id = d[kCGWindowNumber as String] as? Int else { continue }
                ws.append(TrackedWindow(id: id, frame: r))
                if active == nil, pid == frontPID { active = r }
            } else if layer == Self.mainMenuLevel || layer == Self.statusLevel {
                if b.height < 80 { bars.append(r) }       // the menu bar's backdrop and items
            } else if layer == Self.dockLevel {
                if pid == dockPID { dockSeen = true }
            } else if layer < 1000, !isWindowServer(pid) {
                occ.append(r)
            }
        }
        windows = ws
        overlayOccluders = occ
        widgets = wid
        menuBars = bars
        activeWindow = active
        dockWindowOnScreen = dockSeen
    }

    // MARK: Dock and desktop icons

    /// Dock and desktop icons via Accessibility – on a serial background queue, about once per second.
    /// `wantDock: false` leaves the Dock values as they are (except when the Dock auto-hides).
    func refreshAX(wantDock: Bool, wantIcons: Bool, done: @escaping @MainActor () -> Void) {
        let trusted = AXIsProcessTrusted()
        if Settings.shared.axTrusted != trusted { Settings.shared.axTrusted = trusted }
        refreshEstimateIfNeeded()
        let autohide = Self.estimate?.autohide ?? false
        if autohide { applyEstimate() }               // clears the Dock
        guard trusted else {
            applyEstimate()
            if !icons.isEmpty { icons = [] }
            return
        }
        let probeDock = wantDock && !autohide
        guard probeDock || wantIcons, !axBusy else { return }
        axBusy = true
        let h = Self.primaryHeight
        AXProbe.queue.async {
            let deadline = CFAbsoluteTimeGetCurrent() + AXProbe.budget
            AXProbe.configure()
            let dock: AXProbe.Result<CGRect>? = probeDock ? AXProbe.dockFrame(primaryHeight: h, deadline: deadline) : nil
            let icons: AXProbe.Result<[CGRect]>? = wantIcons ? AXProbe.desktopIcons(primaryHeight: h, deadline: deadline) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.axBusy = false
                    if let dock { self.applyAXDock(dock) }
                    if case .found(let list)? = icons { self.icons = list }
                    done()
                }
            }
        }
    }

    private func applyAXDock(_ r: AXProbe.Result<CGRect>) {
        if Self.estimate?.autohide == true { applyEstimate(); return }
        switch r {
        case .found(let f):
            setDock(f, avoid: f, estimated: false)
            dockFromAX = true
        case .missing:
            applyEstimate()
        case .timedOut:
            break                                   // keep the last known frame
        }
    }

    /// Uses the cached estimate (nil frames when the Dock auto-hides or sits at the side).
    private func applyEstimate() {
        dockFromAX = false
        guard let e = Self.estimate, !e.autohide else {
            setDock(nil, avoid: nil, estimated: false)
            return
        }
        setDock(e.sure, avoid: e.safe, estimated: e.sure != nil)
    }

    private func setDock(_ frame: CGRect?, avoid: CGRect?, estimated: Bool) {
        if dockFrame != frame { dockFrame = frame }
        if dockAvoid != avoid { dockAvoid = avoid }
        if dockEstimated != estimated { dockEstimated = estimated }
    }

    /// Recomputes the estimate in the background every `estimateMaxAge` seconds, or sooner after an app
    /// launched or quit or the screens changed.
    private func refreshEstimateIfNeeded() {
        guard !estimating,
              estimateDirty || Self.estimate == nil
                || CFAbsoluteTimeGetCurrent() - Self.estimateTime > Self.estimateMaxAge else { return }
        estimating = true
        estimateDirty = false
        let input = Self.estimateInput()
        Self.estimateQueue.async {
            let e = DockEstimator.compute(input)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.store(e)
                    self.estimating = false
                    if !self.dockFromAX || e.autohide { self.applyEstimate() }
                }
            }
        }
    }

    private static func store(_ e: DockEstimate) {
        estimate = e
        estimateTime = CFAbsoluteTimeGetCurrent()
    }

    /// Screens and regular apps, gathered on the main thread for the background estimate.
    private static func estimateInput() -> DockEstimator.Input {
        let screens = NSScreen.screens.map { DockEstimator.Screen(frame: $0.frame, visible: $0.visibleFrame) }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            DockEstimator.App(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, hidden: $0.isHidden)
        }
        return DockEstimator.Input(screens: screens, apps: apps)
    }

    /// The cached estimate, or a fresh one computed right here when there is none (e.g. `--print-dock`).
    private static func currentEstimate() -> DockEstimate {
        if let e = estimate, CFAbsoluteTimeGetCurrent() - estimateTime <= estimateMaxAge { return e }
        let e = DockEstimator.compute(estimateInput())
        store(e)
        return e
    }

    /// Without Accessibility the Dock's frame is estimated: it is centred at the bottom of the screen,
    /// as tall as the visible frame's bottom inset, and about one tile per item wide.
    /// `includeMinimized: false` gives a width the Dock surely has (snow on the Dock, snowmen);
    /// `true` adds minimized windows (a safe area to keep free). nil if the Dock auto-hides or is at the side.
    /// May return a cached value (up to ~10 s old).
    static func estimatedDockFrame(includeMinimized: Bool) -> CGRect? {
        let e = currentEstimate()
        return includeMinimized ? e.safe : e.sure
    }

    /// Minimized windows show up in the Dock (counted conservatively, see `DockEstimator`). May be cached.
    static func minimizedWindowCount() -> Int {
        currentEstimate().minimized
    }

    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

struct DockEstimate: Sendable {
    var sure: CGRect?           // width the Dock surely has
    var safe: CGRect?           // including minimized windows
    var minimized: Int
    var autohide: Bool
}

/// Estimates the Dock's frame from its preferences, the running apps and the window list.
/// Runs off the main thread; touches only Sendable inputs, `UserDefaults` and `CGWindowList`.
enum DockEstimator {
    struct Screen: Sendable { let frame: CGRect; let visible: CGRect }
    struct App: Sendable { let pid: pid_t; let bundleID: String?; let hidden: Bool }
    struct Input: Sendable { let screens: [Screen]; let apps: [App] }

    /// Dock height ≈ tile size + 20 pt (measured: tilesize 34 → 54 pt inset).
    static let dockPadding: CGFloat = 20
    static let maxMinimized = 4

    nonisolated static func compute(_ input: Input) -> DockEstimate {
        let d = UserDefaults(suiteName: "com.apple.dock")
        let autohide = d?.bool(forKey: "autohide") ?? false
        let minimized = minimizedWindowCount(apps: input.apps)
        guard !autohide, (d?.string(forKey: "orientation") ?? "bottom") == "bottom",
              let screen = input.screens.first(where: { $0.visible.minY - $0.frame.minY > 20 })
        else { return DockEstimate(sure: nil, safe: nil, minimized: minimized, autohide: autohide) }

        let height = screen.visible.minY - screen.frame.minY
        // A Dock with many items shrinks below its `tilesize` to fit the screen; the inset shows that.
        var tile = CGFloat(d?.double(forKey: "tilesize") ?? 0)
        let fitted = max(height - dockPadding, 8)
        if tile < 16 || fitted < tile { tile = fitted }

        func weight(_ entry: Any) -> CGFloat {
            switch (entry as? [String: Any])?["tile-type"] as? String {
            case "small-spacer-tile", "flex-spacer": return 0.5
            default: return 1
            }
        }
        func bundleID(_ entry: Any) -> String? {
            ((entry as? [String: Any])?["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
        }

        var pinned = Set<String>()
        var pinnedTiles: CGFloat = 0                 // including spacer tiles
        for e in d?.array(forKey: "persistent-apps") ?? [] {
            pinnedTiles += weight(e)
            if let b = bundleID(e) { pinned.insert(b) }
        }
        // Running apps that are not pinned get their own tile (Finder is always there).
        var runningIDs = Set<String>()
        var runningNoID = 0
        for a in input.apps where a.bundleID != "com.apple.finder" {
            if let b = a.bundleID {
                if !pinned.contains(b) { runningIDs.insert(b) }
            } else {
                runningNoID += 1
            }
        }
        let running = runningIDs.count + runningNoID
        let showRecents = d?.object(forKey: "show-recents") as? Bool ?? true
        // Recent apps that are running are already counted above.
        let recents = showRecents ? (d?.array(forKey: "recent-apps") ?? []).filter {
            guard let b = bundleID($0) else { return true }
            return !pinned.contains(b) && !runningIDs.contains(b) && b != "com.apple.finder"
        }.count : 0
        let others = (d?.array(forKey: "persistent-others") ?? []).reduce(CGFloat(0)) { $0 + weight($1) }

        let separators: CGFloat = 1 + (showRecents && running + recents > 0 ? 1 : 0)
        let base = 1 + pinnedTiles + CGFloat(running + recents) + others + 1      // Finder … Trash
        func frame(items: CGFloat) -> CGRect {
            let width = min(items * tile * 1.12 + separators * tile * 0.5 + 24, screen.frame.width)
            return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + 2, width: width, height: height - 2)
        }
        return DockEstimate(sure: frame(items: base), safe: frame(items: base + CGFloat(minimized)),
                            minimized: minimized, autohide: false)
    }

    /// Minimized windows are off screen but belong to running apps. Windows on other Spaces, of hidden apps
    /// and native tabs look similar, so hidden apps are skipped, windows with the same app and frame are
    /// counted once (tabs) and the count is capped. Reads no window titles.
    nonisolated static func minimizedWindowCount(apps: [App]) -> Int {
        let visible = Set(apps.filter { !$0.hidden }.map(\.pid))
        guard !visible.isEmpty,
              let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        var seen = Set<[Int]>()
        for w in all {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowIsOnscreen as String] as? Bool) != true,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, visible.contains(pid),
                  let raw = w[kCGWindowBounds as String],
                  let b = CGRect(dictionaryRepresentation: raw as! CFDictionary),
                  b.width > 200, b.height > 150 else { continue }
            seen.insert([Int(pid), Int(b.minX), Int(b.minY), Int(b.width), Int(b.height)])
            if seen.count >= maxMinimized { break }
        }
        return min(seen.count, maxMinimized)
    }
}

/// Accessibility queries. Everything here runs on `queue`, never on the main thread.
enum AXProbe {
    static let queue = DispatchQueue(label: "iSnow.accessibility", qos: .utility)
    /// Overall time for one round (Dock + icons). Each IPC call additionally times out after 0.25 s.
    static let budget: CFAbsoluteTime = 1.5

    enum Result<T: Sendable>: Sendable {
        case found(T)
        case missing
        case timedOut
    }

    /// Sets the global messaging timeout (applies to every element, including children).
    nonisolated static func configure() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    nonisolated static func values(_ el: AXUIElement, _ names: [String]) -> [AnyObject]? {
        var v: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &v) == .success,
              let arr = v as? [AnyObject], arr.count == names.count else { return nil }
        return arr
    }

    /// The AXValue inside `v` if it has the given type (failed attributes come back as `.axError` values).
    nonisolated static func axValue(_ v: AnyObject, _ type: AXValueType) -> AXValue? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let ax = v as! AXValue
        return AXValueGetType(ax) == type ? ax : nil
    }

    nonisolated static func point(_ v: AnyObject) -> CGPoint? {
        var p = CGPoint.zero
        guard let ax = axValue(v, .cgPoint), AXValueGetValue(ax, .cgPoint, &p) else { return nil }
        return p
    }

    nonisolated static func size(_ v: AnyObject) -> CGSize? {
        var s = CGSize.zero
        guard let ax = axValue(v, .cgSize), AXValueGetValue(ax, .cgSize, &s) else { return nil }
        return s
    }

    /// Role and frame (global Cocoa coordinates) in one IPC call.
    nonisolated static func info(_ el: AXUIElement, primaryHeight h: CGFloat) -> (role: String, frame: CGRect?)? {
        guard let v = values(el, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]) else { return nil }
        let role = v[0] as? String ?? ""
        guard let p = point(v[1]), let s = size(v[2]) else {
            return (role, nil)
        }
        return (role, CGRect(x: p.x, y: h - p.y - s.height, width: s.width, height: s.height))
    }

    nonisolated static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    nonisolated static func role(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return v as? String ?? ""
    }

    nonisolated static func app(_ bundleID: String) -> AXUIElement? {
        guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let el = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    /// Frame of the Dock's icon list.
    nonisolated static func dockFrame(primaryHeight h: CGFloat, deadline: CFAbsoluteTime) -> Result<CGRect> {
        guard let dock = app("com.apple.dock") else { return .missing }
        for c in children(dock) {
            if CFAbsoluteTimeGetCurrent() > deadline { return .timedOut }
            if let i = info(c, primaryHeight: h), i.role == (kAXListRole as String),
               let f = i.frame, f.width > 20, f.height > 20 { return .found(f) }
        }
        return CFAbsoluteTimeGetCurrent() > deadline ? .timedOut : .missing
    }

    /// Desktop icons (Finder → desktop area → icons). `.timedOut` keeps the previous icons instead of a partial list.
    nonisolated static func desktopIcons(primaryHeight h: CGFloat, deadline: CFAbsoluteTime) -> Result<[CGRect]> {
        guard let finder = app("com.apple.finder") else { return .found([]) }
        let iconRoles: Set<String> = [kAXImageRole as String, kAXButtonRole as String, kAXGroupRole as String]
        let containerRoles: Set<String> = [kAXGroupRole as String, kAXListRole as String]
        var out: [CGRect] = []
        func add(_ role: String, _ frame: CGRect?) {
            guard iconRoles.contains(role), var f = frame, f.width > 16, f.width < 260 else { return }
            // Top edge of the icon image (without the label) – roughly a square at the top.
            let side = min(f.width, f.height) * 0.72
            f = CGRect(x: f.midX - side / 2, y: f.maxY - side, width: side, height: side)
            out.append(f)
        }
        for area in children(finder) where role(area) == (kAXScrollAreaRole as String) {
            for g in children(area) {
                if CFAbsoluteTimeGetCurrent() > deadline { return .timedOut }
                guard let gi = info(g, primaryHeight: h) else { continue }
                if containerRoles.contains(gi.role) {
                    for it in children(g) {
                        if CFAbsoluteTimeGetCurrent() > deadline { return .timedOut }
                        if let ii = info(it, primaryHeight: h) { add(ii.role, ii.frame) }
                        if out.count > 200 { return .found(out) }
                    }
                } else {
                    add(gi.role, gi.frame)
                    if out.count > 200 { return .found(out) }
                }
            }
        }
        return .found(out)
    }
}
