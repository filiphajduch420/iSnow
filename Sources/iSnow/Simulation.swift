import CoreGraphics
import Foundation
import QuartzCore

/// Triangle mesh vertex (drifts, icicles, snowman) – 24 B, matches the shader.
struct Vertex { var x, y, r, g, b, a: Float }
/// Round particle instance (flake, snow chunk, snowball) – 16 B.
struct Particle { var x, y, size, alpha: Float }

enum SurfaceKind { case window, dock, icon, widget, ground }

struct Flake {
    var x, y, vx, vy, phase, freq, amp, depth, size, alpha: Float
    var sparkle: Bool
}

struct Debris {
    var x, y, vx, vy, size, alpha: Float
    var lands: Bool
    var fade: Float = 1.6        // alpha lost per second (powder only)
}

struct Shard {            // broken-off icicle
    var x, y, vy, len, width: Float
}

struct Snowball {
    var x, y, vx, vy, t, duration: Float
    var target: Int       // drift key, -999 = none
    var tx: Float
    // [1.3 snowmen] snowball fights
    var victim = -1                   // id of the snowman it is aimed at (-1 = none)
    var thrower = -2                  // -1 = the user, ≥ 0 = snowman id, -2 = a plain throw
    var floor: Float = -.infinity     // a ball that missed flies on and splats when it falls to this height
    var size: Float = 7.5             // drawn size at the start …
    var endSize: Float = 7.5          // … and at the end (the user's throw shrinks as it flies away from you)
}

struct Icicle {
    var x, len, maxLen, rate, width: Float
}

final class Pile {
    let key: Int
    let kind: SurfaceKind
    var rect: CGRect
    var bins: [Float]
    var visible: [Bool]
    var cap: Float
    var lastMove: Double
    var icicles: [Icicle] = []
    var icicleVisible: [Bool] = []
    var mesh: [Vertex] = []
    var dirty = true
    var iceDirty = true
    var frost: Float = 0             // 0…1, frost creeping in from the window corners
    var occluders: [CGRect] = []     // windows in front of this one (for frost corners)
    var frostSeed: UInt64 = 0
    var limit: [Float] = []          // per-bin drawing limit (the Dock's snow stays a thin ledge under windows)
    var lastSeen: Double = 0         // time of the last sync (for window speed)
    var landIndex = -1               // position in the simulation's `landables` (for `Simulation.Bands`)
    var parkedSince: Double?         // window went away (other Space, hidden) – kept, not drawn
    /// The drift a window had before it went full screen – given back when it returns to that frame.
    var stash: (rect: CGRect, bins: [Float], icicles: [Icicle], frost: Float)?

    init(key: Int, kind: SurfaceKind, rect: CGRect, binW: Float, now: Double) {
        self.key = key
        self.kind = kind
        self.rect = rect
        let n = max(1, Int(Float(rect.width) / binW))
        bins = Array(repeating: 0, count: n)
        visible = Array(repeating: false, count: n)
        cap = 10
        lastMove = now
    }

    func resize(binW: Float) {
        let n = max(1, Int(Float(rect.width) / binW))
        bins = Array(repeating: 0, count: n)
        visible = Array(repeating: false, count: n)
        dirty = true
    }
}

/// Snow simulation for one screen. Coordinates in points, origin at the screen's bottom left.
@MainActor
final class Simulation {
    static let binW: Float = 4
    static let groundKey = -1, dockKey = -2
    static let gravity: Float = 900

    let origin: CGPoint
    let size: CGSize
    private(set) var menuBarHeight: CGFloat
    private(set) var dockBottomGuess: CGFloat   // top edge of a bottom Dock, derived from visibleFrame
    var hostsSnowman: Bool {
        didSet {
            // The Dock moved to another screen: the snowmen and the tree move with it.
            if !hostsSnowman { snowmen = []; treePos = nil }
        }
    }

    private(set) var flakes: [Flake] = []
    private var parkedFlakes: [Flake] = []   // the snowfall in the air, kept while a full-screen app hides it
    private var debris: [Debris] = []
    private var shards: [Shard] = []
    private var snowballs: [Snowball] = []
    private var piles: [Int: Pile] = [:]
    private var landables: [Pile] = []
    private var columns: [[Pile]] = []          // landables bucketed by 32-pt screen column
    private static let columnW: Float = 32
    private var bandStore = Bands()             // reused between frames (see `Bands`)
    private var menuIcicles: [Icicle] = []
    private var menuSnow: [Float] = []
    // Cached geometry. The menu-bar strip changes a few bins at a time; the garland and the tree only
    // change their brightness between frames (see `Christmas.LightCache`).
    private var menuMesh: [Vertex] = []
    private var menuSlot: [Int] = []            // per bin: first vertex of its block in `menuMesh`, -1 = none
    private var menuGrown: [Int] = []           // bins whose powder grew since the last build
    private var menuMeshValid = false
    private var menuBlock: [Vertex] = []        // scratch for one bin's block
    private var menuMeshKey: (bar: CGFloat, occ: [CGRect]) = (-1, [])
    private var garlandCache = Christmas.LightCache()
    private var treeCache = Christmas.LightCache()
    // [1.3 holidays] presents, countdown sign, fireworks (HolidayScene); lights on the frontmost window
    private(set) var holiday = HolidayScene()
    private var windowLightCache = Christmas.LightCache()
    private var holidaySpot: (x: Float, side: Float)?  // where the tree stands (or would): sign and presents
    // [1.3 decor] gingerbread house, candy canes and saplings (ChristmasDecor)
    var decorItems = ChristmasDecor.scatter()         // settable for debug renders (ISNOW_DECOR=canes)
    private var housePos: (x: Float, y: Float)?
    private var houseGhost = false
    private var decorBlocked: [ClosedRange<Float>] = []   // x ranges kept free of candy canes and saplings
    var snowmen: [Snowman] = []
    // [1.3 snowmen] runtime only (not persisted), set by the holidays code.
    var rollKeys = false                      // ⌥⇧ held: roll a snowball instead of shovelling (set by the overlay)
    private var rollHeld: Float = 0
    private var yard = SnowYard()
    var seasonalHat: Snowman.Hat? = nil       // overrides every snowman's wardrobe hat
    var sparklers = false                     // snowmen hold a sparkler (New Year's Eve)
    private var windowRects: [(key: Int, rect: CGRect)] = []   // front to back
    private var dockLocal: CGRect?
    private var treePos: (x: Float, y: Float)?
    private var noIcicles: CGRect?          // the Dock (plus a margin): icicles never hang into it
    private var dockGuessed = false         // the Dock's frame is only estimated (no Accessibility)
    /// The Dock auto-hides: `dockLocal` follows it live as it slides in and out (nil while hidden).
    private var dockTransient = false
    /// Where an auto-hiding Dock stands when it is fully shown (remembered while it is hidden).
    private var dockRest: CGRect?
    /// The Dock that the tree, the decorations and the snowmen line up with. An auto-hiding Dock comes and
    /// goes: they keep to the ground beside the place where it shows up.
    private var layoutDock: CGRect? { dockTransient ? dockRest : dockLocal }
    private var lastDockTop: Float = -1000    // the auto-hiding Dock's top at the last sync (rising = coming up)
    private var avoidLocal: CGRect?         // area around the Dock kept free of other snow
    private var treeGhost = false
    private var treeHidden = false            // under a menu or popover
    private var treeSnow: Float = 0           // [1.3 tree] snow on the branches, 0…1 in quarter steps
    private var localOcc: [CGRect] = []       // menus, popovers, notifications (local coordinates)
    private var keepVanishedUntil: Double = 0 // after a Space switch, vanished windows keep their snow
    private var activeRect: CGRect?           // the frontmost window (snow is calmer over it)
    private var mouseLocal: SIMD2<Float>?
    private var shovelHeld: Float = 0         // how long ⌥ has been held
    private var santa: Christmas.Sleigh?
    private var plow = Snowplow()
    private var nextAutoPlow: Double = 2       // seconds until the next look at the snow height
    private var nextSanta: Double = 45
    private var skiers: [Skier] = []
    private var queuedSkiers: [Double] = []   // delays before the next skiers of a group set off
    private var nextSkier: Double = -1        // set from the settings on the first frame
    /// When any screen last had a skier (only one skis at a time, across all screens).
    private static var skierSeen: Double = -10
    /// Short status for the menu ("Paused: full-screen app").
    var isFullscreenPaused: Bool { fullscreen }

    private var time: Double = 0
    private var spawnAcc: Double = 0
    private var wind: Float = 0
    // [1.3 weather] the living weather's steady wind and gusts (smoothed) and powder blown off drift crests
    private var weatherWind: Float = 0
    private var blownPowder: [Debris] = []
    private var meshTimer: Double = 0
    private var cfg = SimConfig()
    private var fullscreen = false
    private var lastMouse: SIMD2<Float>?
    private var shovelAt: SIMD2<Float>?        // cursor position while the ⌥ shovel is active
    private var kickedUntil: Double = 0        // the cursor scattered flakes – they fly fast until then
    /// True when a window moved during the last sync (the app then polls faster).
    private(set) var windowMoving = false
    /// [1.3 welcome] Set when a window with a drift moved / the ⌥ shovel moved snow; the app
    /// ticks the welcome window's Things to Try and clears them.
    var snowyWindowMoved = false
    var shoveled = false
    private var tint: (Float, Float, Float) = (1, 1, 1)

    /// Height of the camera housing (notch) – full-screen windows end below it.
    private(set) var safeTop: CGFloat

    init(screenFrame: CGRect, visibleFrame: CGRect, hostsSnowman: Bool, safeTop: CGFloat = 0) {
        origin = screenFrame.origin
        size = screenFrame.size
        self.safeTop = safeTop
        menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        dockBottomGuess = max(0, visibleFrame.minY - screenFrame.minY)
        self.hostsSnowman = hostsSnowman
        let n = Int(Float(size.width) / Self.binW)
        menuSnow = Array(repeating: 0, count: n)
    }

    /// Menu bar auto-hide, Dock size and the notch can change without a new screen configuration.
    func updateMetrics(screenFrame: CGRect, visibleFrame: CGRect, safeTop: CGFloat) {
        menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        dockBottomGuess = max(0, visibleFrame.minY - screenFrame.minY)
        self.safeTop = safeTop
    }

    /// Called on a Space switch: windows that vanish now are on another Space, keep their snow.
    func noteSpaceChange(now: Double) { keepVanishedUntil = now + 1.5 }

    var W: Float { Float(size.width) }
    var H: Float { Float(size.height) }

    // MARK: - Syncing with the environment

    /// Returns true when something changed and a redraw is needed.
    @discardableResult
    func sync(windows: [TrackedWindow], occluders: [CGRect], dock: CGRect?, icons: [CGRect],
              widgets: [TrackedWindow] = [], dockEstimated: Bool = false, dockAvoid: CGRect? = nil,
              dockAutoHides: Bool = false,
              menuBars: [CGRect]? = nil, activeWindow: CGRect? = nil, now: Double, cfg: SimConfig) -> Bool {
        let tintChanged = cfg.tint != self.cfg.tint
        let capsChanged = cfg.windowDepth != self.cfg.windowDepth || cfg.groundDepth != self.cfg.groundDepth
            || cfg.unlimitedDrifts != self.cfg.unlimitedDrifts
        self.cfg = cfg
        tint = (Float(cfg.tint[safe: 0] ?? 1), Float(cfg.tint[safe: 1] ?? 1), Float(cfg.tint[safe: 2] ?? 1))
        var changed = tintChanged || capsChanged
        let bounds = CGRect(origin: .zero, size: size)
        let wasFull = fullscreen
        // Full screen: a window covers the whole screen – or, on a Mac with a notch, everything below
        // the notch while the menu bar is hidden (a zoomed window keeps the menu bar visible).
        let screenGlobal = CGRect(origin: origin, size: size)
        let menuVisible = menuBars.map { bars in
            bars.contains { $0.intersects(screenGlobal) && $0.maxY >= screenGlobal.maxY - 2 && $0.minY > screenGlobal.maxY - 90 }
        } ?? true
        let topGap = max(safeTop, menuBarHeight) + 1
        // Windows that reach from the bottom edge to the top (or to the notch while the menu bar is
        // hidden). One of them spanning the width is full screen; several side by side are Split View.
        var spans: [(CGFloat, CGFloat)] = []
        for w in windows {
            let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            guard r.minY <= 1, r.maxY >= size.height - 1 || (!menuVisible && r.maxY >= size.height - topGap),
                  r.maxX > 0, r.minX < size.width else { continue }
            spans.append((max(0, r.minX), min(size.width, r.maxX)))
        }
        spans.sort { $0.0 < $1.0 }
        var reach: CGFloat = 0
        for sp in spans where sp.0 <= reach + 12 { reach = max(reach, sp.1) }   // Split View has a small gap
        fullscreen = cfg.pauseFullscreen && !spans.isEmpty && reach >= size.width - 1
            && (spans.count == 1 || !menuVisible)
        if fullscreen != wasFull {
            changed = true
            if fullscreen && cfg.fullscreenSnow < 0.02 {
                // Clear the air at once so nothing drifts over a video or presentation – but keep the flakes
                // aside, so back on the desktop the snowfall carries on mid-air instead of starting at the top.
                parkedFlakes = flakes
                flakes.removeAll(keepingCapacity: true)
                debris.removeAll(keepingCapacity: true)
                snowballs.removeAll()
                shards.removeAll()
            }
        }
        if !fullscreen && wasFull && !parkedFlakes.isEmpty {
            let room = max(0, Int(cfg.maxFlakes) - flakes.count)
            flakes.append(contentsOf: parkedFlakes.prefix(room))
            parkedFlakes = []
        }
        windowMoving = false
        var seen = Set<Int>()
        var order: [Pile] = []
        let localOcc = occluders.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        self.localOcc = localOcc
        activeRect = activeWindow.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }

        func upsert(key: Int, kind: SurfaceKind, rect r: CGRect) -> Pile {
            seen.insert(key)
            if let p = piles[key] {
                if p.parkedSince != nil {
                    // Back from another Space: keep the snow if the window didn't move meanwhile.
                    p.parkedSince = nil
                    if p.rect != r { p.rect = r; p.resize(binW: Self.binW); p.icicles = []; p.icicleVisible = []; p.frost = 0 }
                    p.lastSeen = now
                    p.dirty = true
                    changed = true
                    return p
                }
                let dx = Float(r.minX - p.rect.minX), dy = Float(r.minY - p.rect.minY)
                let resized = abs(p.rect.width - r.width) > 0.5 || abs(p.rect.height - r.height) > 0.5
                if p.kind == .window, abs(dx) > 0.5 || abs(dy) > 0.5 || resized {
                    if let st = p.stash, abs(st.rect.minX - r.minX) < 2, abs(st.rect.minY - r.minY) < 2,
                       abs(st.rect.width - r.width) < 2, abs(st.rect.height - r.height) < 2 {
                        // Back from full screen: the window gets its old drift and icicles back.
                        p.rect = r
                        p.resize(binW: Self.binW)
                        if st.bins.count == p.bins.count { p.bins = st.bins }
                        p.icicles = st.icicles
                        p.icicleVisible = Array(repeating: false, count: st.icicles.count)
                        p.frost = st.frost
                        p.stash = nil
                        p.lastSeen = now
                        p.dirty = true
                        p.iceDirty = true
                        changed = true
                        return p
                    }
                    if isScreenSized(r) {
                        // Going full screen: keep the drift aside instead of dropping it.
                        if p.stash == nil { p.stash = (p.rect, p.bins, p.icicles, p.frost) }
                        p.rect = r
                        p.resize(binW: Self.binW)
                        p.icicles = []
                        p.icicleVisible = []
                        p.frost = 0
                        p.lastSeen = now
                        p.dirty = true
                        p.iceDirty = true
                        changed = true
                        return p
                    }
                }
                if p.kind == .dock, dockTransient, !resized, dy > 0.5 {
                    // An auto-hiding Dock sliding up carries its snow along (sliding down, it drops it below).
                    p.rect = r
                    p.lastSeen = now
                    p.dirty = true
                    changed = true
                    return p
                }
                if abs(dx) > 0.5 || abs(dy) > 0.5 || resized {
                    let dt = Float(max(1.0 / 60, min(0.5, now - p.lastSeen)))
                    let vel = SIMD2(dx / dt, dy / dt)
                    let dist = (dx * dx + dy * dy).squareRoot()
                    if p.kind == .window && !resized && (p.bins.max() ?? 0) > 3 { snowyWindowMoved = true }   // [1.3 welcome]
                    if !resized && dist < 4 && p.kind == .window {
                        // A nudge: the drift rides along, only the loose top layer shakes off.
                        p.rect = r
                        shed(p, vel: vel, fraction: min(0.35, dist / 12))
                    } else {
                        // Pulled away: the whole drift slides off where the window was.
                        dump(p, vel: vel)
                        p.rect = r
                        if resized { p.resize(binW: Self.binW) }
                    }
                    p.lastMove = now
                    windowMoving = true
                    changed = true
                }
                p.lastSeen = now
                return p
            }
            let p = Pile(key: key, kind: kind, rect: r, binW: Self.binW, now: now)
            p.cap = capFor(p)
            p.lastSeen = now
            piles[key] = p
            changed = true
            return p
        }

