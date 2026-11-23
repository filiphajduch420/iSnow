import AppKit
import Darwin

/// System authorization UI – the Apple Pay sheet, Touch ID and password prompts, permission prompts –
/// checks that no other process's window lies above it (protection against clickjacking). When one does,
/// macOS hides or disables the confirming part, even if that window is transparent and lets clicks
/// through. iSnow's overlays cover every screen, so they step aside while such UI is shown.
///
/// Cheap signals, read in the normal window poll (no extra timers while nothing is shown):
/// - on-screen windows owned by known authorization agents (one executable-name lookup per new pid);
/// - view services that draw inside another app's window (the Apple Pay sheet is a small separate
///   Safari window, level 0, hosting the PassKit extension's view): their processes are followed through
///   `NSWorkspace.runningApplications` (launch/quit only). When one wakes up to foreground priority the
///   snow steps aside at once (the sheet follows ~0.7 s later), and the small window the front app opens
///   while the service is awake is taken as the sheet: the snow stays away exactly until it closes.
///   The service's priority alone can't tell the end – it stays high for minutes after the sheet closed,
///   and a second sheet opens without any change.
@MainActor
final class SecureUI {
    static let shared = SecureUI()

    /// Executables that show authorization UI in windows of their own.
    nonisolated static let windowOwners: Set<String> = [
        "SecurityAgent",                                    // administrator password prompts
        "coreautha",                                        // Touch ID / password prompts (sudo, apps)
        "LocalAuthenticationRemoteService",                 // Touch ID sheets inside apps
        "AuthorizationPromptService",                       // privacy permission prompts (TCC)
        "universalAccessAuthWarn",                          // Accessibility permission prompt
        "UserNotificationCenter",                           // system alerts with Allow / Deny
        "AuthenticationServicesAgent",                      // passkeys, passwords
        "AKAuthorizationRemoteViewService",                 // Sign in with Apple
        "AuthKitUIMacService",
        "com.apple.PassKit.PaymentAuthorizationUIExtension",  // Apple Pay sheet
        "com.apple.PassKitUIXPCService",
        "AMSUIPaymentViewService_macOS",                    // App Store purchase confirmation
        "ServicesPaymentAngel",
    ]

    /// View services (bundle IDs) that draw their UI inside another app's window.
    nonisolated static let services: Set<String> = [
        "com.apple.PassKit.PaymentAuthorizationUIExtension",
        "com.apple.AMSUIPaymentViewService",
        "com.apple.LocalAuthenticationRemoteService",
        "com.apple.AuthKitUI.AKAuthorizationRemoteViewService",
    ]
    /// A service above this task priority is in use (background = 4, foreground = 31, focal UI = 46/47).
    nonisolated static let idlePriority: Int32 = 20
    /// After a service wakes up, the snow stays away this long waiting for its sheet window
    /// (it appears ~0.7 s later); no sheet by then means it was an unrelated wake-up.
    nonisolated static let wakeGrace: CFAbsoluteTime = 1.6
    /// A sheet is a small window: bigger new windows of the front app are ordinary windows.
    nonisolated static let sheetMaxWidth: CGFloat = 800
    nonisolated static let sheetMaxHeight: CGFloat = 900

    /// iSnow's highest window level (the snowman panel sits right above the overlays). Prompts above it,
    /// like the password and Touch ID dialogs (level 1000), are not covered and need nothing.
    nonisolated static let ownTopLevel = Int(CGWindowLevelForKey(.overlayWindow)) + 1

    /// A window of an authorization agent at `layer` with this size could lie under iSnow's windows.
    nonisolated static func coverable(layer: Int, width: CGFloat, height: CGFloat) -> Bool {
        layer >= 0 && layer <= ownTopLevel && width >= 40 && height >= 40
    }

    /// Debug: `ISNOW_SECUREUI=1` acts as if authorization UI were always shown.
    private static let forced = ProcessInfo.processInfo.environment["ISNOW_SECUREUI"] == "1"

    /// Window polls while the overlays are put away (the end must be noticed quickly).
    static let pollInterval = 0.5

    /// An authorization agent had an on-screen window in the last window poll (set by the tracker).
    var windowShown = false
    private var servicePIDs: Set<pid_t> = []
    /// A view service runs at foreground priority (read with every window list).
    private(set) var serviceAwake = false
    /// When the service last woke up from background priority.
    private var wokeAt: CFAbsoluteTime = -100
    /// Level-0 window numbers of the last window list, and the window taken as the open sheet.
    private var lastWindowIDs: Set<Int> = []
    private var sheetID: Int?
    private var ownerByPID: [pid_t: Bool] = [:]
    private var ownerCacheTime: CFAbsoluteTime = 0
    private var observation: NSKeyValueObservation?
    private var onChange: (@MainActor () -> Void)?
    private var recheck: Timer?

    /// Authorization UI is (probably) on screen: keep every iSnow window away. Read once per window poll.
    var active: Bool {
        if windowShown || Self.forced { return true }
        if sheetID != nil { return true }
        let left = Self.wakeGrace - (CFAbsoluteTimeGetCurrent() - wokeAt)
        if serviceAwake && left > 0 { scheduleRecheck(after: left + 0.05); return true }
        return false
    }

