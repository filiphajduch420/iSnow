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
    private(set) var icons: [CGRect] = []
    private var axBusy = false
    private let ownPID = getpid()

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cheap window query (CGWindowList, no permission needed), called ~8× per second.
    func refreshWindows() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return }
        let h = Self.primaryHeight
        var ws: [TrackedWindow] = []
        var occ: [CGRect] = []
        ws.reserveCapacity(list.count)
        for d in list {
            guard let pid = d[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let raw = d[kCGWindowBounds as String],
                  let b = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { continue }
            if (d[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            let r = CGRect(x: b.minX, y: h - b.maxY, width: b.width, height: b.height)
            if layer == 0 {
                if b.width >= 60 && b.height >= 40, let id = d[kCGWindowNumber as String] as? Int {
                    ws.append(TrackedWindow(id: id, frame: r))
                }
            } else if layer > 0, layer < 1000, layer != 20, layer != 24, layer != 25,
                      (d[kCGWindowOwnerName as String] as? String) != "Window Server" {
                occ.append(r)
            }
        }
        windows = ws
        overlayOccluders = occ
    }

    /// Dock and desktop icons via Accessibility – off the main thread, once per second.
    func refreshAX(wantDock: Bool, wantIcons: Bool, done: @escaping @MainActor () -> Void) {
        Settings.shared.axTrusted = AXIsProcessTrusted()
        guard Settings.shared.axTrusted, wantDock || wantIcons, !axBusy else {
            if !Settings.shared.axTrusted { dockFrame = nil; icons = [] }
            return
        }
        axBusy = true
        let h = Self.primaryHeight
        Task.detached(priority: .utility) {
            let dock = wantDock ? AXProbe.dockFrame(primaryHeight: h) : nil
            let icons = wantIcons ? AXProbe.desktopIcons(primaryHeight: h) : []
            await MainActor.run {
                self.dockFrame = dock
                self.icons = icons
                self.axBusy = false
                done()
            }
        }
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