        dockGuessed = dockEstimated
        dockTransient = dockAutoHides
        // An estimated Dock may be wider than we think – keep a generous margin around it.
        let dockMargin: CGFloat = dockEstimated ? 30 : 6
        let avoid = (dockAvoid ?? dock)?.offsetBy(dx: -origin.x, dy: -origin.y)
        noIcicles = avoid?.insetBy(dx: -dockMargin, dy: -10)
        avoidLocal = avoid
        // Windows (front to back); a window is occluded by the windows in front of it.
        var front: [CGRect] = localOcc
        var rects: [(key: Int, rect: CGRect)] = []
        for w in windows {
            let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            guard r.intersects(bounds) else { continue }
            if cfg.onWindows {
                let p = upsert(key: w.id, kind: .window, rect: r)
                if p.frostSeed == 0 { p.frostSeed = UInt64(truncatingIfNeeded: w.id) &* 0x9E37_79B9_7F4A_7C15 | 1 }
                if updateVisibility(p, occluders: front) { changed = true }
                if updateLimit(p, windows: Array(front.dropFirst(localOcc.count))) { changed = true }
                p.occluders = front
                order.append(p)
            }
            front.append(r)
            rects.append((w.id, r))
        }
        windowRects = rects
        // Dock – its drift reaches above the Dock, so windows hide it (e.g. a zoomed window).
        dockLocal = nil
        if !dockTransient { dockRest = nil }
        if let d = dock?.offsetBy(dx: -origin.x, dy: -origin.y), d.intersects(bounds), d.maxY > 6 {
            dockLocal = d
            if dockTransient, d.minY >= 0, d.minY < size.height / 2 { dockRest = d }
            if cfg.onDock {
                // Snow lies right on the Dock's top edge. Where a window sits above the Dock it stays a
                // thin ledge, so it never covers the window (or the icons below).
                let appears = piles[Self.dockKey] == nil
                let p = upsert(key: Self.dockKey, kind: .dock, rect: d)
                if updateVisibility(p, occluders: localOcc) { changed = true }
                if updateDockLimit(p, windows: Array(front.dropFirst(localOcc.count)), mouse: mouseLocal) { changed = true }
                // An auto-hiding Dock coming up from below the screen edge pushes the snow lying there up.
                if appears && dockTransient && d.minY < -1 { liftGround(onto: p); changed = true }
                order.append(p)
            }
        }
        // An auto-hiding Dock coming up tosses whoever is in its way up onto it, or shoves snowmen aside.
        if dockTransient, hostsSnowman, let d = dockLocal, Float(d.maxY) > lastDockTop + 0.5 { pushedByDock(d) }
        lastDockTop = dockLocal.map { Float($0.maxY) } ?? -1000
        // Desktop icons – they sit below all windows.
        if cfg.onIcons {
            for f in icons {
                let r = f.offsetBy(dx: -origin.x, dy: -origin.y)
                guard bounds.contains(r) else { continue }
                let key = (1 << 40) + Int(r.minX / 4) * 8192 + Int(r.minY / 4)
                let p = upsert(key: key, kind: .icon, rect: r)
                if updateVisibility(p, occluders: front) { changed = true }
                if updateLimit(p, windows: Array(front.dropFirst(localOcc.count))) { changed = true }
                order.append(p)
            }
        }
        // Desktop widgets – like icons, they sit below all windows.
        if cfg.onWidgets {
            for w in widgets {
                let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                guard bounds.contains(r) else { continue }
                let p = upsert(key: (1 << 41) + w.id, kind: .widget, rect: r)
                if updateVisibility(p, occluders: front) { changed = true }
                if updateLimit(p, windows: Array(front.dropFirst(localOcc.count))) { changed = true }
                order.append(p)
            }
        }
        // Bottom edge of the screen
        let g = upsert(key: Self.groundKey, kind: .ground, rect: CGRect(x: 0, y: -1, width: size.width, height: 1))
        if updateGroundVisibility(g, dock: avoidLocal ?? dockLocal, margin: dockEstimated ? 30 : 4, windows: front) { changed = true }
        if updateLimit(g, windows: Array(front.dropFirst(localOcc.count))) { changed = true }
        order.append(g)