    /// Fed by the tracker with every window list: the level-0 windows (number, owner, size) and the
    /// front app. Wakes of the view services and the sheet window are found here.
    func noteWindows(_ list: [(id: Int, pid: pid_t, width: CGFloat, height: CGFloat)], front: pid_t?) {
        let now = CFAbsoluteTimeGetCurrent()
        var awake = false
        for pid in servicePIDs {
            if let p = Self.taskPriority(pid), p > Self.idlePriority { awake = true; break }
        }
        if awake && !serviceAwake { wokeAt = now }
        serviceAwake = awake
        var ids = Set<Int>()
        ids.reserveCapacity(list.count)
        for w in list { ids.insert(w.id) }
        if let s = sheetID, !ids.contains(s) { sheetID = nil }       // the sheet closed
        if sheetID == nil, awake, !lastWindowIDs.isEmpty {
            for w in list where !lastWindowIDs.contains(w.id) && w.pid == front
                && w.width <= Self.sheetMaxWidth && w.height <= Self.sheetMaxHeight {
                sheetID = w.id
                break
            }
        }
        lastWindowIDs = ids
    }

    /// Looks again (through `onChange`, i.e. a window poll) when the wake-up grace runs out.
    private func scheduleRecheck(after delay: CFAbsoluteTime) {
        guard recheck == nil else { return }
        let t = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                SecureUI.shared.recheck = nil
                SecureUI.shared.onChange?()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        recheck = t
    }

    /// Starts following the view services; `changed` runs when one launched or quit.
    func start(changed: @escaping @MainActor () -> Void) {
        onChange = changed
        rescanServices()
        observation = NSWorkspace.shared.observe(\.runningApplications, options: []) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SecureUI.shared.rescanServices() } }
        }
    }

    private func rescanServices() {
        var next = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, Self.services.contains(id), !app.isTerminated else { continue }
            next.insert(app.processIdentifier)
        }
        guard next != servicePIDs else { return }
        servicePIDs = next
        onChange?()
    }

    /// Whether `pid` is one of the authorization agents (`windowOwners`). Cached per pid; the cache is
    /// dropped every 30 s so a reused pid is classified again.
    func ownsSecureWindows(_ pid: pid_t) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - ownerCacheTime > 30 || ownerByPID.count > 256 {
            ownerCacheTime = now
            ownerByPID.removeAll(keepingCapacity: true)
        }
        if let known = ownerByPID[pid] { return known }
        let yes = Self.executableName(pid).map { Self.windowOwners.contains($0) } ?? false
        ownerByPID[pid] = yes
        return yes
    }

    /// Last path component of the process's executable (the full name – `p_comm` is cut at 16 bytes).
    nonisolated static func executableName(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let path = String(decoding: buf.prefix(Int(n)), as: UTF8.self)
        return (path as NSString).lastPathComponent
    }

    /// The task's base priority (one syscall), nil if the process is gone.
    nonisolated static func taskPriority(_ pid: pid_t) -> Int32? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_priority
    }

    /// Debug (`iSnow --secure-ui [seconds]`): prints what the detection sees, twice a second.
    /// Open an Apple Pay sheet (or a Touch ID / password prompt) meanwhile – without paying.
    func runProbe(seconds: Double) {
        print("watched owners:", Self.windowOwners.sorted().joined(separator: ", "))
        print("watched services:", Self.services.sorted().joined(separator: ", "))
        rescanServices()
        let end = CFAbsoluteTimeGetCurrent() + seconds
        var lastLine = ""
        repeat {
            var parts: [String] = []
            var shown = false
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            var feed: [(id: Int, pid: pid_t, width: CGFloat, height: CGFloat)] = []
            for w in list where (w[kCGWindowLayer as String] as? Int ?? -1) == 0
                && (w[kCGWindowAlpha as String] as? Double ?? 1) >= 0.05 {
                guard let id = w[kCGWindowNumber as String] as? Int,
                      let pid = (w[kCGWindowOwnerPID as String] as? Int).flatMap({ pid_t(exactly: $0) }) else { continue }
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                feed.append((id, pid, CGFloat(b["Width"] as? Double ?? 0), CGFloat(b["Height"] as? Double ?? 0)))
            }
            noteWindows(feed, front: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            if let sheetID { parts.append("sheet window #\(sheetID)") }
            for w in list {
                guard let pid = (w[kCGWindowOwnerPID as String] as? Int).flatMap({ pid_t(exactly: $0) }),
                      ownsSecureWindows(pid) else { continue }
                let layer = w[kCGWindowLayer as String] as? Int ?? 0
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let width = b["Width"] as? Double ?? 0, height = b["Height"] as? Double ?? 0
                let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
                let counts = Self.coverable(layer: layer, width: width, height: height) && alpha >= 0.05
                if counts { shown = true }
                parts.append("window \(Self.executableName(pid) ?? "?") layer \(layer) \(Int(width))×\(Int(height))"
                             + " alpha \(alpha)\(counts ? "" : " (ignored)")")
            }
            windowShown = shown
            for pid in servicePIDs.sorted() {
                let name = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
                parts.append("service \(name) pid \(pid) priority \(Self.taskPriority(pid).map(String.init) ?? "-")")
            }
            let line = "active=\(active) | " + (parts.isEmpty ? "nothing" : parts.joined(separator: " | "))
            if line != lastLine {
                print(String(format: "%.1f s ", seconds - (end - CFAbsoluteTimeGetCurrent())) + line)
                lastLine = line
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))   // lets the service list update
        } while CFAbsoluteTimeGetCurrent() < end
    }
}
