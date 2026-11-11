import AppKit
import ApplicationServices

/// Another app's window in global Cocoa coordinates (origin at the main screen's bottom left).
struct TrackedWindow: Sendable {
    let id: Int
    let frame: CGRect
}

/// Finds where windows, the Dock and desktop icons are. Reads positions only, never contents.
@MainActor
final class Tracker {
    private(set) var windows: [TrackedWindow] = []      // front to back
    private(set) var overlayOccluders: [CGRect] = []     // menus, popovers, notifications…
    private(set) var dockFrame: CGRect?
    private(set) var dockEstimated = false        // frame guessed from the Dock's preferences (no AX)
    private(set) var dockAvoid: CGRect?           // area kept free of other snow (wider when guessed)
    private(set) var icons: [CGRect] = []
    private(set) var widgets: [TrackedWindow] = []     // desktop widgets (WidgetKit, macOS 14+)
    private(set) var menuBars: [CGRect] = []           // visible menu bars (hidden in full-screen spaces)
    private var axBusy = false
    private let ownPID = getpid()

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cheap window query (CGWindowList, no permission needed), called ~5× per second.
    /// Also finds desktop widgets.
    func refreshWindows() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let h = Self.primaryHeight
        var ws: [TrackedWindow] = []
        var occ: [CGRect] = []
        var wid: [TrackedWindow] = []
        var bars: [CGRect] = []
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
                if (d[kCGWindowOwnerName as String] as? String) == "Notification Center",
                   b.width >= 100, b.height >= 100, b.width < 1000,
                   let id = d[kCGWindowNumber as String] as? Int {
                    wid.append(TrackedWindow(id: id, frame: r.insetBy(dx: 11, dy: 11)))
                }
            } else if layer == 0 {
                if b.width >= 60 && b.height >= 40, let id = d[kCGWindowNumber as String] as? Int {
                    ws.append(TrackedWindow(id: id, frame: r))
                }
            } else if layer == 24 || layer == 25 {
                if b.height < 80 { bars.append(r) }       // the menu bar's backdrop and items
            } else if layer > 0, layer < 1000, layer != 20,
                      (d[kCGWindowOwnerName as String] as? String) != "Window Server" {
                occ.append(r)
            }
        }
        windows = ws
        overlayOccluders = occ
        widgets = wid
        menuBars = bars
    }

    /// Dock and desktop icons via Accessibility – off the main thread, once per second.
    func refreshAX(wantDock: Bool, wantIcons: Bool, done: @escaping @MainActor () -> Void) {
        Settings.shared.axTrusted = AXIsProcessTrusted()
        guard Settings.shared.axTrusted, !axBusy else {
            if !Settings.shared.axTrusted {
                dockFrame = Self.estimatedDockFrame(includeMinimized: false)
                dockAvoid = Self.estimatedDockFrame(includeMinimized: true)
                dockEstimated = dockFrame != nil
                icons = []
            }
            return
        }
        axBusy = true
        let h = Self.primaryHeight
        Task.detached(priority: .utility) {
            let dock = wantDock ? AXProbe.dockFrame(primaryHeight: h) : nil
            let icons = wantIcons ? AXProbe.desktopIcons(primaryHeight: h) : nil
            await MainActor.run {
                self.dockFrame = dock ?? Self.estimatedDockFrame(includeMinimized: false)
                self.dockAvoid = dock ?? Self.estimatedDockFrame(includeMinimized: true)
                self.dockEstimated = dock == nil && self.dockFrame != nil
                if let icons { self.icons = icons }
                self.axBusy = false
                done()
            }
        }
    }

    /// Without Accessibility the Dock's frame is estimated: it is centred at the bottom of the screen,
    /// as tall as the visible frame's bottom inset, and about one tile per item wide.
    /// `includeMinimized: false` gives a width the Dock surely has (snow on the Dock, snowmen);
    /// `true` adds minimized windows (over-counted, so it is a safe area to keep free).
    static func estimatedDockFrame(includeMinimized: Bool) -> CGRect? {
        let d = UserDefaults(suiteName: "com.apple.dock")
        guard (d?.string(forKey: "orientation") ?? "bottom") == "bottom",
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.minY - $0.frame.minY > 20 }) else { return nil }
        let height = screen.visibleFrame.minY - screen.frame.minY
        var tile = CGFloat(d?.double(forKey: "tilesize") ?? 0)
        if tile < 16 { tile = height - 20 }
        var pinned = Set<String>()
        for e in d?.array(forKey: "persistent-apps") ?? [] {
            if let td = (e as? [String: Any])?["tile-data"] as? [String: Any], let b = td["bundle-identifier"] as? String {
                pinned.insert(b)
            }
        }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                && !pinned.contains($0.bundleIdentifier ?? "")
        }.count
        let showRecents = d?.object(forKey: "show-recents") as? Bool ?? true
        let recents = showRecents ? (d?.array(forKey: "recent-apps")?.count ?? 0) : 0
        let others = d?.array(forKey: "persistent-others")?.count ?? 0
        let minimized = includeMinimized ? minimizedWindowCount() : 0
        let items = 1 + pinned.count + running + recents + others + minimized + 1     // Finder … Trash
        let separators: CGFloat = 1 + (recents > 0 ? 1 : 0) + (minimized > 0 && others == 0 ? 1 : 0)
        let width = CGFloat(items) * tile * 1.12 + separators * tile * 0.5 + 24
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + 2, width: width, height: height - 2)
    }

    /// Minimized windows show up in the Dock. They are off screen but still belong to running apps;
    /// windows on other Spaces look the same, so the count is capped.
    static func minimizedWindowCount() -> Int {
        guard let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier })
        var n = 0
        for w in all {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowIsOnscreen as String] as? Bool) != true,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, regular.contains(pid),
                  let raw = w[kCGWindowBounds as String],
                  let b = CGRect(dictionaryRepresentation: raw as! CFDictionary),
                  b.width > 200, b.height > 150,
                  (w[kCGWindowName as String] as? String).map({ !$0.isEmpty }) ?? true else { continue }
            n += 1
        }
        return min(n, 8)
    }

    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