        // Several windows vanishing at once (or anything vanishing around full screen) means a Space
        // switch, not closing: keep the snow. A single window that disappears was closed or minimized.
        let vanishedWindows = piles.filter { !seen.contains($0.key) && $0.value.parkedSince == nil && $0.value.kind == .window }.count
        let spaceSwitch = now < keepVanishedUntil || fullscreen || wasFull || vanishedWindows >= 2
        for (k, p) in piles where !seen.contains(k) {
            if let since = p.parkedSince {
                // Gone for good after 4 hours on another Space.
                if now - since > 4 * 3600 { piles[k] = nil }
                continue
            }
            if spaceSwitch {
                p.parkedSince = now          // switched Space: keep the snow for when it comes back
            } else {
                shake(p, push: 0)            // closed, minimized or hidden: the snow falls
                piles[k] = nil
            }
            changed = true
        }
        landables = order
        rebuildColumns()
        for p in order {
            // Caps depend on where the surface is (an unlimited drift may grow up to the screen top).
            let cap = capFor(p)
            if cap != p.cap || capsChanged || tintChanged {
                p.cap = cap
                p.dirty = true
                if p.bins.contains(where: { $0 > cap }) { p.bins = p.bins.map { min($0, cap) } }
            }
        }
        if hostsSnowman { syncSnowmen(); syncTree() }
        if hostsSnowman { syncDecor() }                   // [1.3 decor]
        if syncHolidays() { changed = true }              // [1.3 holidays] the sign changed
        return changed
    }

    /// A window as big as the screen (below the notch / menu bar is enough) – i.e. full screen.
    private func isScreenSized(_ r: CGRect) -> Bool {
        r.minX <= 1 && r.minY <= 1 && r.maxX >= size.width - 1
            && r.maxY >= size.height - max(safeTop, menuBarHeight) - 2
    }

    /// How much longer icicles get in the cold: 1× at 0 °C, 2× at −7 °C, ~3× in hard frost.
    private var coldFactor: Float {
        cfg.temperature < 0 ? 1 + min(2.2, Float(-cfg.temperature) / 7) : 1
    }

    /// Long icicles are also thicker at the root.
    private func iceWidth(_ len: Float) -> Float { 1 + min(1.2, max(0, len - 20) / 40) }

    private func capFor(_ p: Pile) -> Float {
        let roof = max(0, H - Float(menuBarHeight) - Float(p.rect.maxY) - 2)   // room up to the menu bar
        if cfg.unlimitedDrifts {
            switch p.kind {
            case .window, .widget: return roof
            case .dock: return min(roof, 70)
            case .ground: return max(0, roof - 30)
            case .icon: return min(Float(cfg.windowDepth) * 0.4, 22)
            }
        }
        let w = Float(cfg.windowDepth)
        switch p.kind {
        case .window: return w
        case .dock: return min(w * 0.55, 34)
        case .icon: return min(w * 0.4, 22)
        case .widget: return w * 0.7
        case .ground: return Float(cfg.groundDepth)
        }
    }

    /// Height of the drift on surface `key` at x (0 if none).
    private func driftHeight(_ key: Int, at x: Float) -> Float {
        guard let p = piles[key] else { return 0 }
        let b = Int((x - Float(p.rect.minX)) / Self.binW)
        guard b >= 0, b < p.bins.count else { return 0 }
        // Average a few bins so a snowman doesn't jitter on a bumpy drift.
        var sum: Float = 0, n: Float = 0
        for k in max(0, b - 2)...min(p.bins.count - 1, b + 2) {
            sum += min(p.bins[k], k < p.limit.count ? p.limit[k] : .infinity); n += 1
        }
        return sum / n
    }

    private func updateVisibility(_ p: Pile, occluders: [CGRect]) -> Bool {
        let n = p.bins.count
        let top = p.rect.maxY
        let margin: Int = switch p.kind {
        case .window: 4
        case .widget: 5          // widgets have large rounded corners
        case .dock: 3
        default: 1
        }
        let topLimit = size.height - menuBarHeight - 1
        var changed = false
        for i in 0..<n {
            let x = p.rect.minX + (CGFloat(i) + 0.5) * CGFloat(Self.binW)
            var v = i >= margin && i < n - margin && x >= 0 && x <= size.width && top < topLimit
            if v {
                for o in occluders where x >= o.minX && x <= o.maxX
                    && ((top + 3 >= o.minY && top + 3 <= o.maxY) || (top - 3 >= o.minY && top - 3 <= o.maxY)) {
                    v = false
                    break
                }
            }
            if p.visible[i] != v { p.visible[i] = v; changed = true }
        }
        // Icicles – the window's bottom edge
        if p.kind == .window {
            if p.icicleVisible.count != p.icicles.count { p.icicleVisible = Array(repeating: false, count: p.icicles.count) }
            let bottom = p.rect.minY
            for (k, ic) in p.icicles.enumerated() {
                let x = p.rect.minX + CGFloat(ic.x)
                var v = bottom > 40 && x >= 0 && x <= size.width
                if let d = noIcicles, x >= d.minX, x <= d.maxX, bottom <= d.maxY + 30 { v = false }
                if v {
                    for o in occluders where x >= o.minX && x <= o.maxX
                        && ((bottom - 3 >= o.minY && bottom - 3 <= o.maxY) || (bottom + 3 >= o.minY && bottom + 3 <= o.maxY)) {
                        v = false
                        break
                    }
                }
                if p.icicleVisible[k] != v { p.icicleVisible[k] = v; p.iceDirty = true; changed = true }
            }
        }
        if changed { p.dirty = true }
        return changed
    }

    /// Snow never grows into a window in front of it: each column is limited by the lowest window
    /// above the surface (so the bottom drift and tall hills stay out of windows).
    private func updateLimit(_ p: Pile, windows: [CGRect]) -> Bool {
        if p.limit.count != p.bins.count { p.limit = Array(repeating: .infinity, count: p.bins.count) }
        let top = p.rect.maxY
        var changed = false
        for i in p.bins.indices {
            let x = p.rect.minX + (CGFloat(i) + 0.5) * CGFloat(Self.binW)
            var l = Float.infinity
            for w in windows where x >= w.minX && x <= w.maxX && w.minY > top + 1 {
                l = min(l, Float(w.minY - top) - 1)
            }
            if p.limit[i] != l { p.limit[i] = l; changed = true }
        }
        if changed { p.dirty = true }
        return changed
    }

    /// The Dock's snow: a thin ledge under a window that sits on the Dock.
    private func updateDockLimit(_ p: Pile, windows: [CGRect], mouse: SIMD2<Float>?) -> Bool {
        if p.limit.count != p.bins.count { p.limit = Array(repeating: .infinity, count: p.bins.count) }
        let top = p.rect.maxY
        var changed = false
        for i in p.bins.indices {
            let x = p.rect.minX + (CGFloat(i) + 0.5) * CGFloat(Self.binW)
            var l = Float.infinity
            for w in windows where x >= w.minX && x <= w.maxX {
                if top + 4 >= w.minY && top + 4 <= w.maxY { l = 4; break }
                if w.minY > top + 1 { l = min(l, Float(w.minY - top) - 1) }
            }
            if p.limit[i] != l { p.limit[i] = l; changed = true }
        }
        if changed { p.dirty = true }
        return changed
    }

    private func updateGroundVisibility(_ p: Pile, dock: CGRect?, margin: CGFloat, windows: [CGRect]) -> Bool {
        var changed = false
        for i in 0..<p.bins.count {
            let x = (CGFloat(i) + 0.5) * CGFloat(Self.binW)
            var v = true
            // Never in front of the Dock's icons.
            if let d = dock, d.minY < 12, x >= d.minX - margin, x <= d.maxX + margin { v = false }
            if v { for w in windows where x >= w.minX && x <= w.maxX && w.minY <= 4 { v = false; break } }
            if p.visible[i] != v { p.visible[i] = v; changed = true }
        }
        if changed { p.dirty = true }
        return changed
    }

    // MARK: - Simulation step

    func step(dt: Double, now: Double, mouse: CGPoint? = nil, shovel: Bool = false) {
        time += dt
        let fdt = Float(dt)
        mouseLocal = mouse.map { SIMD2(Float($0.x), Float($0.y)) }
        // ⌥ only becomes a shovel after a short hold, so typing ⌥-characters doesn't shovel.
        shovelHeld = shovel && !rollKeys ? shovelHeld + fdt : 0
        rollHeld = rollKeys ? rollHeld + fdt : 0          // [1.3 snowmen]
        wind = Float(cfg.wind) * Float(sin(time * 0.071) * 16 + sin(time * 0.23) * 6 + sin(time * 0.017) * 12)
        stepWeather(dt: fdt)                    // [1.3 weather] adds the steady wind and gusts to `wind`

        if !cfg.paused && (!fullscreen || cfg.fullscreenSnow >= 0.02) {
            spawnAcc += 28 * cfg.density * Double(size.width) / 1000 * dt
            let maxF = Int(cfg.maxFlakes)
            while spawnAcc >= 1 {
                spawnAcc -= 1
                if flakes.count < maxF { spawnFlake() }
            }
        }
        shovelAt = nil
        if cfg.mouse, let mouse {
            let m = SIMD2(Float(mouse.x), Float(mouse.y))
            if shovelHeld > 0.25 {
                shovelAt = m                 // the shovel follows the cursor while ⌥ is held
                // [1.3 snowmen] over a snowman ⌥ means aiming a snowball, not digging
                if !aiming(at: m) { stepShovel(m, dt: fdt) }
            }
            stepMouse(m, dt: fdt)
        } else { lastMouse = nil }
        let acc = Float(cfg.accumulation)
        let temp = Float(cfg.temperature)
        let sleet = temp > 4          // too warm: wet flakes melt on contact

        // Flakes (compacted in place; the invariants are hoisted out of the loop – it runs for thousands)
        let menuLine = H - Float(menuBarHeight)
        let onMenuBar = cfg.onMenuBar, landing = !sleet && !fullscreen
        let w = W, depositAmount = 0.35 * acc, menuBins = menuSnow.count
        let drift = wind
        var kept = 0
        var bands = Bands()
        swap(&bands, &bandStore)
        if landing && !flakes.isEmpty { bands.build(landables, columns: columns) }
        let columnCount = landing ? columns.count : 0
        flakes.withUnsafeMutableBufferPointer { buf in
            for k in 0..<buf.count {
                var f = buf[k]
                let oy = f.y
                f.phase += f.freq * fdt
                f.x += (drift * (0.35 + f.depth) + sin(f.phase) * f.amp + f.vx) * fdt
                f.y -= f.vy * fdt
                if f.vx != 0 { f.vx *= max(0, 1 - 2.5 * fdt); if abs(f.vx) < 1 { f.vx = 0 } }
                // Only a flake that crosses the height of some drift top in its column can land.
                if f.depth > 0.3, landing, case let c = Int(f.x / Self.columnW), c >= 0, c < columnCount,
                   bands.crosses(column: c, from: oy, to: f.y),
                   let (p, b) = hit(x: f.x, oldY: oy, newY: f.y) {
                    deposit(p, b, depositAmount * (0.6 + f.depth))
                    bands.refresh(p, around: b, columns: columns)
                    continue
                }
                if onMenuBar, f.depth > 0.6, oy > menuLine, f.y <= menuLine {
                    // Powder snow along the bottom edge of the menu bar
                    let b = Int(f.x / Self.binW)
                    if b >= 0 && b < menuBins && menuSnow[b] < 2.2 {
                        menuSnow[b] += 0.12
                        if menuGrown.count < 256 { menuGrown.append(b) } else { menuMeshValid = false }
                    }
                }
                if f.y < -10 { continue }
                if f.x < -30 { f.x += w + 60 } else if f.x > w + 30 { f.x -= w + 60 }
                buf[kept] = f
                kept += 1
            }
        }
        if kept < flakes.count { flakes.removeLast(flakes.count - kept) }
        swap(&bands, &bandStore)

        // Falling snow chunks
        var i = 0
        while i < debris.count {
            var d = debris[i]
            let oy = d.y
            d.vy -= Self.gravity * fdt
            d.vx *= (1 - 0.8 * fdt)
            d.x += d.vx * fdt
            d.y += d.vy * fdt
            if d.lands, d.vy < 0, !fullscreen, let (p, b) = hit(x: d.x, oldY: oy, newY: d.y) {
                deposit(p, b, d.size * 0.5)
                if d.vy < -220 && d.size > 4 && debris.count < 9000 {
                    // Impact: the clump bursts into powder.
                    for _ in 0..<Int(min(4, d.size / 3)) {
                        debris.append(Debris(x: d.x, y: Float(p.rect.maxY) + p.bins[b], vx: d.vx * 0.3 + Float.random(in: -80...80),
                                             vy: Float.random(in: 40...140), size: Float.random(in: 1.4...3), alpha: 0.8,
                                             lands: false, fade: 1.4))
                    }
                }
                debris.swapAt(i, debris.count - 1); debris.removeLast(); continue
            }
            if d.y < -20 || d.alpha <= 0 { debris.swapAt(i, debris.count - 1); debris.removeLast(); continue }
            if !d.lands { d.alpha -= fdt * d.fade }
            debris[i] = d
            i += 1
        }

        // Broken-off icicles
        i = 0
        while i < shards.count {
            shards[i].vy -= Self.gravity * fdt
            shards[i].y += shards[i].vy * fdt
            if shards[i].y + shards[i].len < -10 { shards.swapAt(i, shards.count - 1); shards.removeLast() } else { i += 1 }
        }

        // Snowballs
        i = 0
        while i < snowballs.count {
            var s = snowballs[i]
            s.t += fdt
            s.vy -= 600 * fdt
            s.x += s.vx * fdt
            s.y += s.vy * fdt
            if s.t >= s.duration || (s.y <= s.floor && s.vy < 0) {
                // [1.3 snowmen] aimed at a snowman that ducked: it flies on
                if s.victim >= 0 && !snowballLands(&s) { snowballs[i] = s; i += 1; continue }
                splat(s)
                snowballs.swapAt(i, snowballs.count - 1); snowballs.removeLast(); continue
            }
            snowballs[i] = s
            i += 1
        }

        // Icicles grow under windows that stay still for a while
        meshTimer += dt
        let growTick = meshTimer > 0.25
        if growTick {
            let tick = Float(meshTimer)
            meshTimer = 0
            let temp = Float(cfg.temperature)
            // Snow always settles and evaporates a little (slowly in frost), and melts fast above zero.
            // Deep snow also compacts, so drifts level off instead of growing forever.
            let base = cfg.meltBase / 60 * tick
            if base > 0 {
                for p in landables {
                    var any = false
                    for k in p.bins.indices where p.bins[k] > 0 { p.bins[k] = max(0, p.bins[k] - base); any = true }
                    if any { p.dirty = true }
                }
                for k in menuSnow.indices where menuSnow[k] > 0 { menuSnow[k] = max(0, menuSnow[k] - base * 0.2); menuMeshValid = false }
            }
            // Frost on windows: grows on still windows when it is below zero, thaws above.
            let frostTarget: Float = cfg.windowFrost && temp < 0 ? min(1, -temp / 15) : 0
            for p in landables where p.kind == .window {
                var f = p.frost
                if f > frostTarget { f = max(frostTarget, f - tick / 25) }
                else if now - p.lastMove > 4 { f = min(frostTarget, f + tick / 70 * (0.5 + frostTarget)) }
                if abs(f - p.frost) > 0.0005 { p.frost = f; p.dirty = true }
            }
            for p in landables where p.kind == .window {
                guard cfg.icicles else {
                    if !p.icicles.isEmpty { p.icicles = []; p.icicleVisible = []; p.iceDirty = true }
                    continue
                }
                if temp > 0 {
                    // Thaw: icicles shrink and eventually disappear (visibility kept in step).
                    if !p.icicles.isEmpty {
                        for k in p.icicles.indices { p.icicles[k].len -= temp * 0.12 * tick }
                        for k in p.icicles.indices.reversed() where p.icicles[k].len <= 0.3 {
                            p.icicles.remove(at: k)
                            if k < p.icicleVisible.count { p.icicleVisible.remove(at: k) }
                        }
                        p.iceDirty = true
                    }
                    continue
                }
                guard now - p.lastMove > 12, p.rect.minY > 40 else { continue }
                if p.icicles.isEmpty {
                    let w = Float(p.rect.width)
                    // The colder it is, the more icicles form.
                    let count = max(2, min(18, Int(w / 110 * (0.6 + 0.4 * coldFactor))))
                    p.icicles = (0..<count).map { _ in
                        let maxLen = Float.random(in: 7...30)        // × icicle length × cold, applied when growing
                        return Icicle(x: Float.random(in: 16...max(17, w - 16)), len: 0, maxLen: maxLen,
                                      rate: maxLen / Float.random(in: 50...160), width: Float.random(in: 3.5...6))
                    }
                    p.icicleVisible = Array(repeating: false, count: count)
                    p.dirty = true          // visibility is computed on the next sync
                }
                // Hard frost: icicles grow faster and up to ~3× longer.
                let coldBoost = 1 + min(2, -temp / 8)
                let target = coldFactor * Float(cfg.icicleLength)
                for k in p.icicles.indices {
                    let goal = p.icicles[k].maxLen * target
                    if p.icicles[k].len < goal {
                        p.icicles[k].len = min(goal, p.icicles[k].len + p.icicles[k].rate * coldBoost * target * tick)
                        p.iceDirty = true
                    } else if p.icicles[k].len > goal + 0.5 {
                        p.icicles[k].len = goal              // the length slider was lowered
                        p.iceDirty = true
                    }
                }
            }
            if cfg.onMenuBar && cfg.icicles && menuBarHeight > 0 {
                if menuIcicles.isEmpty {
                    menuMeshValid = false
                    let count = max(4, Int(W / 140))
                    menuIcicles = (0..<count).map { _ in
                        let m = Float.random(in: 5...18)
                        return Icicle(x: Float.random(in: 10...(W - 10)), len: 0, maxLen: m,
                                      rate: m / Float.random(in: 90...240), width: Float.random(in: 3...5))
                    }
                }
                if temp > 0 {
                    for k in menuIcicles.indices where menuIcicles[k].len > 0 {
                        menuIcicles[k].len = max(0, menuIcicles[k].len - temp * 0.12 * tick)
                        menuMeshValid = false
                    }
                } else {
                    let target = coldFactor * Float(cfg.icicleLength)
                    for k in menuIcicles.indices {
                        let goal = menuIcicles[k].maxLen * target
                        if menuIcicles[k].len < goal {
                            menuIcicles[k].len = min(goal, menuIcicles[k].len + menuIcicles[k].rate * target * tick)
                            menuMeshValid = false
                        } else if menuIcicles[k].len > goal + 0.5 {
                            menuIcicles[k].len = goal
                            menuMeshValid = false
                        }
                    }
                }
            } else if !menuIcicles.isEmpty {
                menuIcicles = []
                menuMeshValid = false
            }
            if !cfg.onMenuBar || menuBarHeight == 0, menuSnow.contains(where: { $0 > 0 }) {
                for k in menuSnow.indices { menuSnow[k] = 0 }
                menuMeshValid = false
            }
        }

        if hostsSnowman { stepSnowmen(dt: fdt); stepSanta(dt: fdt) }
        stepHolidays(fdt)                                  // [1.3 holidays]
        stepYard(dt: fdt)                       // [1.3 snowmen]
        if hostsSnowman && cfg.snowplow && !cfg.paused && !fullscreen {
            // Every couple of seconds: is the snow at the bottom high enough to call the plow?
            nextAutoPlow -= dt
            if nextAutoPlow <= 0 {
                nextAutoPlow = 2
                if !plow.visible && groundNeedsPlowing { plow.startAutopilot(leftToRight: Bool.random(), screenWidth: W) }
            }
        }
        if plow.visible || plow.input != 0 {
            plow.step(dt: fdt, screenWidth: W, ground: piles[Self.groundKey], binW: Self.binW, debris: &debris,
                      dock: dockLocal, dockPile: piles[Self.dockKey])
        }
        stepSkier(dt: dt)
        stepPenguins(dt: dt)            // [1.3 penguin]
        stepReindeer(dt: dt)            // [1.3 reindeer]
    }

    // MARK: - Skier

    private var skierElsewhere: Bool { skiers.isEmpty && CACurrentMediaTime() - Self.skierSeen < 0.5 }

    private func skierInterval() -> Double { max(0.5, cfg.skierInterval) * 60 * Double.random(in: 0.8...1.2) }

    /// Send a group of skiers down the tallest hill on a window right now: the first sets off at once,
    /// the others follow one after another. Returns false if there is no hill (or skiers are already out).
    func sendSkier() -> Bool {
        guard !fullscreen, skiers.isEmpty, !skierElsewhere, startSkier() else { return false }
        queueFollowers()
        nextSkier = skierInterval()
        return true
    }

    private func queueFollowers() {
        let extra = max(0, Int(cfg.skierCount.rounded()) - 1)
        var delay = 0.0
        queuedSkiers = (0..<extra).map { _ in delay += Double.random(in: 1.0...2.8); return delay }
    }

    private var skierDir: Float = 1          // the whole group rides the same way

    /// Skiers ride along the snow at the bottom of the screen, from one edge to the other.
    private func startSkier() -> Bool {
        guard let ground = piles[Self.groundKey] else { return false }
        if skiers.isEmpty && queuedSkiers.isEmpty { skierDir = Bool.random() ? 1 : -1 }
        let s = Skier.alongBottom(ground, dir: skierDir, width: W)
        skiers.append(s)
        // A little puff of powder where the skier pops up.
        for _ in 0..<8 where debris.count < 9000 {
            debris.append(Debris(x: s.x + Float.random(in: -7...7), y: s.y + Float.random(in: 0...4),
                                 vx: Float.random(in: -40...40), vy: Float.random(in: 20...70),
                                 size: Float.random(in: 1.2...2.4), alpha: 0.8, lands: false, fade: 1.5))
        }
        Self.skierSeen = CACurrentMediaTime()
        return true
    }

    private func stepSkier(dt: Double) {
        if cfg.skier && !cfg.paused && !fullscreen && skiers.isEmpty && queuedSkiers.isEmpty {
            if nextSkier < 0 { nextSkier = min(skierInterval(), 45) }     // the first group comes soon
            nextSkier -= dt
            if nextSkier <= 0 {
                // No hill (or skiers on another screen): try again a bit later.
                if !skierElsewhere && startSkier() {
                    queueFollowers()
                    nextSkier = skierInterval()
                } else {
                    nextSkier = 30
                }
            }
        }
        if fullscreen { skiers = []; queuedSkiers = []; return }
        // The rest of the group sets off one after another from the same hilltop.
        if !queuedSkiers.isEmpty && !cfg.paused {
            for k in queuedSkiers.indices { queuedSkiers[k] -= dt }
            while let first = queuedSkiers.first, first <= 0 {
                queuedSkiers.removeFirst()
                _ = startSkier()
            }
        }
        guard !skiers.isEmpty else { return }
        Self.skierSeen = CACurrentMediaTime()
        var i = 0
        while i < skiers.count {
            var s = skiers[i]
            let alive = s.step(dt: Float(dt), host: piles[s.pileKey], width: W, debris: &debris) { x, y in
                self.skierFloor(x, y)
            }
            if alive { skiers[i] = s; i += 1 } else { skiers.remove(at: i) }
        }
    }

    /// Top of the snow on the highest surface below (x, y) – where a jumping skier lands.
    private func skierFloor(_ x: Float, _ y: Float) -> (top: Float, pile: Pile?) {
        let s = surfaceBelow(x: x, y: y, liveDock: true)     // visitors use an auto-hiding Dock while it is shown
        return (s.top + driftHeight(s.key, at: x), piles[s.key])
    }

    /// Has the snow at the bottom (or on the Dock) reached the height set for the plow?
    private var groundNeedsPlowing: Bool {
        let limit = Float(cfg.autoPlowHeight)
        func average(_ p: Pile?) -> Float {
            guard let p else { return 0 }
            var sum: Float = 0, n: Float = 0
            for k in p.bins.indices where p.visible[k] { sum += p.bins[k]; n += 1 }
            return n > 0 ? sum / n : 0
        }
        // Both the bottom and the Dock use the height from the settings.
        return average(piles[Self.groundKey]) >= limit || average(piles[Self.dockKey]) >= limit
    }

    /// Send the snowplow across the bottom right now (settings button).
    func sendPlow() {
        guard hostsSnowman, !fullscreen else { return }
        plow.startAutopilot(leftToRight: Bool.random(), screenWidth: W)
    }

    // MARK: - Penguin [1.3 penguin]

    private var penguins: [Penguin] = []
    private var nextPenguin: Double = -1        // set from the settings on the first frame
    private var chickIn: Double?                // a chick follows its parent this many seconds later
    private var penguinDir: Float = 1

    /// Where the penguins are (for debug snapshots).
    var penguinSpots: [String] { penguins.map { "\($0.x) \($0.y) dir \($0.dir) \($0.act)" } }

    private func penguinInterval() -> Double { max(1, cfg.penguinInterval) * 60 * Double.random(in: 0.8...1.2) }

    /// Send a penguin along the bottom right now (settings button). False if one is already out.
    func sendPenguin() -> Bool {
        guard hostsSnowman, !fullscreen, penguins.isEmpty, chickIn == nil, startPenguin(chick: false) else { return false }
        nextPenguin = penguinInterval()
        return true
    }

    /// A penguin waddles in from a screen edge (now and then followed by its chick).
    private func startPenguin(chick: Bool) -> Bool {
        guard piles[Self.groundKey] != nil else { return false }
        if !chick {
            penguinDir = Bool.random() ? 1 : -1
            chickIn = Double.random(in: 0..<1) < 0.2 ? Double.random(in: 1.6...2.4) : nil
        }
        let x: Float = penguinDir > 0 ? -14 : W + 14
        let size = min(1.6, max(0.85, 0.8 + 0.27 * Float(cfg.snowmanSize)))
        var p = Penguin(x: x, y: skierFloor(x, 1).top, dir: penguinDir, chick: chick, size: size)
        p.hat = cfg.christmas && cfg.christmasHats && !chick
        p.scarf = cfg.christmas && (chick || !cfg.christmasHats)
        penguins.append(p)
        return true
    }

    private func stepPenguins(dt: Double) {
        guard hostsSnowman, !fullscreen else { penguins = []; chickIn = nil; return }
        if cfg.penguin && !cfg.paused && penguins.isEmpty && chickIn == nil && cfg.temperature <= 2 {
            if nextPenguin < 0 { nextPenguin = min(penguinInterval(), 120) }     // the first one comes soon
            nextPenguin -= dt
            if nextPenguin <= 0 { nextPenguin = reindeer.isEmpty && startPenguin(chick: false) ? penguinInterval() : 30 }   // [1.3 reindeer] one visitor at a time
        }
        if let c = chickIn {
            chickIn = c - dt
            if c - dt <= 0 { chickIn = nil; if !penguins.isEmpty { _ = startPenguin(chick: true) } }
        }
        guard !penguins.isEmpty else { return }
        let parentX = penguins.first { !$0.chick }?.x
        var i = 0
        while i < penguins.count {
            var p = penguins[i]
            p.leaderX = p.chick ? parentX : nil
            // A snowball flying close by: duck.
            let c = p.center
            if snowballs.contains(where: { abs($0.x - c.x) < 60 && abs($0.y - c.y) < 50 }) { p.duck() }
            // Passing a standing snowman: wave to it – and it waves back.
            if !cfg.paused {
                for k in snowmen.indices where snowmen[k].phase == .standing && !snowmen[k].hidden && !snowmen[k].ghost {
                    let sx = snowmen[k].anchorX
                    guard abs(sx - p.x) < 34 * p.size + snowmen[k].R(0), abs(snowmen[k].baseY - p.y) < 30,
                          p.greet(snowmanAt: sx) else { continue }
                    if snowmen[k].wave <= 0 { snowmen[k].wave = 1.6 }
                }
            }
            let alive = p.step(dt: Float(dt), width: W, mouse: mouseLocal, paused: cfg.paused, debris: &debris) { x, y in
                self.skierFloor(x, y)
            }
            if alive { penguins[i] = p; i += 1 } else { penguins.remove(at: i) }
        }
    }

    // MARK: - Reindeer [1.3 reindeer]

    private var reindeer: [Reindeer] = []
    private var nextReindeer: Double = -1       // set from the settings on the first frame
    private var noseBack: [Int: Double] = [:]   // snowman id → when it finds a new carrot

    /// Where the reindeer are (for debug snapshots).
    var reindeerSpots: [String] { reindeer.map { "\($0.x) \($0.y) dir \($0.dir) \($0.act)" } }

    private func reindeerInterval() -> Double { max(1, cfg.reindeerInterval) * 60 * Double.random(in: 0.8...1.2) }

    /// Send a reindeer along the bottom right now (settings button). False if one is already out.
    func sendReindeer() -> Bool {
        guard hostsSnowman, !fullscreen, reindeer.isEmpty, startReindeer() else { return false }
        nextReindeer = reindeerInterval()
        return true
    }

    private func startReindeer() -> Bool {
        guard piles[Self.groundKey] != nil else { return false }
        let dir: Float = Bool.random() ? 1 : -1
        let x: Float = dir > 0 ? -30 : W + 30
        // As tall at the nose as a snowman's carrot, more or less (it rears up for the rest).
        let size = min(2.6, max(0.9, 1.4 * Float(cfg.snowmanSize)))
        // Rudolph comes more often after dark and on 24–26 December.
        let day = Holidays.info(at: Holidays.now())
        let rudolph: Float = day.giftDays ? 0.6 : (day.hour >= 17 || day.hour < 7) ? 0.4 : 0.2
        reindeer.append(Reindeer(x: x, y: skierFloor(x, 1).top, dir: dir, size: size,
                                 rudolph: Float.random(in: 0..<1) < rudolph))
        return true
    }

    /// The tip of a standing snowman's carrot nose (nil if it has none or is busy).
    private func carrotTip(_ s: Snowman) -> SIMD2<Float>? {
        guard s.phase == .standing, s.hasCarrot, s.levels == 3, !s.hidden, !s.ghost, !s.carried, !s.falling,
              let h = s.ball(2) else { return nil }
        let k = s.sizeScale * s.scale
        return SIMD2(h.x + h.r + 5 * k, h.y - 0.6 * k)
    }

    private func stepReindeer(dt: Double) {
        guard hostsSnowman, !fullscreen else { reindeer = []; return }
        if cfg.christmas && cfg.reindeer && !cfg.paused && reindeer.isEmpty {
            if nextReindeer < 0 { nextReindeer = min(reindeerInterval(), 150) }     // the first one comes soon
            nextReindeer -= dt
            if nextReindeer <= 0 { nextReindeer = penguins.isEmpty && startReindeer() ? reindeerInterval() : 20 }
        }
        // A snowman that lost its nose finds a new carrot after a while.
        for (id, at) in noseBack where time >= at {
            noseBack[id] = nil
            if let k = snowmanIndex(id), snowmen[k].phase == .standing, snowmen[k].levels == 3 {
                snowmen[k].hasCarrot = true
                snowmen[k].wobble = max(snowmen[k].wobble, 0.4)
            }
        }
        guard !reindeer.isEmpty else { return }
        var i = 0
        while i < reindeer.count {
            var r = reindeer[i]
            let c = r.center
            if let b = snowballs.first(where: { abs($0.x - c.x) < 60 && abs($0.y - c.y) < 50 }) { r.bolt(from: b.x) }
            if !cfg.paused {
                if let tg = r.target {
                    // Still there, nose and all?
                    let ok = snowmanIndex(tg.id).flatMap { carrotTip(snowmen[$0]) }
                        .map { abs($0.x - tg.tip.x) < 3 && abs($0.y - tg.tip.y) < 3 } ?? false
                    if !ok { r.dropTarget() }
                } else if r.canAim {
                    for s in snowmen where !r.tried(s.id) {
                        guard let tip = carrotTip(s), abs(s.anchorX - r.x) < 280, abs(s.baseY - r.y) < 90 else { continue }
                        let ground = skierFloor(s.anchorX, s.baseY + 15).top          // the snow the snowman stands on
                        if r.aim(snowman: s.id, tip: tip, ground: ground, floor: { x, y in self.skierFloor(x, y) }) { break }
                    }
                }
            }
            let alive = r.step(dt: Float(dt), width: W, mouse: mouseLocal, paused: cfg.paused, debris: &debris) { x, y in
                self.skierFloor(x, y)
            }
            if let id = r.bit {
                // Crunch: the carrot is gone and the snowman wobbles and waves its arms.
                r.bit = nil
                if let k = snowmanIndex(id), snowmen[k].hasCarrot {
                    snowmen[k].hasCarrot = false
                    snowmen[k].wobble = 1
                    snowmen[k].wave = 1.6
                    noseBack[id] = time + Double.random(in: 40...80)
                }
            }
            if r.act == .reach || r.act == .chew, let k = snowmen.indices.min(by: {
                abs(snowmen[$0].anchorX - r.x) < abs(snowmen[$1].anchorX - r.x) }), abs(snowmen[k].anchorX - r.x) < 90 {
                snowmen[k].lookAt = r.center + SIMD2(0, 14 * r.size)        // the snowman stares at the thief
            }
            if alive { reindeer[i] = r; i += 1 } else { reindeer.remove(at: i) }
        }
    }

    /// True while something fast is on screen and the display link should run at the user's full rate.
    /// Ambient snowfall, faded full-screen snow, twinkling lights, glints, a snowman that just stands
    /// (its eyes following the cursor) and frozen (paused) scenes return false.
    var wantsFullFrameRate: Bool {
        // Particles are drawn in every mode: falling clumps and powder (window drift, splashes, skier and
        // plow spray, Santa's sparkles), snowballs, a window being moved, flakes the cursor just kicked.
        if !debris.isEmpty || !snowballs.isEmpty || windowMoving || time < kickedUntil { return true }
        // Everything else is mesh, which is not drawn over a full-screen app.
        if fullscreen { return false }
        if !shards.isEmpty || !skiers.isEmpty || plow.visible || santa != nil || shovelAt != nil { return true }
        if hostsSnowman && holiday.isAlive { return true }        // [1.3 holidays] fireworks, falling presents
        if hostsSnowman && yard.isMoving { return true }        // [1.3 snowmen] a ball being rolled
        if !queuedSkiers.isEmpty && !cfg.paused { return true }        // the rest of a group about to set off
        if penguins.contains(where: { $0.isMoving }) { return true }  // [1.3 penguin]
        if reindeer.contains(where: { $0.isMoving }) { return true }  // [1.3 reindeer]
        guard hostsSnowman else { return false }
        // A snowman's life cycle is frozen while paused, so only one in your hand or in the air moves then.
        let alive = cfg.snowman && !cfg.paused
        return snowmen.contains { $0.carried || $0.falling || (alive && !$0.hidden && $0.isMoving) }
    }

    /// Does anything still need animating? If not, the display link goes to sleep.
    var isAnimating: Bool {
        if !cfg.paused && !fullscreen { return true }
        if fullscreen {
            // Faded snow keeps falling over full-screen apps (unless set to none).
            return (!cfg.paused && cfg.fullscreenSnow >= 0.02) || !flakes.isEmpty || !debris.isEmpty
        }
        if !skiers.isEmpty || !queuedSkiers.isEmpty { return true }
        if !penguins.isEmpty || chickIn != nil { return true }        // [1.3 penguin] it waddles off
        if !reindeer.isEmpty { return true }                          // [1.3 reindeer] it trots off
        // Paused: the lights only keep twinkling if the user wants that.
        if cfg.christmas && cfg.lightsWhilePaused && (cfg.christmasGarland || treePos != nil
                                                       || (cfg.windowLights && windowLightSpan() != nil)) { return true }   // [1.3 holidays] window lights
        if cfg.christmas && cfg.lightsWhilePaused && hostsSnowman && housePos != nil { return true }   // [1.3 decor] lit windows, smoke
        if hostsSnowman && holiday.isAlive { return true }        // [1.3 holidays] fireworks, falling presents
        if !flakes.isEmpty || !debris.isEmpty || !shards.isEmpty || !snowballs.isEmpty || santa != nil { return true }
        if !blownPowder.isEmpty { return true }      // [1.3 weather] powder still in the air fades out (not frozen)
        if plow.isMoving || plow.input != 0 { return true }
        // While paused only a snowman in your hand or in the air needs frames.
        return hostsSnowman && snowmen.contains { $0.carried || $0.falling }
    }

    // MARK: - Drift physics

    private func rebuildColumns() {
        let n = Int(W / Self.columnW) + 1
        var cols = Array(repeating: [Pile](), count: n)
        for (k, p) in landables.enumerated() {
            p.landIndex = k
            let a = max(0, Int(Float(p.rect.minX) / Self.columnW))
            let b = min(n - 1, Int(Float(p.rect.maxX) / Self.columnW))
            if a <= b { for c in a...b { cols[c].append(p) } }
        }
        columns = cols
    }

    /// For each 32-pt column and each surface in it, the range [lo, hi] its snow top spans there.
    /// `hit` can only find a landing if the step from `oldY` to `newY` reaches into one of these
    /// ranges, so the flake loop skips it for the (many) flakes that are nowhere near a drift.
    @MainActor struct Bands {
        private var start: [Int] = []        // bands of column c: start[c] ..< start[c + 1]
        private var lo: [Float] = [], hi: [Float] = []
        private var pile: [Int] = []          // `landIndex` of the band's surface
        private var fill: [Int] = []
        private var valid = false             // false: every flake goes to `hit`

        /// One pass over each surface's bins. `columns` lists the surfaces of each column in `landables`
        /// order (see `rebuildColumns`), so the bands of a column come out in the same order.
        mutating func build(_ landables: [Pile], columns: [[Pile]]) {
            let nc = columns.count
            start.removeAll(keepingCapacity: true)
            var total = 0
            for list in columns { start.append(total); total += list.count }
            start.append(total)
            if lo.count != total {
                lo = Array(repeating: 0, count: total); hi = lo
                pile = Array(repeating: -1, count: total)
            }
            fill.removeAll(keepingCapacity: true)
            fill.append(contentsOf: start.dropLast())
            valid = true
            let w = Simulation.columnW, bw = Simulation.binW
            for (k, p) in landables.enumerated() {
                let minX = Float(p.rect.minX), top = Float(p.rect.maxY)
                let a = max(0, Int(minX / w)), b = min(nc - 1, Int(Float(p.rect.maxX) / w))
                guard a <= b else { continue }
                p.bins.withUnsafeBufferPointer { bins in
                    for c in a...b {
                        let j = fill[c]
                        guard j < start[c + 1] else { valid = false; return }
                        fill[c] = j + 1
                        let x0 = Float(c) * w - (c == 0 ? w : 0), x1 = Float(c + 1) * w
                        let b0 = max(0, Int(((x0 - minX) / bw).rounded(.down)) - 1)
                        let b1 = min(bins.count - 1, Int(((x1 - minX) / bw).rounded(.down)) + 1)
                        var l = Float.infinity, h = -Float.infinity
                        if b0 <= b1 { for i in b0...b1 { l = min(l, bins[i]); h = max(h, bins[i]) } }
                        lo[j] = top + l; hi[j] = top + h; pile[j] = k
                    }
                }
            }
            if valid { for c in 0..<nc where fill[c] != start[c + 1] { valid = false; break } }
        }

        /// Can a flake in column `c` moving from `oldY` down to `newY` cross a snow top there?
        @inline(__always)
        func crosses(column c: Int, from oldY: Float, to newY: Float) -> Bool {
            guard valid, c + 1 < start.count else { return true }
            for j in start[c]..<start[c + 1] where newY < hi[j] && oldY >= lo[j] { return true }
            return false
        }

        /// `deposit` changed bins around `b` (and the ends of a raised surface): update those columns.
        mutating func refresh(_ p: Pile, around b: Int, columns: [[Pile]]) {
            guard valid, start.count == columns.count + 1 else { return }
            let x0 = Float(p.rect.minX), n = p.bins.count
            func update(_ k0: Int, _ k1: Int) {
                let c0 = max(0, Int((x0 + Float(k0) * Simulation.binW) / Simulation.columnW) - 1)
                let c1 = min(columns.count - 1, Int((x0 + Float(k1 + 1) * Simulation.binW) / Simulation.columnW) + 1)
                guard c0 <= c1 else { return }
                for c in c0...c1 {
                    for j in start[c]..<start[c + 1] where pile[j] == p.landIndex {
                        let r = Self.range(p, column: c)
                        lo[j] = r.lo; hi[j] = r.hi
                    }
                }
            }
            update(max(0, b - 8), min(n - 1, b + 8))
            if p.kind != .ground { update(0, 0); update(n - 1, n - 1) }
        }

        /// Lowest and highest snow top of `p` over the bins a flake in column `c` can reach (one bin of
        /// slack on each side for rounding; column 0 also holds x in (−32, 0), as in `hit`).
        private static func range(_ p: Pile, column c: Int) -> (lo: Float, hi: Float) {
            let w = Simulation.columnW, bw = Simulation.binW
            let x0 = Float(c) * w - (c == 0 ? w : 0), x1 = Float(c + 1) * w
            let minX = Float(p.rect.minX)
            let b0 = max(0, Int(((x0 - minX) / bw).rounded(.down)) - 1)
            let b1 = min(p.bins.count - 1, Int(((x1 - minX) / bw).rounded(.down)) + 1)
            guard b0 <= b1 else { return (.infinity, -.infinity) }
            var l = Float.infinity, h = -Float.infinity
            p.bins.withUnsafeBufferPointer { bins in
                for k in b0...b1 { l = min(l, bins[k]); h = max(h, bins[k]) }
            }
            let top = Float(p.rect.maxY)
            return (top + l, top + h)
        }
    }

    private func hit(x: Float, oldY: Float, newY: Float) -> (Pile, Int)? {
        let c = Int(x / Self.columnW)
        guard c >= 0, c < columns.count else { return nil }
        for p in columns[c] {
            let rel = x - Float(p.rect.minX)
            if rel < 0 || rel >= Float(p.rect.width) { continue }
            let b = Int(rel / Self.binW)
            if b >= p.bins.count || !p.visible[b] { continue }
            let top = Float(p.rect.maxY) + p.bins[b]
            if oldY >= top && newY < top { return (p, b) }
        }
        return nil
    }

    private func deposit(_ p: Pile, _ b: Int, _ amount: Float) {
        // A window in front blocks the column: snow can't pile up into it.
        let cap = b < p.limit.count ? min(p.cap, max(0, p.limit[b])) : p.cap
        guard p.bins[b] < cap else { return }
        p.bins[b] = min(cap, p.bins[b] + amount)
        let n = p.bins.count
        let slope: Float = p.kind == .ground ? 1.8 : 1.7
        for _ in 0..<2 {
            for j in max(0, b - 7)...min(n - 1, b + 7) {
                if j > 0 {
                    let d = p.bins[j] - p.bins[j - 1]
                    if d > slope { let m = (d - slope) * 0.5; p.bins[j] -= m; p.bins[j - 1] += m }
                }
                if j < n - 1 {
                    let d = p.bins[j] - p.bins[j + 1]
                    if d > slope { let m = (d - slope) * 0.5; p.bins[j] -= m; p.bins[j + 1] += m }
                }
            }
        }
        if p.kind != .ground {
            // Snow falls off the edges, so the ends stay rounded.
            let e = slope * 0.8
            if p.bins[0] > e { p.bins[0] = e }
            if p.bins[n - 1] > e { p.bins[n - 1] = e }
        }
        p.dirty = true
    }

    /// An auto-hiding Dock is coming up: penguins, reindeer and skiers in its way are tossed up onto it.
    /// A snowman standing at the bottom where it comes up is lifted onto it with a little hop (one put on the
    /// Dock that fell off as it slid away goes back up with it); one only half over its end is shoved aside.
    private func pushedByDock(_ d: CGRect) {
        let lo = Float(d.minX) - 2, hi = Float(d.maxX) + 2
        func top(_ x: Float) -> Float { Float(d.maxY) + driftHeight(Self.dockKey, at: x) }
        for i in penguins.indices where penguins[i].x > lo && penguins[i].x < hi && penguins[i].y < top(penguins[i].x) - 1 {
            penguins[i].liftedByDock(to: top(penguins[i].x))
        }
        for i in reindeer.indices where reindeer[i].x > lo && reindeer[i].x < hi && reindeer[i].y < top(reindeer[i].x) - 1 {
            reindeer[i].liftedByDock(to: top(reindeer[i].x))
        }
        for i in skiers.indices where skiers[i].x > lo && skiers[i].x < hi && skiers[i].y < top(skiers[i].x) - 1 {
            skiers[i].liftedByDock(to: top(skiers[i].x))
        }
        var shoved: (left: Float, right: Float) = (0, 0)    // how far the row beside each end already reaches
        for i in snowmen.indices {
            let s = snowmen[i]
            let half = 30 * s.scale * s.sizeScale
            guard !s.carried, !s.falling, s.hostKey == Self.groundKey,
                  s.anchorX > Float(d.minX) - half, s.anchorX < Float(d.maxX) + half else { continue }
            if s.anchorX > Float(d.minX) + half * 0.5, s.anchorX < Float(d.maxX) - half * 0.5 {
                // The Dock comes up faster than a hop: it simply picks the snowman up (with a jolt), and it rides
                // along from then on (see syncSnowmen).
                snowmen[i].hostKey = Self.dockKey
                snowmen[i].hostRect = d
                snowmen[i].offsetX = s.anchorX - Float(d.minX)
                snowmen[i].baseY = top(s.anchorX) * 0.85 + Float(d.maxY) * 0.15
                snowmen[i].userPlaced = true
                snowmen[i].wobble = 1
                continue
            }
            let left = s.anchorX - Float(d.minX) < Float(d.maxX) - s.anchorX
            let x = left ? Float(d.minX) - shoved.left - half - 4 : Float(d.maxX) + shoved.right + half + 4
            guard x > half, x < W - half else { continue }      // no room beside the Dock: leave it be
            if left { shoved.left += 2 * half + 4 } else { shoved.right += 2 * half + 4 }
            snowmen[i].anchorX = x
            snowmen[i].offsetX = x
            snowmen[i].falling = true
            snowmen[i].vy = 140
        }
    }

    /// An auto-hiding Dock rises out of the snow at the bottom: the snow above it is lifted onto the Dock
    /// (as much as it holds), and the rest is thrown off to the sides with a puff of powder.
    private func liftGround(onto p: Pile) {
        guard let g = piles[Self.groundKey], !p.bins.isEmpty else { return }
        let x0 = Float(p.rect.minX), mid = Float(p.rect.midX)
        var room = max(0, 9000 - debris.count)
        for i in 0..<p.bins.count {
            let x = x0 + (Float(i) + 0.5) * Self.binW
            let gi = Int(x / Self.binW)
            guard gi >= 0, gi < g.bins.count else { continue }
            let h = g.bins[gi]
            g.bins[gi] = 0
            guard h > 0.05 else { continue }
            let keep = min(h, p.cap)
            p.bins[i] = max(p.bins[i], keep)
            let away: Float = x < mid ? -1 : 1
            // What doesn't fit on the Dock is thrown off, outwards; a deep drift also puffs a little powder.
            if h - keep > 1 && room > 0 && i % 2 == 0 {
                let size = max(2.5, min(9, (h - keep) * 0.3))
                debris.append(Debris(x: x, y: keep + 4, vx: away * Float.random(in: 40...160), vy: Float.random(in: 80...220),
                                     size: size, alpha: 1, lands: true))
                room -= 1
            }
            if h > 4 && room > 0 && Float.random(in: 0...1) < 0.25 {
                debris.append(Debris(x: x, y: keep, vx: away * Float.random(in: 0...60) + Float.random(in: -30...30),
                                     vy: Float.random(in: 30...120), size: Float.random(in: 1.5...3.5), alpha: 0.85,
                                     lands: false, fade: 0.9))
                room -= 1
            }
        }
        g.dirty = true
        p.dirty = true
    }

    /// A window moved or disappeared – the snow slides off and icicles snap.
    private func shake(_ p: Pile, push: Float) { dump(p, vel: SIMD2(push, 0)) }

    /// The whole drift falls: it leaves as one slab (shared velocity) and breaks into clumps,
    /// with a puff of powder. Clumps land on whatever is below and pile up again.
    private func dump(_ p: Pile, vel: SIMD2<Float>) {
        let n = p.bins.count
        let x0 = Float(p.rect.minX), top = Float(p.rect.maxY)
        // The slab keeps part of the window's motion (friction) – capped so it stays readable.
        let carry = SIMD2(max(-480, min(480, vel.x * 0.5)), max(-220, min(280, vel.y * 0.35)))
        // How much snow is there? Everything that falls is proportional to it.
        var volume: Float = 0
        for i in 0..<n where p.visible[i] { volume += p.bins[i] * Self.binW }
        let room = max(0, 9000 - debris.count)
        var budget = min(room, 4000)
        var i = 0
        while i < n && budget > 0 {
            let h = p.bins[i]
            guard h > 0.3, p.visible[i] else { i += 1; continue }
            // Deep drifts break into big clumps, a dusting into small ones.
            let s = max(3, min(20, 3 + h * 0.34)) * Float.random(in: 0.85...1.15)
            let step = max(1, Int(s * 0.45 / Self.binW))
            let x = x0 + (Float(i) + Float(step) * 0.5) * Self.binW
            // Stack clumps to fill the drift's height, so the slab keeps its shape as it leaves.
            let layers = max(1, min(8, Int((h / (s * 0.7)).rounded(.up))))
            for k in 0..<layers {
                let frac = (Float(k) + 0.5) / Float(layers)
                let size = s * (1 - 0.25 * frac) * Float.random(in: 0.8...1.1)
                // Bigger chunks hold together longer; small bits scatter more.
                let spread = 26 / (1 + s * 0.08)
                debris.append(Debris(x: x + Float.random(in: -2...2), y: top + frac * h,
                                     vx: carry.x * Float.random(in: 0.8...1) + Float.random(in: -spread...spread),
                                     vy: carry.y + Float.random(in: -8...30) + frac * 14, size: size, alpha: 1, lands: true))
                budget -= 1
            }
            i += step
        }
        // Powder cloud – bigger and longer-lived the more snow falls.
        let puffs = min(Int(volume / 45), min(500, max(0, 9000 - debris.count)))
        let fade = max(0.55, 1.5 - volume / 6000)
        for _ in 0..<puffs {
            let k = Int.random(in: 0..<n)
            guard p.visible[k] else { continue }
            let h = p.bins[k]
            debris.append(Debris(x: x0 + (Float(k) + 0.5) * Self.binW, y: top + h * Float.random(in: 0.4...1.1),
                                 vx: carry.x * 0.45 + Float.random(in: -95...95), vy: Float.random(in: 25...170),
                                 size: Float.random(in: 1.5...4.5), alpha: 0.9, lands: false, fade: fade))
        }
        for (k, ic) in p.icicles.enumerated() where ic.len > 2 && (k < p.icicleVisible.count && p.icicleVisible[k]) {
            shards.append(Shard(x: x0 + ic.x, y: Float(p.rect.minY), vy: min(0, vel.y * 0.3), len: ic.len, width: ic.width))
        }
        for i in 0..<n { p.bins[i] = 0 }
        p.icicles = []
        p.icicleVisible = []
        p.frost = 0
        p.dirty = true
        p.iceDirty = true
    }

    /// A small nudge: part of the top layer shakes off, the rest rides along with the window.
    private func shed(_ p: Pile, vel: SIMD2<Float>, fraction: Float) {
        let x0 = Float(p.rect.minX), top = Float(p.rect.maxY)
        for i in p.bins.indices where p.bins[i] > 0.6 && p.visible[i] {
            // Edges lose more than the middle.
            let edge: Float = min(Float(i), Float(p.bins.count - 1 - i)) < 6 ? 2.2 : 1
            let take = p.bins[i] * min(0.9, fraction * edge)
            guard take > 0.3 else { continue }
            p.bins[i] -= take
            if i % 2 == 0 {
                debris.append(Debris(x: x0 + (Float(i) + 0.5) * Self.binW, y: top + p.bins[i] + take * 0.5,
                                     vx: -vel.x * 0.15 + Float.random(in: -25...25), vy: Float.random(in: 10...60),
                                     size: min(8, 2.2 + take * 0.8), alpha: 1, lands: true))
            }
        }
        if vel.x * vel.x + vel.y * vel.y > 150 * 150 {
            for (k, ic) in p.icicles.enumerated() where ic.len > 2 && (k < p.icicleVisible.count && p.icicleVisible[k]) {
                shards.append(Shard(x: x0 + ic.x, y: Float(p.rect.minY), vy: 0, len: ic.len, width: ic.width))
            }
            p.icicles = []
            p.icicleVisible = []
            p.iceDirty = true
        }
        p.dirty = true
    }

    /// Shovel the snow off the bottom edge and the Dock (menu action).
    func shovelBottom() {
        for p in landables where p.kind == .ground || p.kind == .dock {
            let x0 = Float(p.rect.minX), top = Float(p.rect.maxY)
            for i in p.bins.indices where p.bins[i] > 0.4 && p.visible[i] && i % 2 == 0 {
                debris.append(Debris(x: x0 + (Float(i) + 0.5) * Self.binW, y: top + p.bins[i] * 0.6,
                                     vx: Float.random(in: -90...90), vy: Float.random(in: 120...320),
                                     size: min(7, 2 + p.bins[i] * 0.3), alpha: 1, lands: false))
            }
            for i in p.bins.indices { p.bins[i] = 0 }
            p.dirty = true
        }
    }

    func shakeAll() {
        for p in piles.values { shake(p, push: 0); p.lastMove = CACurrentMediaTime() }
        for k in menuSnow.indices { menuSnow[k] = 0 }
        menuMeshValid = false
        for ic in menuIcicles where ic.len > 2 {
            shards.append(Shard(x: ic.x, y: H - Float(menuBarHeight), vy: 0, len: ic.len, width: ic.width))
        }
        menuIcicles = []
    }

    private func splat(_ s: Snowball) {
        if let p = piles[s.target], let b = Optional(Int((s.tx - Float(p.rect.minX)) / Self.binW)), b >= 0, b < p.bins.count {
            for k in max(0, b - 4)...min(p.bins.count - 1, b + 4) where p.visible[k] { deposit(p, k, 1.4) }
        }
        for _ in 0..<14 {
            let a = Float.random(in: 0...(2 * .pi))
            let v = Float.random(in: 40...170)
            debris.append(Debris(x: s.x, y: s.y, vx: cos(a) * v, vy: abs(sin(a)) * v, size: Float.random(in: 2...4.5),
                                 alpha: 1, lands: false))
        }
    }

    private func spawnFlake() {
        let depth = Float.random(in: 0.25...1)
        let temp = Float(cfg.temperature)
        // Above zero the snow gets wet (heavier, faster); above +4 °C it turns to sleet.
        let wet: Float = temp > 0 ? min(1, temp / 4) : 0
        let sleet = temp > 4
        let size = (1.4 + depth * depth * 5.2) * Float(cfg.flakeSize) * (sleet ? 0.55 : 1 + wet * 0.2)
        let vy = (22 + 58 * depth + Float.random(in: 0...12)) * Float(cfg.fallSpeed) * (sleet ? 2.6 : 1 + wet * 0.5)
        flakes.append(Flake(x: Float.random(in: -20...(W + 20)), y: H + size, vx: 0, vy: vy,
                            phase: Float.random(in: 0...(2 * .pi)), freq: Float.random(in: 0.5...1.6),
                            amp: Float.random(in: 5...22) * depth * (sleet ? 0.2 : 1), depth: depth, size: size,
                            alpha: (0.5 + 0.5 * depth) * (sleet ? 0.6 : 1),
                            sparkle: cfg.sparkle && Float.random(in: 0...1) < 0.18))
    }

    /// The cursor scatters flakes; a fast swipe across a drift knocks it down.
    private func stepMouse(_ m: SIMD2<Float>, dt: Float) {
        defer { lastMouse = m }
        guard let last = lastMouse, dt > 0 else { return }
        let v = (m - last) / dt
        let speed = (v.x * v.x + v.y * v.y).squareRoot()
        guard speed > 40, speed < 20000 else { return }
        let r: Float = 70
        var kicked = false
        flakes.withUnsafeMutableBufferPointer { buf in
            for i in buf.indices {
                let dx = buf[i].x - m.x, dy = buf[i].y - m.y
                let d2 = dx * dx + dy * dy
                if d2 < r * r {
                    let fall = 1 - d2.squareRoot() / r
                    buf[i].vx += v.x * 0.35 * fall
                    buf[i].y += v.y * 0.02 * fall
                    kicked = true
                }
            }
        }
        if kicked { kickedUntil = time + 1.0 }
        guard speed > 260 else { return }
        for p in landables {
            let rel = m.x - Float(p.rect.minX)
            guard rel >= 0, rel < Float(p.rect.width) else { continue }
            let c = Int(rel / Self.binW)
            guard c < p.bins.count else { continue }
            let top = Float(p.rect.maxY)
            guard m.y >= top - 3, m.y <= top + p.bins[c] + 4 else { continue }
            // By hand (no shovel) a swipe only brushes a little off the top.
            for k in max(0, c - 2)...min(p.bins.count - 1, c + 2) where p.bins[k] > 0.4 && p.visible[k] {
                let take = p.bins[k] * 0.2
                p.bins[k] -= take
                debris.append(Debris(x: Float(p.rect.minX) + (Float(k) + 0.5) * Self.binW, y: top + p.bins[k] + take * 0.5,
                                     vx: v.x * 0.25 + Float.random(in: -20...20), vy: Float.random(in: 20...90),
                                     size: min(10, 2.5 + take * 0.5), alpha: 1, lands: true))
            }
            p.dirty = true
        }
    }

    /// ⌥ + cursor = shovel: pushes snow in the direction of motion (a ridge builds up ahead),
    /// works at any speed, also on the bottom drift and the Dock.
    private func stepShovel(_ m: SIMD2<Float>, dt: Float) {
        let dirX: Float = {
            guard let last = lastMouse else { return 0 }
            let d = m.x - last.x
            return abs(d) < 0.3 ? 0 : (d > 0 ? 1 : -1)
        }()
        let reach = 6                     // bins on each side (≈ 24 pt) – the shovel bites much deeper than a hand
        for p in landables {
            let rel = m.x - Float(p.rect.minX)
            guard rel >= -16, rel < Float(p.rect.width) + 16 else { continue }
            let top = Float(p.rect.maxY)
            let c = Int(rel / Self.binW), n = p.bins.count
            let lo = max(0, c - reach), hi = min(n - 1, c + reach)
            guard lo <= hi else { continue }
            var tallest: Float = 0
            for k in lo...hi { tallest = max(tallest, p.bins[k]) }
            guard m.y >= top - 6, m.y <= top + tallest + 14 else { continue }
            var moved: Float = 0
            for k in lo...hi where p.bins[k] > 0.05 {
                let take = p.bins[k] * min(1, 22 * dt)
                p.bins[k] -= take
                moved += take
            }
            guard moved > 0.01 else { continue }
            p.dirty = true
            shoveled = true                   // [1.3 welcome]
            if dirX != 0 {
                // Plough: the snow piles up just ahead of the shovel; off the end it falls.
                let ahead = c + Int(dirX) * (reach + 2)
                if ahead >= 0 && ahead < n && p.visible[ahead] {
                    let before = p.bins[ahead]
                    deposit(p, ahead, moved * 0.85)
                    moved -= max(0, p.bins[ahead] - before)
                }
            }
            if moved > 0.2 && Float.random(in: 0...1) < 0.6 {
                debris.append(Debris(x: m.x + dirX * 10, y: top + 4, vx: dirX * Float.random(in: 40...140) + Float.random(in: -30...30),
                                     vy: Float.random(in: 40...150), size: min(6, 1.8 + moved * 0.4), alpha: 0.95,
                                     lands: dirX != 0))
            }
        }
    }

    // MARK: - Snowmen

    /// The Christmas tree stands on the ground next to the Dock (left side if there is room).
    private func syncTree() {
        let s = Float(cfg.treeSize)
        var x: Float
        if let d = layoutDock, d.minY < size.height / 2 {
            let a = avoidLocal ?? d
            let margin: Float = dockGuessed ? 30 : 0
            // [1.3 tree] Left of the Dock when the tree, its presents and the sign all fit there, else right of it
            // (past any snowmen lined up on the ground there, e.g. by a Dock on the left), else wherever the
            // tree alone fits.
            let left = Float(a.minX) - 62 * s - margin
            var right = Float(a.maxX) + 62 * s + margin
            if cfg.snowman {
                let sz = Float(cfg.snowmanSize)
                for i in 0..<max(1, min(6, Int(cfg.snowmanCount.rounded()))) {
                    let sl = slot(i, size: sz)
                    if sl.key == Self.groundKey { right = max(right, sl.x + 34 * sz + 50 * s) }
                }
            }
            let extra = 140 * s
            if left - extra >= 20 { x = left }
            else if right + extra <= W - 20 { x = right }
            else if left >= 50 * s { x = left }
            else { x = right }
        } else {
            x = W * 0.12
        }
        x = max(50 * s, min(W - 50 * s, x))
        // [1.3 holidays] the sign and the presents go on the side away from the Dock (if there is room)
        var side: Float = layoutDock.map { x < Float($0.midX) ? -1 : 1 } ?? -1
        if x + side * 135 * s < 20 || x + side * 135 * s > W - 20 {
            // Flip only if the sign would not land on the Dock there; otherwise it stays outside, squeezed
            // against the screen edge (see buildHolidays).
            let other = x - side * 122 * s
            let onDock = layoutDock.map { d -> Bool in
                let a = avoidLocal ?? d
                return other + 34 * s > Float(a.minX) && other - 34 * s < Float(a.maxX) && a.minY < size.height / 2
            } ?? false
            if !onDock { side = -side }
        }
        holidaySpot = (x, side)
        guard cfg.christmas, cfg.christmasTree else { treePos = nil; return }
        // [1.3 tree] whole points only, so the cached tree is not rebuilt for every flake that lands
        let drift = driftHeight(Self.groundKey, at: x)
        let y = (drift * 0.8).rounded()
        treePos = (x, y)
        // [1.3 tree] the branches carry more snow as the drift around the tree grows (and less as it thaws)
        let full = Float(min(28, max(6, cfg.groundDepth * 0.8)))
        treeSnow = (min(1, drift / full) * 4).rounded() / 4
        let r = Christmas.treeRect(x: x, baseY: y, scale: s).insetBy(dx: 12, dy: 6)
        treeGhost = cfg.snowmanGhost && windowRects.contains { $0.rect.intersects(r) }
        treeHidden = localOcc.contains { $0.intersects(r) }
    }

    /// Default spot for snowman i: along the top of the Dock from the right, then beside the Dock.
    private func slot(_ i: Int, size sz: Float) -> (key: Int, x: Float, y: Float) {
        let gap = 64 * sz
        if dockTransient, let d = dockRest {
            // An auto-hiding Dock: line up on the ground to the right of where it shows up (the tree is on
            // the left), so the Dock never comes up through a snowman.
            let gx = Float(d.maxX) + 40 * sz + Float(i) * gap
            return (Self.groundKey, min(W - 20 * sz, gx), 0)
        }
        if let d = layoutDock, d.minY < size.height / 2, dockGuessed {
            // Only a guess of where the Dock is: keep every snowman on top of its middle part.
            let count = Float(max(1, autoSnowmen))
            let row = min(gap, Float(d.width) * 0.75 / count)
            return (Self.dockKey, Float(d.midX) + (count - 1) * row * 0.5 - Float(i) * row, Float(d.maxY))
        }
        if let d = layoutDock, d.minY < size.height / 2 {
            let x = Float(d.maxX) - 46 * sz - Float(i) * gap
            if x > Float(d.minX) + 20 * sz { return (Self.dockKey, x, Float(d.maxY)) }
            // No more room on the Dock: line up on the ground to the right of it (the tree is on the left).
            let k = Float(i) - floor((Float(d.width) - 66 * sz) / gap) - 1
            let a = avoidLocal ?? d
            let gx = Float(a.maxX) + 40 * sz + max(0, k) * gap
            return (Self.groundKey, min(W - 20 * sz, gx), 0)
        }
        // The Dock is on the side, hidden or unknown: stand on the bottom drift, spread around the middle.
        let count = Float(max(1, autoSnowmen))
        let row = min(gap * 0.8, W * 0.4 / count)
        let x = W * 0.5 + (count - 1) * row * 0.5 - Float(i) * row
        return (Self.groundKey, x, 0)
    }

    private func surfaceRect(_ key: Int) -> CGRect? {
        if key == Self.groundKey { return CGRect(x: 0, y: -1, width: size.width, height: 1) }
        if key == Self.dockKey { return dockLocal }
        if let p = piles[key] { return p.rect }
        return windowRects.first { $0.key == key }?.rect
    }

    /// Highest visible surface at x whose top is at or below y.
    /// `liveDock`: include an auto-hiding Dock while it is shown (visitors); snowmen and hats never stay on it.
    private func surfaceBelow(x: Float, y: Float, liveDock: Bool = false) -> (key: Int, top: Float) {
        var best: (Int, Float) = (Self.groundKey, 0)
        for (idx, w) in windowRects.enumerated() {
            let r = w.rect
            guard x >= Float(r.minX) + 8, x <= Float(r.maxX) - 8, Float(r.maxY) <= y + 1, Float(r.maxY) > best.1,
                  r.maxY < size.height - menuBarHeight - 1 else { continue }
            let pt = CGPoint(x: CGFloat(x), y: r.maxY + 3)
            if windowRects[..<idx].contains(where: { $0.rect.contains(pt) }) { continue }
            best = (w.key, Float(r.maxY))
        }
        if !dockTransient || liveDock, let d = dockLocal, x >= Float(d.minX), x <= Float(d.maxX), Float(d.maxY) <= y + 1, Float(d.maxY) > best.1 {
            best = (Self.dockKey, Float(d.maxY))
        }
        return best
    }

    private func syncSnowmen() {
        let want = cfg.snowman ? max(1, min(6, Int(cfg.snowmanCount.rounded()))) : 0
        // [1.3 snowmen] The automatic snowmen come first in `snowmen`, the ones the user rolled after them.
        var autos = autoSnowmen
        while autos < want {
            var s = Snowman()
            s.id = newSnowmanID()
            s.nextBuild = autos == 0 ? 12 : Float(4 + autos * 5)
            snowmen.insert(s, at: autos)
            autos += 1
        }
        while autos > want {
            var s = snowmen.remove(at: autos - 1)
            s.dismantle(into: &debris)
            autos -= 1
        }
        let sz = Float(cfg.snowmanSize)
        for i in snowmen.indices {
            var s = snowmen[i]
            if !s.userBuilt { s.sizeScale = sz }
            if s.carried || s.falling { snowmen[i] = s; continue }
            if !s.userPlaced {
                let sl = slot(i, size: sz)
                s.hostKey = sl.key
                s.anchorX = sl.x
                s.baseY = sl.y + driftHeight(sl.key, at: sl.x) * 0.85
                s.hostRect = surfaceRect(sl.key)
            } else if dockTransient, s.hostKey == Self.dockKey, let r = dockLocal, let old = s.hostRect,
                      abs(r.minX - old.minX) < 0.5, r.maxY > old.maxY + 0.5,
                      s.offsetX >= 0, s.offsetX <= Float(r.width) {
                // An auto-hiding Dock sliding up carries the snowman on it (sliding down, it falls off).
                s.hostRect = r
                s.anchorX = Float(r.minX) + s.offsetX
                s.baseY = Float(r.maxY) + driftHeight(s.hostKey, at: s.anchorX) * 0.85
            } else if let r = surfaceRect(s.hostKey), let old = s.hostRect,
                      abs(r.minX - old.minX) < 0.5, abs(r.maxY - old.maxY) < 0.5,
                      s.offsetX >= 0, s.offsetX <= Float(r.width) - 6 {
                s.anchorX = Float(r.minX) + s.offsetX
                s.baseY = Float(r.maxY) + driftHeight(s.hostKey, at: s.anchorX) * 0.85
            } else if s.phase != .absent {
                // The window it stood on moved or closed – it falls.
                s.falling = true
                s.vy = 0
            } else {
                s.userPlaced = false
            }
            // Fade it when it covers a window (behind the Dock or in front of its own window), and hide
            // it completely under menus, popovers and notifications.
            s.ghost = false
            s.hidden = false
            if let body = s.bodyRect {
                if cfg.snowmanGhost {
                    for w in windowRects {
                        if w.key == s.hostKey { break }
                        if w.rect.intersects(body.insetBy(dx: 4, dy: 2)) { s.ghost = true; break }
                    }
                }
                s.hidden = !s.carried && localOcc.contains { $0.intersects(body) }
            }
            snowmen[i] = s
        }
    }

    private func stepSnowmen(dt: Float) {
        guard cfg.snowman else {
            for i in snowmen.indices where snowmen[i].phase != .absent { snowmen[i].dismantle(into: &debris) }
            snowmen.removeAll { $0.retired }                // [1.3 snowmen]
            return
        }
        if cfg.paused || fullscreen {
            // Frozen life cycle, but a snowman you dropped still lands.
            for i in snowmen.indices where snowmen[i].falling { stepFall(i, dt: dt) }
            return
        }
        for i in snowmen.indices {
            snowmen[i].lookAt = mouseLocal
            snowmen[i].rebuildDelay = Float(cfg.snowmanBreak) * 60
            snowmen[i].throwEvery = Float(cfg.throwEvery)
            snowmen[i].temperature = Float(cfg.temperature)
            snowmen[i].santaHat = cfg.christmas && cfg.christmasHats
            snowmen[i].seasonalHat = seasonalHat            // [1.3 snowmen]
            snowmen[i].sparkler = sparklers
            snowmen[i].holdsKeepsake = cfg.christmas && cfg.christmasDecor   // [1.3 decor]
            snowmen[i].outfits = cfg.snowmanOutfits
            if snowmen[i].falling { stepFall(i, dt: dt) }
            if let h = snowmen[i].flyingHat, !h.lying {
                // A hat knocked off lands on whatever is below it (the Dock, a window, the bottom).
                let below = surfaceBelow(x: h.x, y: h.y)
                snowmen[i].flyingHat?.rest = below.top + driftHeight(below.key, at: h.x) * 0.85 + 1
            }
            let wantsThrow = snowmen[i].step(dt: dt, debris: &debris, shards: &shards)
            if wantsThrow && cfg.snowballs && !snowmen[i].ghost {
                // [1.3 snowmen] with two or more snowmen, some throws go at each other
                if Float.random(in: 0...1) < 0.4, let v = fightTarget(for: i) { throwSnowball(from: i, atSnowman: v) }
                else { throwSnowball(from: i) }
            }
            if let target = snowmen[i].takeRetort(), cfg.snowballs, !snowmen[i].ghost {
                if target >= 0, let t = snowmanIndex(target), snowmen[t].phase == .standing {
                    throwSnowball(from: i, atSnowman: t)
                } else if target < 0, let m = mouseLocal {
                    throwSnowball(from: i, toward: m)
                }
            }
        }
        // [1.3 snowmen] rolled snowmen that melted away – once their loose balls, carrot and hat have landed, and
        // never while one is being dragged (indices must not shift under the mouse).
        if !snowmen.contains(where: { $0.carried }) {
            snowmen.removeAll { $0.retired && $0.loose.isEmpty && $0.carrot == nil && $0.flyingHat == nil }
        }
    }

    private func stepFall(_ i: Int, dt: Float) {
        var s = snowmen[i]
        let target = surfaceBelow(x: s.anchorX, y: s.baseY, liveDock: true)   // a shown auto-hiding Dock holds it too
        s.vy -= Self.gravity * dt
        s.baseY += s.vy * dt
        if s.baseY <= target.top {
            s.baseY = target.top
            s.falling = false
            s.wobble = 1
            s.hostKey = target.key
            s.hostRect = surfaceRect(target.key)
            s.offsetX = s.anchorX - Float(s.hostRect?.minX ?? 0)
            s.userPlaced = true
            for _ in 0..<8 {
                let a = Float.random(in: 0.2...(.pi - 0.2)), v = Float.random(in: 40...120)
                debris.append(Debris(x: s.anchorX, y: s.baseY + 2, vx: cos(a) * v, vy: sin(a) * v,
                                     size: .random(in: 2...4), alpha: 1, lands: false))
            }
        }
        snowmen[i] = s
    }

    func throwSnowball(from i: Int = 0) {
        guard snowmen.indices.contains(i) else { return }
        let targets = landables.filter { ($0.kind == .window || $0.kind == .icon || $0.kind == .widget) && $0.visible.contains(true) }
        guard let p = targets.randomElement() else { return }
        let idx = p.visible.indices.filter { p.visible[$0] }
        guard let b = idx.randomElement() else { return }
        let tx = Float(p.rect.minX) + (Float(b) + 0.5) * Self.binW
        let ty = Float(p.rect.maxY) + p.bins[b] + 2
        let hand = snowmen[i].handPosition
        let dist = hypot(tx - hand.x, ty - hand.y)
        let T = max(0.6, min(1.7, dist / 420))
        let vx = (tx - hand.x) / T
        let vy = (ty - hand.y) / T + 0.5 * 600 * T
        snowballs.append(Snowball(x: hand.x, y: hand.y, vx: vx, vy: vy, t: 0, duration: T, target: p.key, tx: tx))
        snowmen[i].armThrow = 1
    }

    /// Index of the snowman with this id.
    func snowmanIndex(_ id: Int) -> Int? { snowmen.firstIndex { $0.id == id } }

    private func newSnowmanID() -> Int { nextSnowmanID += 1; return nextSnowmanID }
    private var nextSnowmanID = 0

    func snowmanClicked(id: Int, at p: CGPoint) {
        guard hostsSnowman, let i = snowmanIndex(id) else { return }
        if SnowYard.optionDown { throwAtSnowman(i, at: p); return }      // [1.3 snowmen] ⌥-click = throw a snowball
        let fightBack = snowmen[i].hit(at: SIMD2(Float(p.x), Float(p.y)), debris: &debris)
        if fightBack && cfg.snowballs { throwSnowball(from: i) }
    }

    /// Drag a snowman with the mouse (`p` = cursor in local coordinates).
    func dragSnowman(id: Int, to p: CGPoint) {
        guard let i = snowmanIndex(id), snowmen[i].bodyRect != nil else { return }
        snowmen[i].carried = true
        snowmen[i].falling = false
        snowmen[i].anchorX = Float(p.x)
        snowmen[i].baseY = Float(p.y) - snowmen[i].R(0) * 1.4
        snowmen[i].wobble = max(snowmen[i].wobble, 0.4)
    }

    /// Let go: it falls onto whatever is below.
    func dropSnowman(id: Int) {
        guard let i = snowmanIndex(id), snowmen[i].carried else { return }
        snowmen[i].carried = false
        snowmen[i].falling = true
        snowmen[i].vy = 0
    }

    /// Click targets of the snowmen, keyed by their stable ids.
    var snowmanTargets: [(id: Int, rect: CGRect?)] {
        guard hostsSnowman, !fullscreen else { return [] }
        return snowmen.map { ($0.id, $0.hidden ? nil : $0.hitRect) }
    }

    func restartSnowmen() {
        snowmen.removeAll { $0.userBuilt }                  // [1.3 snowmen]
        for i in snowmen.indices { snowmen[i].restart() }
    }

    func buildSnowmanNow() {
        guard hostsSnowman else { return }
        for i in snowmen.indices { snowmen[i].buildNow() }
    }

    /// Send all dragged snowmen back to the Dock.
    func resetSnowmen() {
        for i in snowmen.indices where !snowmen[i].userBuilt { snowmen[i].userPlaced = false; snowmen[i].falling = false }
        syncSnowmen()
    }

    // MARK: - [1.3 snowmen] Rolling snowmen, snowball fights

    private var autoSnowmen: Int { snowmen.reduce(0) { $0 + ($1.userBuilt ? 0 : 1) } }

    /// ⌥ held over a snowman: the cursor holds a snowball instead of the shovel.
    private func aiming(at m: SIMD2<Float>) -> Bool {
        guard hostsSnowman, cfg.snowman else { return false }
        let pt = CGPoint(x: CGFloat(m.x), y: CGFloat(m.y))
        return snowmen.contains { !$0.hidden && ($0.hitRect?.insetBy(dx: -4, dy: -4).contains(pt) ?? false) }
    }

    private func stepYard(dt: Float) {
        guard hostsSnowman, cfg.snowman else {
            if !yard.isEmpty { yard.crumbleAll(into: &debris) }
            return
        }
        guard !cfg.paused, !fullscreen else { return }
        let held = cfg.mouse && rollHeld > 0.2 ? mouseLocal : nil
        var span: ClosedRange<Float>?
        if plow.visible {
            let a = plow.x - plow.facing * 46, b = plow.x + plow.facing * 58
            span = min(a, b)...max(a, b)
        }
        let dock = dockLocal.flatMap { $0.minY < size.height / 2 ? $0 : nil }
        let done = yard.step(
            dt: dt, cursor: held, maxRadius: 20 * Float(cfg.snowmanSize), temperature: Float(cfg.temperature), plow: span,
            debris: &debris,
            surfaceAt: { m in
                if let d = dock, let p = self.piles[Self.dockKey], m.x >= Float(d.minX), m.x <= Float(d.maxX),
                   m.y >= Float(d.minY) - 4, m.y <= Float(d.maxY) + self.driftHeight(Self.dockKey, at: m.x) + 70 {
                    return SnowYard.Surface(pile: p, top: Float(d.maxY))
                }
                guard let g = self.piles[Self.groundKey], m.y <= self.driftHeight(Self.groundKey, at: m.x) + 70 else { return nil }
                return SnowYard.Surface(pile: g, top: 0)
            },
            surfaceFor: { key in
                guard let p = self.piles[key] else { return nil }
                return SnowYard.Surface(pile: p, top: key == Self.groundKey ? 0 : Float(p.rect.maxY))
            },
            height: { key, x in self.driftHeight(key, at: x) })
        for st in done { addBuiltSnowman(st) }
    }

    /// Three stacked balls come alive. At most `SnowYard.maxBuilt` rolled snowmen stand at once – the oldest
    /// one falls apart to make room.
    private func addBuiltSnowman(_ st: SnowYard.Stack) {
        let built = snowmen.indices.filter { snowmen[$0].userBuilt && snowmen[$0].phase == .standing }
        if built.count >= SnowYard.maxBuilt, let oldest = built.first { snowmen[oldest].life = 0 }
        var s = Snowman.built(radii: (st.balls[0], st.balls[1], st.balls[2]), x: st.x, baseY: st.baseY)
        s.hostKey = st.key
        s.hostRect = surfaceRect(st.key)
        s.offsetX = st.x - Float(s.hostRect?.minX ?? 0)
        s.userPlaced = true
        s.throwEvery = Float(cfg.throwEvery)
        s.temperature = Float(cfg.temperature)
        s.id = newSnowmanID()
        snowmen.append(s)
    }

    /// Another standing snowman within throwing range of snowman i.
    private func fightTarget(for i: Int) -> Int? {
        let me = snowmen[i]
        return snowmen.indices.filter { j in
            let o = snowmen[j]
            return j != i && o.phase == .standing && !o.hidden && !o.ghost && !o.carried && !o.falling && o.levels == 3
                && abs(o.anchorX - me.anchorX) > 30 && abs(o.anchorX - me.anchorX) < 700
        }.randomElement()
    }

    /// Snowman i throws at snowman v's head (v may duck).
    func throwSnowball(from i: Int, atSnowman v: Int) {
        guard snowmen.indices.contains(i), snowmen.indices.contains(v), let head = snowmen[v].ball(snowmen[v].levels - 1)
        else { return }
        throwSnowball(from: i, toward: SIMD2(head.x, head.y), victim: snowmen[v].id)
    }

    /// Snowman i throws a snowball that lands at `p` (the cursor, another snowman).
    private func throwSnowball(from i: Int, toward p: SIMD2<Float>, victim: Int = -1) {
        guard snowmen.indices.contains(i) else { return }
        let hand = snowmen[i].handPosition
        let dist = hypot(p.x - hand.x, p.y - hand.y)
        let T = max(0.5, min(1.4, dist / 420))
        let vx = (p.x - hand.x) / T
        let vy = (p.y - hand.y) / T + 0.5 * 600 * T
        snowballs.append(Snowball(x: hand.x, y: hand.y, vx: vx, vy: vy, t: 0, duration: T, target: -999, tx: p.x,
                                  victim: victim, thrower: snowmen[i].id))
        snowmen[i].armThrow = 1
        if victim >= 0, let v = snowmanIndex(victim) { snowmen[v].incoming(eta: T, chance: 0.35) }
    }

    /// ⌥-click: the user throws a snowball at snowman i. It comes in from the front – big, shrinking as it
    /// flies away from you – and hits where you clicked (unless the snowman ducks in time).
    func throwAtSnowman(_ i: Int, at point: CGPoint, duckChance: Float = 0.3) {
        guard hostsSnowman, snowmen.indices.contains(i), snowmen[i].phase == .standing || snowmen[i].phase == .dressing
        else { return }
        let p = SIMD2(Float(point.x), Float(point.y))
        let side: Float = p.x > W * 0.5 ? -1 : 1
        let start = SIMD2(p.x + side * 120, p.y + 70)
        let T: Float = 0.38
        let vx = (p.x - start.x) / T, vy = (p.y - start.y) / T + 0.5 * 600 * T
        snowballs.append(Snowball(x: start.x, y: start.y, vx: vx, vy: vy, t: 0, duration: T, target: -999, tx: p.x,
                                  victim: snowmen[i].id, thrower: -1, size: 34, endSize: 8))
        snowmen[i].incoming(eta: T, chance: duckChance)
    }

    /// A snowball aimed at a snowman arrives. Returns false when it missed (it ducked or moved) – the ball then
    /// flies on and splats where it falls.
    private func snowballLands(_ s: inout Snowball) -> Bool {
        guard let v = snowmanIndex(s.victim), let body = snowmen[v].bodyRect, !snowmen[v].carried else { return true }
        if body.insetBy(dx: 2, dy: -3).contains(CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))) {
            snowmen[v].hitBySnowball(at: SIMD2(s.x, s.y), dirX: s.vx >= 0 ? 1 : -1, debris: &debris)
            if cfg.snowballs {
                // It answers: the user gets one back at the cursor, another snowman at its head.
                snowmen[v].scheduleRetort(at: s.thrower, chance: s.thrower == -1 ? 0.75 : 0.55)
            }
            return true
        }
        s.victim = -1
        s.duration = s.t + 2.5
        s.floor = snowmen[v].baseY + 2
        return false
    }

    /// For the snapshot: a moment of a snowball fight.
    func demoFight(t: inout Double, dt: Double) {
        guard snowmen.count >= 3 else { return }
        for i in snowmen.indices { snowmen[i].outfit.hat = [.topHat, .beanie, .bucket][i % 3] }
        // Snowman 1 hits snowman 2: its hat flies.
        if let h = snowmen[2].ball(2) {
            snowmen[2].hitBySnowball(at: SIMD2(h.x, h.y), dirX: -1, debris: &debris, hatChance: 1)
        }
        for _ in 0..<9 { step(dt: dt, now: t); t += dt }
        // You throw at snowman 0, snowman 2 throws at snowman 1, which ducks.
        if let b = snowmen[0].ball(1) { throwAtSnowman(0, at: CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)), duckChance: 0) }
        snowmen[1].duckDelay = 0.02
        throwSnowball(from: 2, atSnowman: 1)
        for _ in 0..<7 { step(dt: dt, now: t); t += dt }
    }

    var yardSummary: String {
        "stacks \(yard.stacks.map { $0.balls.map { Int($0) } }), built \(snowmen.filter { $0.userBuilt }.count)"
    }

    // MARK: - Santa

    func launchSanta() {
        guard hostsSnowman, santa == nil else { return }
        let ltr = Bool.random()
        santa = Christmas.Sleigh(x: ltr ? -200 : W + 200, y: H * Float.random(in: 0.62...0.8), dir: ltr ? 1 : -1, t: 0)
    }

    private func stepSanta(dt: Float) {
        if cfg.christmas && cfg.santa && !cfg.paused && !fullscreen {
            nextSanta -= Double(dt)
            if nextSanta <= 0 {
                nextSanta = Double.random(in: 180...420)
                launchSanta()
            }
        }
        guard var sl = santa else { return }
        sl.t += dt
        sl.x += sl.dir * 190 * dt
        sl.y += cos(sl.t * 1.7) * 14 * dt
        // A trail of sparkles behind the sleigh.
        if debris.count < 9000 {
            for _ in 0..<3 {
                debris.append(Debris(x: sl.x - sl.dir * 60 + Float.random(in: -6...6), y: sl.y - 4 + Float.random(in: -5...5),
                                     vx: -sl.dir * Float.random(in: 10...40), vy: Float.random(in: -30...10),
                                     size: Float.random(in: 1.2...2.8), alpha: 1, lands: false, fade: 0.9))
            }
        }
        santa = (sl.x < -260 || sl.x > W + 260) ? nil : sl
    }

    // MARK: - Holidays [1.3 holidays]

    /// Ground under the presents and the sign: the top of the snow at the bottom, as for the tree.
    private func holidayGround(_ x: Float) -> Float { driftHeight(Self.groundKey, at: x) * 0.8 }
    private var holidayParty = false

    /// Calendar, party hats and sparklers, Santa's presents, fireworks (on the screen with the characters).
    private func stepHolidays(_ dt: Float) {
        holiday.refresh(Holidays.now())
        guard hostsSnowman else { return }
        holiday.tidyPresents()
        let party = holiday.partyTime(newYear: cfg.newYear)
        if party != holidayParty {                       // only on a change: a demo may set them too
            holidayParty = party
            seasonalHat = party ? .party : nil
            sparklers = party
        }
        if fullscreen {
            if holiday.isAlive { holiday.clearSky() }
            return
        }
        if cfg.christmas, let sl = santa, let spot = holidaySpot {
            holiday.santaOverhead(x: sl.x, y: sl.y, dir: sl.dir, dt: dt, treeX: spot.x, side: spot.side,
                                  scale: Float(cfg.treeSize), ground: holidayGround)
        }
        holiday.step(dt: dt, W: W, H: H, auto: !cfg.paused, newYear: cfg.newYear, ground: holidayGround, debris: &debris)
    }

    /// Called from `sync` (also while the display link sleeps): true when the sign needs redrawing.
    private func syncHolidays() -> Bool {
        holiday.refresh(Holidays.now())
        guard hostsSnowman, !fullscreen else { return false }
        let sign = cfg.countdownSign ? holiday.sign(christmas: cfg.christmas, newYear: cfg.newYear) : nil
        return sign != holiday.drawnSign
    }

    /// The settings' "Launch Fireworks Now": the big show with confetti and party hats, any day.
    func launchFireworks() {
        guard hostsSnowman, !fullscreen else { return }
        holiday.startShow(seconds: 120, extras: true, party: true, W: W, H: H)
    }

    /// Advent candles, the Christmas Eve star and the midnight flash, read by `Christmas` while drawing.
    private func prepareHolidayLights() {
        let on = cfg.christmas && hostsSnowman
        Christmas.advent = on ? holiday.info.advent : 0
        Christmas.starBoost = on && holiday.info.christmasEve ? 1.8 : 1
        Christmas.flash = hostsSnowman ? min(1, holiday.flash) : 0
    }

    /// Lights along the top edge of the frontmost window: the part not covered by windows in front of it
    /// or by menus, and not over the window buttons. None for a window right under the menu bar (zoomed).
    private func windowLightSpan() -> (left: Float, right: Float, top: Float, occluders: [CGRect])? {
        guard let r = activeRect?.standardized, r.width > 160, r.height > 60 else { return nil }
        let top = r.maxY
        guard top < size.height - max(menuBarHeight, safeTop) - 8, top > 60 else { return nil }
        let left = max(4, r.minX + 80), right = min(size.width - 4, r.maxX - 6)
        guard right - left > 50 else { return nil }
        var occ = localOcc
        if let i = windowRects.firstIndex(where: { abs($0.rect.minX - r.minX) < 2 && abs($0.rect.maxY - r.maxY) < 2
                                                  && abs($0.rect.width - r.width) < 2 }) {
            occ += windowRects[..<i].map(\.rect)
        }
        return (Float(left), Float(right), Float(top), occ)
    }

    /// [1.3 lights] Where the decor wreath hangs on the front window (the same test as in `buildDecor`), so the
    /// window lights leave a gap for it.
    private func windowWreathX(_ span: (left: Float, right: Float, top: Float, occluders: [CGRect])) -> Float? {
        guard decorOn, let r = activeRect?.standardized, r.width >= 300 else { return nil }
        let rr: Float = 9, cx = Float(r.midX), cy = span.top - 5 - rr
        let box = CGRect(x: CGFloat(cx - rr - 5), y: CGFloat(cy - rr - 5), width: CGFloat(2 * rr + 10),
                         height: CGFloat(span.top - cy + rr + 6))
        return span.occluders.contains(where: { $0.intersects(box) }) ? nil : cx
    }

    private func buildHolidays(into out: inout [Vertex], cached: Bool, style: Christmas.LightStyle) {
        if cfg.christmas && cfg.windowLights, let span = windowLightSpan() {
            let gap = windowWreathX(span)                                    // [1.3 lights]
            let y = CGFloat(span.top - 7)
            let hidden = { (x: Float) -> Bool in
                span.occluders.contains { CGFloat(x) >= $0.minX && CGFloat(x) <= $0.maxX && y >= $0.minY && y <= $0.maxY }
            }
            if cached {
                Christmas.garland(&out, cache: &windowLightCache, width: span.right, y: span.top, t: drawTime, style: style,
                                  left: span.left, sag: 0.55, gap: gap, occluders: span.occluders, skip: hidden)
            } else {
                Christmas.garland(&out, width: span.right, y: span.top, t: drawTime, style: style, left: span.left,
                                  sag: 0.55, gap: gap, skip: hidden)
            }
        }
        guard hostsSnowman, let spot = holidaySpot else { return }
        let s = Float(cfg.treeSize)
        if !holiday.presents.isEmpty { holiday.buildPresents(into: &out, ground: holidayGround, alpha: treeGhost ? 0.22 : 1) }
        let sign = cfg.countdownSign ? holiday.sign(christmas: cfg.christmas, newYear: cfg.newYear) : nil
        if cached { holiday.drawnSign = sign }
        guard let items = sign else { return }
        let x = treePos != nil ? min(max(spot.x + spot.side * 122 * s, 32 * s + 4), W - 32 * s - 4) : spot.x
        let ground = holidayGround(x)
        let box = CGRect(x: CGFloat(x - 32 * s), y: CGFloat(ground), width: CGFloat(64 * s), height: CGFloat(36 * s))
        guard !localOcc.contains(where: { $0.intersects(box) }) else { return }
        let ghost = cfg.snowmanGhost && windowRects.contains { $0.rect.intersects(box.insetBy(dx: 6, dy: 4)) }
        HolidayScene.buildSign(into: &out, items: items, x: x, ground: ground, scale: s, t: drawTime, alpha: ghost ? 0.22 : 1)
    }

    // MARK: - Christmas decorations [1.3 decor]

    private var decorOn: Bool { cfg.christmas && cfg.christmasDecor }
    private var goldenFlakesOn: Bool { cfg.christmas && cfg.goldenFlakes && !fullscreen }

    /// Where the gingerbread house stands: on the other side of the Dock from the tree (past any snowmen
    /// lined up on the ground), and which stretches of the bottom stay free of candy canes.
    private func syncDecor() {
        housePos = nil
        decorBlocked = []
        guard decorOn, let spot = holidaySpot else { return }
        let s = Float(cfg.treeSize), ds = Float(cfg.decorSize)
        let half = 30 * ds
        var x: Float
        if let d = layoutDock, d.minY < size.height / 2 {
            let a = avoidLocal ?? d
            let margin: Float = (dockGuessed ? 30 : 0) + 26
            if spot.x < Float(d.midX) {
                x = Float(a.maxX) + margin + half
                if cfg.snowman {
                    let sz = Float(cfg.snowmanSize)
                    for i in 0..<max(1, min(6, Int(cfg.snowmanCount.rounded()))) {
                        let sl = slot(i, size: sz)
                        if sl.key == Self.groundKey { x = max(x, sl.x + 34 * sz + half) }
                    }
                }
            } else {
                x = Float(a.minX) - margin - half
            }
            decorBlocked.append(Float(a.minX) - 16...Float(a.maxX) + 16)
        } else {
            x = W - spot.x
        }
        // snowmen standing on the ground keep their spot free of candy canes and saplings
        if cfg.snowman {
            let sz = Float(cfg.snowmanSize)
            for i in 0..<max(1, min(6, Int(cfg.snowmanCount.rounded()))) {
                let sl = slot(i, size: sz)
                if sl.key == Self.groundKey { decorBlocked.append(sl.x - 28 * sz...sl.x + 28 * sz) }
            }
        }
        // the tree, the presents and the sign on the tree's side
        let treeHalf = 56 * s
        decorBlocked.append(spot.x - treeHalf...spot.x + treeHalf)
        let far = spot.x + spot.side * 160 * s
        decorBlocked.append(min(spot.x, far)...max(spot.x, far))
        if x - half >= 4, x + half <= W - 4, !decorBlocked.contains(where: { $0.overlaps(x - half...x + half) }) {
            let y = driftHeight(Self.groundKey, at: x) * 0.8
            let r = ChristmasDecor.houseRect(x: x, baseY: y, scale: ds)
            if !localOcc.contains(where: { $0.intersects(r) }) {
                housePos = (x, y)
                houseGhost = cfg.snowmanGhost && windowRects.contains { $0.rect.intersects(r.insetBy(dx: 8, dy: 6)) }
                decorBlocked.append(x - half - 6...x + half + 6)
            }
        }
    }

    /// Candy canes and saplings stuck in the bottom snow, drawn before the drift so it buries their feet.
    /// They sink in as the snow piles up, about two thirds of each one keep showing.
    private func buildBuriedDecor(into out: inout [Vertex]) {
        guard decorOn, let ground = piles[Self.groundKey] else { return }
        let s = Float(cfg.decorSize) * 0.95
        for it in decorItems {
            let x = it.u * W, hw = ChristmasDecor.halfWidth(it, scale: s)
            guard x - hw > 6, x + hw < W - 6, !decorBlocked.contains(where: { $0.overlaps(x - hw...x + hw) }) else { continue }
            let b = Int(x / Self.binW)
            guard ground.visible.indices.contains(b), ground.visible[b] else { continue }
            let h = ChristmasDecor.height(it, scale: s)
            let y = max(0, driftHeight(Self.groundKey, at: x) - 0.34 * h)
            if localOcc.contains(where: { $0.contains(CGPoint(x: CGFloat(x), y: CGFloat(y + h * 0.7))) }) { continue }
            let ghost = cfg.snowmanGhost && windowRects.contains {
                $0.rect.intersects(CGRect(x: CGFloat(x - hw), y: CGFloat(y), width: CGFloat(2 * hw), height: CGFloat(h)))
            }
            ChristmasDecor.item(&out, it, x: x, baseY: y, scale: s, alpha: ghost ? 0.22 : 1)
        }
    }

    /// The gingerbread house by the Dock and the wreath on the front window.
    private func buildDecor(into out: inout [Vertex]) {
        guard decorOn else { return }
        if hostsSnowman, let p = housePos {
            let info = holiday.info
            let wreath = info.giftDays && !(info.day == 24 && info.hour < 16)
            ChristmasDecor.house(&out, x: p.x, baseY: p.y, scale: Float(cfg.decorSize), t: drawTime, wind: wind,
                                 wreath: wreath, alpha: houseGhost ? 0.22 : 1)
        }
        // A wreath in the middle of the front window's top edge (where it fits and nothing covers it).
        if let span = windowLightSpan(), let r = activeRect?.standardized, r.width >= 300 {
            let rr: Float = 8.5, cx = Float(r.midX), cy = span.top - 3.5 - rr      // hangs high: covers little of the title
            let box = CGRect(x: CGFloat(cx - rr - 5), y: CGFloat(cy - rr - 5), width: CGFloat(2 * rr + 10),
                             height: CGFloat(span.top - cy + rr + 6))
            if !span.occluders.contains(where: { $0.intersects(box) }) {
                ChristmasDecor.wreath(&out, cx: cx, cy: cy, r: rr, alpha: 1, hangFrom: span.top - 1)
            }
        }
    }

    /// A few flakes fall as golden stars (the same ones `buildParticles` leaves out).
    private func buildGoldenFlakes(into out: inout [Vertex]) {
        guard goldenFlakesOn else { return }
        let calm = cfg.calmActive ? activeRect?.standardized : nil
        var golden = 0
        for f in flakes where ChristmasDecor.isGolden(f) {
            if golden >= ChristmasDecor.maxGoldenFlakes { break }
            golden += 1
            let a = calm.map { $0.contains(CGPoint(x: CGFloat(f.x), y: CGFloat(f.y))) } == true ? f.alpha * 0.3 : f.alpha
            ChristmasDecor.goldenFlake(&out, x: f.x, y: f.y, size: f.size, alpha: a, t: drawTime, phase: f.phase)
        }
    }

    // MARK: - Output for the renderer

    /// Animation clock for drawing – wrapped so Float stays precise after days of uptime.
    private var drawTime: Float { Float(time.truncatingRemainder(dividingBy: 3600)) }

    func buildParticles(into out: inout [Particle]) {
        let t = drawTime
        out.reserveCapacity(out.count + flakes.count + debris.count + snowballs.count)
        // Calm over the active window: flakes there fade to a light dusting (soft 40-pt edge).
        let calm = cfg.calmActive && !fullscreen ? activeRect.map { $0.standardized } : nil
        let hasCalm = calm.map { !$0.isEmpty } ?? false
        let cx0 = Float(calm?.minX ?? 0), cx1 = Float(calm?.maxX ?? 0)
        let cy0 = Float(calm?.minY ?? 0), cy1 = Float(calm?.maxY ?? 0)
        let fade: Float = fullscreen ? Float(cfg.fullscreenSnow) : 1
        let goldOn = goldenFlakesOn; var golden = 0          // [1.3 decor] golden star flakes are drawn as mesh
        for f in flakes {
            if goldOn && ChristmasDecor.isGolden(f) && golden < ChristmasDecor.maxGoldenFlakes { golden += 1; continue }
            var a = f.alpha * fade, sz = f.size
            if hasCalm, f.x >= cx0, f.x < cx1, f.y >= cy0, f.y < cy1 {
                let edge = min(f.x - cx0, cx1 - f.x, f.y - cy0, cy1 - f.y)
                let k = min(1, edge / 40)
                a *= 1 - 0.78 * k
                sz *= 1 - 0.25 * k
            }
            if f.sparkle {
                let tw = 0.55 + 0.45 * sin(t * 9 + f.phase * 3)
                out.append(Particle(x: f.x, y: f.y, size: sz * (0.9 + 0.5 * tw), alpha: min(1, a * (0.5 + tw))))
            } else {
                out.append(Particle(x: f.x, y: f.y, size: sz, alpha: a))
            }
        }
        for d in debris {
            // Landing clumps are drawn solid; powder stays soft.
            out.append(Particle(x: d.x, y: d.y, size: d.lands && d.size > 2.4 ? -d.size : d.size, alpha: max(0, d.alpha) * fade))
        }
        for s in snowballs {
            let sz = s.size + (s.endSize - s.size) * min(1, s.t / max(0.01, s.duration))
            out.append(Particle(x: s.x, y: s.y, size: -sz, alpha: 1))
        }
        for d in blownPowder { out.append(Particle(x: d.x, y: d.y, size: d.size, alpha: max(0, d.alpha))) }   // [1.3 weather]
    }

    func buildMesh(into out: inout [Vertex]) { buildMesh(into: &out, cached: true) }

    /// For tests: the same mesh built without the menu-bar / garland / tree caches (and without
    /// touching them). Must be identical to `buildMesh` byte for byte.
    func buildMeshUncached(into out: inout [Vertex]) { buildMesh(into: &out, cached: false) }

    private func buildMesh(into out: inout [Vertex], cached: Bool) {
        Mesh.tint = tint
        if fullscreen {
            // Over a full-screen app only the icicles along the top stay.
            if cfg.onMenuBar && menuBarHeight > 0 { buildMenuBar(into: &out, cached: cached) }
            return
        }
        if cfg.frost { buildFrost(into: &out) }
        if hostsSnowman { holiday.buildSky(into: &out, t: drawTime) }        // [1.3 holidays] fireworks
        if hostsSnowman { buildBuriedDecor(into: &out) }                    // [1.3 decor] behind the bottom drift
        for p in landables {
            if p.dirty || p.iceDirty { rebuildMesh(p) }
            out.append(contentsOf: p.mesh)
        }
        if cfg.onMenuBar && menuBarHeight > 0 { buildMenuBar(into: &out, cached: cached) }
        for s in shards { Mesh.icicle(&out, x: s.x, top: s.y, len: s.len, width: s.width, alpha: 0.9) }
        let style = Christmas.LightStyle(rawValue: cfg.lightStyle) ?? .colorful
        Christmas.bulbScale = Float(cfg.lightSize)
        Christmas.glow = Float(cfg.lightGlow)
        prepareHolidayLights()                                               // [1.3 holidays]
        let menuY = H - Float(menuBarHeight)
        if cfg.christmas && cfg.christmasGarland && menuBarHeight > 0 {
            if cached {
                Christmas.garland(&out, cache: &garlandCache, width: W, y: menuY, t: drawTime, style: style,
                                  occluders: localOcc) { x in self.underMenu(x) }
            } else {
                Christmas.garland(&out, width: W, y: menuY, t: drawTime, style: style) { x in self.underMenu(x) }
            }
        }
        if hostsSnowman, let p = treePos, !treeHidden {
            if cached {
                Christmas.tree(&out, cache: &treeCache, x: p.x, baseY: p.y, scale: Float(cfg.treeSize), t: drawTime,
                               style: style, alpha: treeGhost ? 0.22 : 1, snow: treeSnow)
            } else {
                Christmas.tree(&out, x: p.x, baseY: p.y, scale: Float(cfg.treeSize), t: drawTime, style: style,
                               alpha: treeGhost ? 0.22 : 1, snow: treeSnow)
            }
        }
        buildHolidays(into: &out, cached: cached, style: style)            // [1.3 holidays]
        buildDecor(into: &out)                                             // [1.3 decor] house, window wreath
        if hostsSnowman { yard.build(into: &out) }        // [1.3 snowmen] rolled balls
        if hostsSnowman { for s in snowmen where !s.hidden { s.build(into: &out) } }
        for s in skiers where !localOcc.contains(where: { $0.contains(CGPoint(x: CGFloat(s.x), y: CGFloat(s.y + 10))) }) {
            s.build(into: &out, t: drawTime)
        }
        for p in penguins where !localOcc.contains(where: { $0.contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y + 10))) }) {
            p.build(into: &out, t: drawTime)        // [1.3 penguin]
        }
        for r in reindeer where !localOcc.contains(where: { $0.contains(CGPoint(x: CGFloat(r.x), y: CGFloat(r.y + 12))) }) {
            r.build(into: &out, t: drawTime)        // [1.3 reindeer]
        }
        if let sl = santa { Christmas.sleigh(&out, sl, t: drawTime) }
        if plow.visible { plow.build(into: &out, t: drawTime) }
        if hostsSnowman { holiday.buildConfetti(into: &out) }               // [1.3 holidays]
        buildGoldenFlakes(into: &out)                                       // [1.3 decor]
        if let m = shovelAt {
            if aiming(at: m) { SnowYard.aimBall(&out, at: m, t: drawTime) }      // [1.3 snowmen]
            else { Mesh.shovel(&out, at: m, digging: shovelDigging) }
        }
    }

    /// Is something (an open menu, a popover) covering the strip right under the menu bar at x?
    private func underMenu(_ x: Float) -> Bool {
        let y = size.height - menuBarHeight - 6
        return localOcc.contains { CGFloat(x) >= $0.minX && CGFloat(x) <= $0.maxX && y >= $0.minY && y <= $0.maxY }
    }

    private var shovelDigging: Bool {
        guard let m = shovelAt, let last = lastMouse else { return false }
        return abs(m.x - last.x) + abs(m.y - last.y) > 0.5
    }

    private func rebuildMesh(_ p: Pile) {
        p.mesh.removeAll(keepingCapacity: true)
        let n = p.bins.count
        let base = Float(p.rect.maxY) - 0.5
        let x0 = Float(p.rect.minX)
        let bw = Self.binW
        let lim = p.limit.count == n ? p.limit : []
        func h(_ i: Int) -> Float {
            let k = max(0, min(n - 1, i))
            return lim.isEmpty ? p.bins[k] : min(p.bins[k], lim[k])
        }
        // Snow texture anchored to the pile, so it travels with a dragged window.
        let mat = Mesh.snowMaterial(kind: 1, anchor: (x0, base))
        var i = 0
        while i < n {
            if !p.visible[i] || p.bins[i] < 0.25 { i += 1; continue }
            // Smooth top: height at a bin boundary = average of the neighbours.
            let l = x0 + Float(i) * bw, r = l + bw
            let hl = (i > 0 && p.visible[i - 1]) ? (h(i - 1) + h(i)) * 0.5 : 0
            let hr = (i < n - 1 && p.visible[i + 1]) ? (h(i) + h(i + 1)) * 0.5 : 0
            let hm = h(i)
            let m = l + bw * 0.5
            Mesh.snowColumn(&p.mesh, l: l, m: m, r: r, base: base, hl: hl, hm: hm, hr: hr, material: mat)
            i += 1
        }
        if p.kind == .window && p.frost > 0.01 { buildWindowFrost(p) }
        if p.kind == .window {
            for (k, ic) in p.icicles.enumerated() where ic.len > 0.6 && k < p.icicleVisible.count && p.icicleVisible[k] {
                Mesh.icicle(&p.mesh, x: x0 + ic.x, top: Float(p.rect.minY) + 0.5, len: ic.len,
                            width: ic.width * iceWidth(ic.len), alpha: 0.85)
            }
        }
        p.dirty = false
        p.iceDirty = false
    }

    /// Frost creeping into a window from its corners, with a few ice needles.
    private func buildWindowFrost(_ p: Pile) {
        let r = p.rect
        let f = p.frost
        let radius = Float(min(r.width, r.height)) * 0.08 + 70 * f
        let a = 0.5 * f
        let ice: RGBA = (0.74 * tint.0, 0.86 * tint.1, 1 * tint.2, a)
        let clear: RGBA = (ice.0, ice.1, ice.2, 0)
        var rng = p.frostSeed
        func rnd() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(rng >> 40) / Float(1 << 24)
        }
        let corners: [(CGFloat, CGFloat, Float)] = [(r.minX, r.minY, 0), (r.maxX, r.minY, .pi / 2),
                                                    (r.maxX, r.maxY, .pi), (r.minX, r.maxY, 1.5 * .pi)]
        for (cx, cy, start) in corners {
            let ix = cx == r.minX ? cx + 3 : cx - 3, iy = cy == r.minY ? cy + 3 : cy - 3
            guard ix >= 0, ix <= size.width, iy >= 0, iy <= size.height,
                  !p.occluders.contains(where: { $0.contains(CGPoint(x: ix, y: iy)) }) else { continue }
            // Corner glow
            Mesh.sector(&p.mesh, cx: Float(cx), cy: Float(cy), r: radius, from: start, to: start + .pi / 2,
                        center: ice, rim: clear)
            // Ice needles
            let needles = 3 + Int(f * 6)
            for _ in 0..<needles {
                let ang = start + 0.15 + rnd() * (.pi / 2 - 0.3)
                let len = radius * (0.5 + 0.7 * rnd())
                let x0 = Float(cx), y0 = Float(cy)
                let x1 = x0 + cos(ang) * len, y1 = y0 + sin(ang) * len
                Mesh.line(&p.mesh, (x0, y0), (x1, y1), width: 1.1, color: (0.80, 0.90, 1, 0.75 * f))
                let mx = x0 + (x1 - x0) * 0.6, my = y0 + (y1 - y0) * 0.6
                let side = ang + (rnd() > 0.5 ? 0.6 : -0.6)
                Mesh.line(&p.mesh, (mx, my), (mx + cos(side) * len * 0.3, my + sin(side) * len * 0.3),
                          width: 0.9, color: (0.80, 0.90, 1, 0.6 * f))
            }
        }
    }

    private func buildFrost(into out: inout [Vertex]) {
        let w = W, h = H, e: Float = 46
        let ice: RGBA = (0.86 * tint.0, 0.94 * tint.1, 1 * tint.2, 0.42)
        let clear: RGBA = (ice.0, ice.1, ice.2, 0)
        Mesh.quad(&out, x: 0, y: 0, w: w, h: e, bl: ice, br: ice, tr: clear, tl: clear)
        Mesh.quad(&out, x: 0, y: h - e, w: w, h: e, bl: clear, br: clear, tr: ice, tl: ice)
        Mesh.quad(&out, x: 0, y: 0, w: e, h: h, bl: ice, br: clear, tr: clear, tl: ice)
        Mesh.quad(&out, x: w - e, y: 0, w: e, h: h, bl: clear, br: ice, tr: ice, tl: clear)
    }

    /// Powder and icicles along the bottom edge of the menu bar. The cached copy is rebuilt when an
    /// icicle or the melt changes it (≤ 4× a second) or a menu opens; powder that grows in a bin that
    /// already shows only rewrites that bin's 12 vertices.
    private func buildMenuBar(into out: inout [Vertex], cached: Bool) {
        guard cached else { _ = buildMenuBarMesh(into: &out); return }
        if menuMeshValid, menuMeshKey.bar == menuBarHeight, menuMeshKey.occ == localOcc {
            let y = H - Float(menuBarHeight)
            let mat = Mesh.snowMaterial(kind: 1, anchor: (0, y))
            for b in menuGrown where menuSlot[b] < 0 {
                // A new bin shows up (or stays hidden under a menu): rebuild in order.
                if menuSnow[b] > 0.2 && !underMenu(Float(b) * Self.binW) { menuMeshValid = false; break }
            }
            if menuMeshValid {
                for b in menuGrown where menuSlot[b] >= 0 {
                    menuBlock.removeAll(keepingCapacity: true)
                    let h = menuSnow[b]
                    Mesh.snowRect(&menuBlock, x: Float(b) * Self.binW, y: y - h * 0.5, w: Self.binW, h: h, material: mat)
                    let o = menuSlot[b]
                    for k in menuBlock.indices { menuMesh[o + k] = menuBlock[k] }
                }
            }
        }
        if !menuMeshValid || menuMeshKey.bar != menuBarHeight || menuMeshKey.occ != localOcc {
            menuMesh.removeAll(keepingCapacity: true)
            menuSlot = buildMenuBarMesh(into: &menuMesh)
            menuMeshKey = (menuBarHeight, localOcc)
            menuMeshValid = true
        }
        menuGrown.removeAll(keepingCapacity: true)
        out.append(contentsOf: menuMesh)
    }

    /// Returns, per bin, the first vertex of its block (-1 = not drawn).
    private func buildMenuBarMesh(into out: inout [Vertex]) -> [Int] {
        let y = H - Float(menuBarHeight)
        let bw = Self.binW
        let mat = Mesh.snowMaterial(kind: 1, anchor: (0, y))
        var slots = Array(repeating: -1, count: menuSnow.count)
        for (i, h) in menuSnow.enumerated() where h > 0.2 {
            let l = Float(i) * bw
            if underMenu(l) { continue }
            slots[i] = out.count
            Mesh.snowRect(&out, x: l, y: y - h * 0.5, w: bw, h: h, material: mat)
        }
        for ic in menuIcicles where ic.len > 0.6 && !underMenu(ic.x) {
            Mesh.icicle(&out, x: ic.x, top: y, len: ic.len, width: ic.width * iceWidth(ic.len), alpha: 0.85)
        }
        return slots
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - [1.3 weather] Living weather

extension Simulation {
    /// Eases the living weather's steady wind and gusts into `wind` (the app passes a new value a few times
    /// a second) and, in gusts, blows a little powder off the drift crests – soft, short-lived and never
    /// landing, at most ~400 grains, so it costs about as much as a few hundred more flakes.
    private func stepWeather(dt: Float) {
        let goal = Float(cfg.weatherWind)
        weatherWind += (goal - weatherWind) * min(1, dt * 1.5)
        if goal == 0 && abs(weatherWind) < 0.05 { weatherWind = 0 }
        wind += weatherWind
        if fullscreen {
            if !blownPowder.isEmpty { blownPowder.removeAll() }
            return
        }
        var i = 0
        while i < blownPowder.count {
            var d = blownPowder[i]
            d.vx += (wind * 0.8 - d.vx) * min(1, 1.5 * dt)
            d.vy -= 90 * dt
            d.x += d.vx * dt
            d.y += d.vy * dt
            d.alpha -= d.fade * dt
            if d.alpha <= 0 || d.y < -10 {
                blownPowder.swapAt(i, blownPowder.count - 1)
                blownPowder.removeLast()
                continue
            }
            blownPowder[i] = d
            i += 1
        }
        let amount = Float(cfg.weatherPowder)
        guard amount > 0.05, !cfg.paused, abs(wind) > 25, !landables.isEmpty, dt > 0 else { return }
        // Puffs per second grow with the gust and the screen width; each puff is a short plume of grains.
        let expected = amount * 22 * W / 1000 * dt
        var count = Int(expected)
        if Float.random(in: 0..<1) < expected - Float(count) { count += 1 }
        guard count > 0 else { return }
        var total = 0
        for p in landables { total += p.bins.count }
        guard total > 0 else { return }
        let dir = wind > 0 ? 1 : -1
        for _ in 0..<count where blownPowder.count < 400 {
            // A few tries for a bin on a crest: high enough, visible and not lower than its downwind neighbor.
            for _ in 0..<4 {
                var k = Int.random(in: 0..<total)
                var pile: Pile?
                for p in landables {
                    if k < p.bins.count { pile = p; break }
                    k -= p.bins.count
                }
                guard let p = pile, k > 0, k < p.bins.count - 1, p.visible[k] else { continue }
                let limited = p.limit.count == p.bins.count
                func h(_ b: Int) -> Float { limited ? min(p.bins[b], p.limit[b]) : p.bins[b] }
                let top = h(k)
                guard top > 2.5, top >= h(k + dir) - 0.1 else { continue }
                let x0 = Float(p.rect.minX) + (Float(k) + 0.5) * Self.binW
                let y0 = Float(p.rect.maxY) + top - 1
                for _ in 0..<Int.random(in: 8...14) {
                    let lag = Float.random(in: 0...1)          // grains further along the plume rise and thin out
                    blownPowder.append(Debris(
                        x: x0 + Float(dir) * lag * Float.random(in: 4...30), y: y0 + lag * Float.random(in: 0...9),
                        vx: wind * Float.random(in: 0.5...0.7), vy: Float.random(in: 4...24),
                        size: Float.random(in: 1.7...3.2), alpha: Float.random(in: 0.45...0.75) * (1 - 0.4 * lag),
                        lands: false, fade: Float.random(in: 0.55...0.85)))
                }
                break
            }
        }
    }
}