enum AXProbe {
    nonisolated static func frame(_ el: AXUIElement, primaryHeight h: CGFloat) -> CGRect? {
        var pv: CFTypeRef?
        var sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue((pv as! AXValue), .cgPoint, &p)
        AXValueGetValue((sv as! AXValue), .cgSize, &s)
        return CGRect(x: p.x, y: h - p.y - s.height, width: s.width, height: s.height)
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
    nonisolated static func dockFrame(primaryHeight h: CGFloat) -> CGRect? {
        guard let dock = app("com.apple.dock") else { return nil }
        for c in children(dock) where role(c) == (kAXListRole as String) {
            if let f = frame(c, primaryHeight: h), f.width > 20, f.height > 20 { return f }
        }
        return nil
    }

    /// Desktop icons (Finder → desktop area → icons).
    nonisolated static func desktopIcons(primaryHeight h: CGFloat) -> [CGRect] {
        guard let finder = app("com.apple.finder") else { return [] }
        var out: [CGRect] = []
        for area in children(finder) where role(area) == (kAXScrollAreaRole as String) {
            for g in children(area) {
                let items = role(g) == (kAXGroupRole as String) || role(g) == (kAXListRole as String) ? children(g) : [g]
                for it in items {
                    let r = role(it)
                    guard r == (kAXImageRole as String) || r == (kAXButtonRole as String) || r == (kAXGroupRole as String),
                          var f = frame(it, primaryHeight: h), f.width > 16, f.width < 260 else { continue }
                    // Top edge of the icon image (without the label) – roughly a square at the top.
                    let side = min(f.width, f.height) * 0.72
                    f = CGRect(x: f.midX - side / 2, y: f.maxY - side, width: side, height: side)
                    out.append(f)
                    if out.count > 200 { return out }
                }
            }
        }
        return out
    }
}
