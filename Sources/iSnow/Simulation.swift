import CoreGraphics
import Foundation
import QuartzCore

/// Triangle mesh vertex (drifts, icicles, snowman) – 24 B, matches the shader.
struct Vertex { var x, y, r, g, b, a: Float }
/// Round particle instance (flake, snow chunk, snowball) – 16 B.
struct Particle { var x, y, size, alpha: Float }

enum SurfaceKind { case window, dock, icon, ground }

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
    var lastSeen: Double = 0         // time of the last sync (for window speed)

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
    let menuBarHeight: CGFloat
    let dockBottomGuess: CGFloat         // top edge of a bottom Dock, derived from visibleFrame
    var hostsSnowman: Bool

    private(set) var flakes: [Flake] = []
    private var debris: [Debris] = []
    private var shards: [Shard] = []
    private var snowballs: [Snowball] = []
    private var piles: [Int: Pile] = [:]
    private var landables: [Pile] = []
    private var columns: [[Pile]] = []          // landables bucketed by 32-pt screen column
    private static let columnW: Float = 32
    private var menuIcicles: [Icicle] = []
    private var menuIceDirty = true
    private var menuSnow: [Float] = []
    var snowmen: [Snowman] = []
    private var windowRects: [(key: Int, rect: CGRect)] = []   // front to back
    private var dockLocal: CGRect?
    private var treePos: (x: Float, y: Float)?
    private var treeGhost = false

    private var time: Double = 0
    private var spawnAcc: Double = 0
    private var wind: Float = 0
    private var meshTimer: Double = 0
    private var cfg = SimConfig()
    private var fullscreen = false
    private var lastMouse: SIMD2<Float>?
    private var shovelAt: SIMD2<Float>?        // cursor position while the ⌥ shovel is active
    /// True when a window moved during the last sync (the app then polls faster).
    private(set) var windowMoving = false
    private var tint: (Float, Float, Float) = (1, 1, 1)

    init(screenFrame: CGRect, visibleFrame: CGRect, hostsSnowman: Bool) {
        origin = screenFrame.origin
        size = screenFrame.size
        menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        dockBottomGuess = max(0, visibleFrame.minY - screenFrame.minY)
        self.hostsSnowman = hostsSnowman
        let n = Int(Float(size.width) / Self.binW)
        menuSnow = Array(repeating: 0, count: n)
    }

    var W: Float { Float(size.width) }
    var H: Float { Float(size.height) }

    // MARK: - Syncing with the environment

    /// Returns true when something changed and a redraw is needed.
    @discardableResult
    func sync(windows: [TrackedWindow], occluders: [CGRect], dock: CGRect?, icons: [CGRect],
              now: Double, cfg: SimConfig) -> Bool {
        let tintChanged = cfg.tint != self.cfg.tint
        let capsChanged = cfg.windowDepth != self.cfg.windowDepth || cfg.groundDepth != self.cfg.groundDepth
            || cfg.unlimitedDrifts != self.cfg.unlimitedDrifts
        self.cfg = cfg
        tint = (Float(cfg.tint[safe: 0] ?? 1), Float(cfg.tint[safe: 1] ?? 1), Float(cfg.tint[safe: 2] ?? 1))
        var changed = tintChanged || capsChanged
        let bounds = CGRect(origin: .zero, size: size)
        let wasFull = fullscreen
        fullscreen = cfg.pauseFullscreen && windows.contains { w in
            let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            return r.minX <= 1 && r.minY <= 1 && r.maxX >= size.width - 1 && r.maxY >= size.height - 1
        }
        if fullscreen != wasFull { changed = true }
        windowMoving = false
        var seen = Set<Int>()
        var order: [Pile] = []
        let localOcc = occluders.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }

        func upsert(key: Int, kind: SurfaceKind, rect r: CGRect) -> Pile {
            seen.insert(key)
            if let p = piles[key] {
                let dx = Float(r.minX - p.rect.minX), dy = Float(r.minY - p.rect.minY)
                let resized = abs(p.rect.width - r.width) > 0.5 || abs(p.rect.height - r.height) > 0.5
                if abs(dx) > 0.5 || abs(dy) > 0.5 || resized {
                    let dt = Float(max(1.0 / 60, min(0.5, now - p.lastSeen)))
                    let vel = SIMD2(dx / dt, dy / dt)
                    let dist = (dx * dx + dy * dy).squareRoot()
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
                p.occluders = front
                order.append(p)
            }
            front.append(r)
            rects.append((w.id, r))
        }
        windowRects = rects
        // Dock – its drift reaches above the Dock, so windows hide it (e.g. a zoomed window).
        dockLocal = nil
        if let d = dock?.offsetBy(dx: -origin.x, dy: -origin.y), d.intersects(bounds), d.maxY > 6 {
            dockLocal = d
            if cfg.onDock {
                let p = upsert(key: Self.dockKey, kind: .dock, rect: d)
                if updateVisibility(p, occluders: front) { changed = true }
                order.append(p)
            }
        }
        // Desktop icons – they sit below all windows.
        if cfg.onIcons {
            for f in icons {
                let r = f.offsetBy(dx: -origin.x, dy: -origin.y)
                guard bounds.contains(r) else { continue }
                let key = 0x4000_0000 + Int(r.minX / 4) * 8192 + Int(r.minY / 4)
                let p = upsert(key: key, kind: .icon, rect: r)
                if updateVisibility(p, occluders: front) { changed = true }
                order.append(p)
            }
        }
        // Bottom edge of the screen
        let g = upsert(key: Self.groundKey, kind: .ground, rect: CGRect(x: 0, y: -1, width: size.width, height: 1))
        if updateGroundVisibility(g, dock: dockLocal, windows: front) { changed = true }
        order.append(g)

        for (k, p) in piles where !seen.contains(k) {
            shake(p, push: 0)
            piles[k] = nil
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
        return changed
    }

    private func capFor(_ p: Pile) -> Float {
        let roof = max(0, H - Float(menuBarHeight) - Float(p.rect.maxY) - 2)   // room up to the menu bar
        if cfg.unlimitedDrifts {
            switch p.kind {
            case .window, .dock: return roof
            case .ground: return max(0, roof - 30)
            case .icon: return min(Float(cfg.windowDepth) * 0.4, 22)
            }
        }
        let w = Float(cfg.windowDepth)
        switch p.kind {
        case .window: return w
        case .dock: return min(w * 0.55, 34)
        case .icon: return min(w * 0.4, 22)
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
        for k in max(0, b - 2)...min(p.bins.count - 1, b + 2) { sum += p.bins[k]; n += 1 }
        return sum / n
    }

    private func updateVisibility(_ p: Pile, occluders: [CGRect]) -> Bool {
        let n = p.bins.count
        let top = p.rect.maxY
        let margin = p.kind == .window ? 4 : (p.kind == .dock ? 3 : 1)
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

    /// The bottom drift lies behind windows: a window reaching the bottom edge hides it.
    private func updateGroundVisibility(_ p: Pile, dock: CGRect?, windows: [CGRect]) -> Bool {
        var changed = false
        for i in 0..<p.bins.count {
            let x = (CGFloat(i) + 0.5) * CGFloat(Self.binW)
            var v = true
            if let d = dock, d.minY < 12, x >= d.minX - 4, x <= d.maxX + 4 { v = false }
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
        wind = Float(cfg.wind) * Float(sin(time * 0.071) * 16 + sin(time * 0.23) * 6 + sin(time * 0.017) * 12)

        if !cfg.paused && !fullscreen {
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
            if shovel { stepShovel(m, dt: fdt) }
            stepMouse(m, dt: fdt)
        } else { lastMouse = nil }
        let acc = Float(cfg.accumulation)
        let temp = Float(cfg.temperature)
        let sleet = temp > 4          // too warm: wet flakes melt on contact

        // Flakes
        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            let oy = f.y
            f.phase += f.freq * fdt
            f.x += (wind * (0.35 + f.depth) + sin(f.phase) * f.amp + f.vx) * fdt
            f.y -= f.vy * fdt
            if f.vx != 0 { f.vx *= max(0, 1 - 2.5 * fdt); if abs(f.vx) < 1 { f.vx = 0 } }
            if f.depth > 0.3, !sleet, let (p, b) = hit(x: f.x, oldY: oy, newY: f.y) {
                deposit(p, b, 0.35 * acc * (0.6 + f.depth))
                flakes.swapAt(i, flakes.count - 1); flakes.removeLast(); continue
            }
            if cfg.onMenuBar, f.depth > 0.6, oy > H - Float(menuBarHeight), f.y <= H - Float(menuBarHeight) {
                // Powder snow along the bottom edge of the menu bar
                let b = Int(f.x / Self.binW)
                if b >= 0 && b < menuSnow.count && menuSnow[b] < 2.2 { menuSnow[b] += 0.12; menuIceDirty = true }
            }
            if f.y < -10 { flakes.swapAt(i, flakes.count - 1); flakes.removeLast(); continue }
            if f.x < -30 { f.x += W + 60 } else if f.x > W + 30 { f.x -= W + 60 }
            flakes[i] = f
            i += 1
        }

        // Falling snow chunks
        i = 0
        while i < debris.count {
            var d = debris[i]
            let oy = d.y
            d.vy -= Self.gravity * fdt
            d.vx *= (1 - 0.8 * fdt)
            d.x += d.vx * fdt
            d.y += d.vy * fdt
            if d.lands, d.vy < 0, let (p, b) = hit(x: d.x, oldY: oy, newY: d.y) {
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
            if s.t >= s.duration {
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
            if cfg.meltRate > 0 {
                let m = cfg.meltRate / 60 * tick
                for p in landables {
                    var any = false
                    for k in p.bins.indices where p.bins[k] > 0 { p.bins[k] = max(0, p.bins[k] - m); any = true }
                    if any { p.dirty = true }
                }
                for k in menuSnow.indices where menuSnow[k] > 0 { menuSnow[k] = max(0, menuSnow[k] - m * 0.2) }
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
                    // Thaw: icicles shrink and eventually disappear.
                    if !p.icicles.isEmpty {
                        for k in p.icicles.indices { p.icicles[k].len -= temp * 0.12 * tick }
                        p.icicles.removeAll { $0.len <= 0.3 }
                        p.icicleVisible = Array(repeating: false, count: p.icicles.count)
                        p.dirty = true
                        p.iceDirty = true
                    }
                    continue
                }
                guard now - p.lastMove > 12, p.rect.minY > 40 else { continue }
                if p.icicles.isEmpty {
                    let w = Float(p.rect.width)
                    let count = max(2, min(9, Int(w / 110)))
                    p.icicles = (0..<count).map { _ in
                        let maxLen = Float.random(in: 7...30) * Float(cfg.icicleLength)
                        return Icicle(x: Float.random(in: 16...max(17, w - 16)), len: 0, maxLen: maxLen,
                                      rate: maxLen / Float.random(in: 50...160), width: Float.random(in: 3.5...6))
                    }
                    p.icicleVisible = Array(repeating: false, count: count)
                    p.dirty = true          // visibility is computed on the next sync
                }
                let coldBoost = 1 + min(2, -temp / 8)
                for k in p.icicles.indices where p.icicles[k].len < p.icicles[k].maxLen {
                    p.icicles[k].len = min(p.icicles[k].maxLen, p.icicles[k].len + p.icicles[k].rate * coldBoost * tick)
                    p.iceDirty = true
                }
            }
            if cfg.onMenuBar {
                if menuIcicles.isEmpty {
                    let count = max(4, Int(W / 140))
                    menuIcicles = (0..<count).map { _ in
                        let m = Float.random(in: 5...18) * Float(cfg.icicleLength)
                        return Icicle(x: Float.random(in: 10...(W - 10)), len: 0, maxLen: m,
                                      rate: m / Float.random(in: 90...240), width: Float.random(in: 3...5))
                    }
                }
                if temp > 0 {
                    for k in menuIcicles.indices { menuIcicles[k].len = max(0, menuIcicles[k].len - temp * 0.12 * tick) }
                    menuIceDirty = true
                } else {
                    for k in menuIcicles.indices where menuIcicles[k].len < menuIcicles[k].maxLen {
                        menuIcicles[k].len = min(menuIcicles[k].maxLen, menuIcicles[k].len + menuIcicles[k].rate * tick)
                        menuIceDirty = true
                    }
                }
            } else if !menuIcicles.isEmpty || menuSnow.contains(where: { $0 > 0 }) {
                menuIcicles = []
                for k in menuSnow.indices { menuSnow[k] = 0 }
                menuIceDirty = true
            }
        }

        if hostsSnowman { stepSnowmen(dt: fdt) }
    }

    /// Does anything still need animating? If not, the display link goes to sleep.
    var isAnimating: Bool {
        if !cfg.paused && !fullscreen { return true }
        if cfg.christmas && (cfg.christmasGarland || treePos != nil) && !fullscreen { return true }   // twinkling lights
        if !flakes.isEmpty || !debris.isEmpty || !shards.isEmpty || !snowballs.isEmpty { return true }
        return hostsSnowman && snowmen.contains { $0.isMoving }
    }

    // MARK: - Drift physics

    private func rebuildColumns() {
        let n = Int(W / Self.columnW) + 1
        var cols = Array(repeating: [Pile](), count: n)
        for p in landables {
            let a = max(0, Int(Float(p.rect.minX) / Self.columnW))
            let b = min(n - 1, Int(Float(p.rect.maxX) / Self.columnW))
            if a <= b { for c in a...b { cols[c].append(p) } }
        }
        columns = cols
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
        guard p.bins[b] < p.cap else { return }
        p.bins[b] = min(p.cap, p.bins[b] + amount)
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
        for ic in menuIcicles where ic.len > 2 {
            shards.append(Shard(x: ic.x, y: H - Float(menuBarHeight), vy: 0, len: ic.len, width: ic.width))
        }
        menuIcicles = []
        menuIceDirty = true
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
        for i in flakes.indices {
            let dx = flakes[i].x - m.x, dy = flakes[i].y - m.y
            let d2 = dx * dx + dy * dy
            if d2 < r * r {
                let fall = 1 - d2.squareRoot() / r
                flakes[i].vx += v.x * 0.35 * fall
                flakes[i].y += v.y * 0.02 * fall
            }
        }
        guard speed > 260 else { return }
        for p in landables {
            let rel = m.x - Float(p.rect.minX)
            guard rel >= 0, rel < Float(p.rect.width) else { continue }
            let c = Int(rel / Self.binW)
            guard c < p.bins.count else { continue }
            let top = Float(p.rect.maxY)
            guard m.y >= top - 3, m.y <= top + p.bins[c] + 4 else { continue }
            for k in max(0, c - 3)...min(p.bins.count - 1, c + 3) where p.bins[k] > 0.4 && p.visible[k] {
                let take = p.bins[k] * 0.7
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
        let reach = 4                     // bins on each side (≈ 16 pt)
        for p in landables {
            let rel = m.x - Float(p.rect.minX)
            guard rel >= -16, rel < Float(p.rect.width) + 16 else { continue }
            let top = Float(p.rect.maxY)
            guard m.y >= top - 6, m.y <= top + p.cap + 10 else { continue }
            shovelAt = m
            let c = Int(rel / Self.binW), n = p.bins.count
            var moved: Float = 0
            for k in max(0, c - reach)...min(n - 1, max(0, c + reach)) where p.bins[k] > 0.05 {
                let take = p.bins[k] * min(1, 14 * dt)
                p.bins[k] -= take
                moved += take
            }
            guard moved > 0.01 else { continue }
            p.dirty = true
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
        guard cfg.christmas, cfg.christmasTree else { treePos = nil; return }
        let s = Float(cfg.treeSize)
        var x: Float
        if let d = dockLocal, d.minY < size.height / 2 {
            x = Float(d.minX) - 62 * s
            if x < 50 * s { x = Float(d.maxX) + 62 * s }
        } else {
            x = W * 0.12
        }
        let y = driftHeight(Self.groundKey, at: x) * 0.8
        treePos = (x, y)
        let r = Christmas.treeRect(x: x, baseY: y, scale: s).insetBy(dx: 12, dy: 6)
        treeGhost = cfg.snowmanGhost && windowRects.contains { $0.rect.intersects(r) }
    }

    var treeHitRect: CGRect? {
        guard let p = treePos, !treeGhost, !fullscreen else { return nil }
        return Christmas.treeRect(x: p.x, baseY: p.y, scale: Float(cfg.treeSize))
    }

    /// Default spot for snowman i: along the top of the Dock from the right, then beside the Dock.
    private func slot(_ i: Int, size sz: Float) -> (key: Int, x: Float, y: Float) {
        let gap = 64 * sz
        if let d = dockLocal, d.minY < size.height / 2 {
            let x = Float(d.maxX) - 46 * sz - Float(i) * gap
            if x > Float(d.minX) + 20 * sz { return (Self.dockKey, x, Float(d.maxY)) }
            let k = Float(i) - floor((Float(d.width) - 66 * sz) / gap) - 1
            let gx = Float(d.minX) - 30 * sz - max(0, k) * gap
            return (Self.groundKey, max(20 * sz, gx), 0)
        }
        return (Self.groundKey, W * 0.5 + 180 - Float(i) * gap, Float(dockBottomGuess))
    }

    private func surfaceRect(_ key: Int) -> CGRect? {
        if key == Self.groundKey { return CGRect(x: 0, y: -1, width: size.width, height: 1) }
        if key == Self.dockKey { return dockLocal }
        if let p = piles[key] { return p.rect }
        return windowRects.first { $0.key == key }?.rect
    }

    /// Highest visible surface at x whose top is at or below y.
    private func surfaceBelow(x: Float, y: Float) -> (key: Int, top: Float) {
        var best: (Int, Float) = (Self.groundKey, 0)
        for (idx, w) in windowRects.enumerated() {
            let r = w.rect
            guard x >= Float(r.minX) + 8, x <= Float(r.maxX) - 8, Float(r.maxY) <= y + 1, Float(r.maxY) > best.1,
                  r.maxY < size.height - menuBarHeight - 1 else { continue }
            let pt = CGPoint(x: CGFloat(x), y: r.maxY + 3)
            if windowRects[..<idx].contains(where: { $0.rect.contains(pt) }) { continue }
            best = (w.key, Float(r.maxY))
        }
        if let d = dockLocal, x >= Float(d.minX), x <= Float(d.maxX), Float(d.maxY) <= y + 1, Float(d.maxY) > best.1 {
            best = (Self.dockKey, Float(d.maxY))
        }
        return best
    }

    private func syncSnowmen() {
        let want = cfg.snowman ? max(1, min(6, Int(cfg.snowmanCount.rounded()))) : 0
        while snowmen.count < want {
            var s = Snowman()
            s.nextBuild = snowmen.isEmpty ? 12 : Float(4 + snowmen.count * 5)
            snowmen.append(s)
        }
        while snowmen.count > want {
            var s = snowmen.removeLast()
            s.dismantle(into: &debris)
        }
        let sz = Float(cfg.snowmanSize)
        for i in snowmen.indices {
            var s = snowmen[i]
            s.sizeScale = sz
            if s.carried || s.falling { snowmen[i] = s; continue }
            if !s.userPlaced {
                let sl = slot(i, size: sz)
                s.hostKey = sl.key
                s.anchorX = sl.x
                s.baseY = sl.y + driftHeight(sl.key, at: sl.x) * 0.85
                s.hostRect = surfaceRect(sl.key)
            } else if let r = surfaceRect(s.hostKey), let old = s.hostRect,
                      abs(r.minX - old.minX) < 0.5, abs(r.maxY - old.maxY) < 0.5 {
                s.anchorX = Float(r.minX) + s.offsetX
                s.baseY = Float(r.maxY) + driftHeight(s.hostKey, at: s.anchorX) * 0.85
            } else if s.phase != .absent {
                // The window it stood on moved or closed – it falls.
                s.falling = true
                s.vy = 0
            } else {
                s.userPlaced = false
            }
            // Fade it when it covers a window (behind the Dock or in front of its own window).
            s.ghost = false
            if cfg.snowmanGhost, let body = s.bodyRect {
                for w in windowRects {
                    if w.key == s.hostKey { break }
                    if w.rect.intersects(body.insetBy(dx: 4, dy: 2)) { s.ghost = true; break }
                }
            }
            snowmen[i] = s
        }
    }

    private func stepSnowmen(dt: Float) {
        guard cfg.snowman else {
            for i in snowmen.indices where snowmen[i].phase != .absent { snowmen[i].dismantle(into: &debris) }
            return
        }
        if cfg.paused || fullscreen { return }
        for i in snowmen.indices {
            snowmen[i].rebuildDelay = Float(cfg.snowmanBreak) * 60
            snowmen[i].throwEvery = Float(cfg.throwEvery)
            snowmen[i].temperature = Float(cfg.temperature)
            snowmen[i].santaHat = cfg.christmas && cfg.christmasHats
            if snowmen[i].falling { stepFall(i, dt: dt) }
            let wantsThrow = snowmen[i].step(dt: dt, debris: &debris, shards: &shards)
            if wantsThrow && cfg.snowballs && !snowmen[i].ghost { throwSnowball(from: i) }
        }
    }

    private func stepFall(_ i: Int, dt: Float) {
        var s = snowmen[i]
        let target = surfaceBelow(x: s.anchorX, y: s.baseY)
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
        let targets = landables.filter { ($0.kind == .window || $0.kind == .icon) && $0.visible.contains(true) }
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

    func snowmanClicked(_ i: Int, at p: CGPoint) {
        guard hostsSnowman, snowmen.indices.contains(i) else { return }
        let fightBack = snowmen[i].hit(at: SIMD2(Float(p.x), Float(p.y)), debris: &debris)
        if fightBack && cfg.snowballs { throwSnowball(from: i) }
    }

    /// Drag a snowman with the mouse (`p` = cursor in local coordinates).
    func dragSnowman(_ i: Int, to p: CGPoint) {
        guard snowmen.indices.contains(i), snowmen[i].bodyRect != nil else { return }
        snowmen[i].carried = true
        snowmen[i].falling = false
        snowmen[i].anchorX = Float(p.x)
        snowmen[i].baseY = Float(p.y) - snowmen[i].R(0) * 1.4
        snowmen[i].wobble = max(snowmen[i].wobble, 0.4)
    }

    /// Let go: it falls onto whatever is below.
    func dropSnowman(_ i: Int) {
        guard snowmen.indices.contains(i), snowmen[i].carried else { return }
        snowmen[i].carried = false
        snowmen[i].falling = true
        snowmen[i].vy = 0
    }

    var snowmanHitRects: [CGRect?] {
        guard hostsSnowman, !fullscreen else { return [] }
        return snowmen.map { $0.hitRect }
    }

    func buildSnowmanNow() {
        guard hostsSnowman else { return }
        for i in snowmen.indices { snowmen[i].buildNow() }
    }

    /// Send all dragged snowmen back to the Dock.
    func resetSnowmen() {
        for i in snowmen.indices { snowmen[i].userPlaced = false; snowmen[i].falling = false }
        syncSnowmen()
    }

    // MARK: - Output for the renderer

    func buildParticles(into out: inout [Particle]) {
        let t = Float(time)
        for f in flakes {
            if f.sparkle {
                let tw = 0.55 + 0.45 * sin(t * 9 + f.phase * 3)
                out.append(Particle(x: f.x, y: f.y, size: f.size * (0.9 + 0.5 * tw), alpha: min(1, f.alpha * (0.5 + tw))))
            } else {
                out.append(Particle(x: f.x, y: f.y, size: f.size, alpha: f.alpha))
            }
        }
        for d in debris {
            // Landing clumps are drawn solid; powder stays soft.
            out.append(Particle(x: d.x, y: d.y, size: d.lands && d.size > 2.4 ? -d.size : d.size, alpha: max(0, d.alpha)))
        }
        for s in snowballs { out.append(Particle(x: s.x, y: s.y, size: -7.5, alpha: 1)) }
    }

    func buildMesh(into out: inout [Vertex]) {
        Mesh.tint = tint
        if fullscreen { return }
        if cfg.frost { buildFrost(into: &out) }
        for p in landables {
            if p.dirty || p.iceDirty { rebuildMesh(p) }
            out.append(contentsOf: p.mesh)
        }
        if cfg.onMenuBar { buildMenuBar(into: &out) }
        for s in shards { Mesh.icicle(&out, x: s.x, top: s.y, len: s.len, width: s.width, alpha: 0.9) }
        let style = Christmas.LightStyle(rawValue: cfg.lightStyle) ?? .colorful
        if cfg.christmas && cfg.christmasGarland && menuBarHeight > 0 {
            Christmas.garland(&out, width: W, y: H - Float(menuBarHeight), t: Float(time), style: style)
        }
        if hostsSnowman, let p = treePos {
            Christmas.tree(&out, x: p.x, baseY: p.y, scale: Float(cfg.treeSize), t: Float(time), style: style,
                           alpha: treeGhost ? 0.22 : 1)
        }
        if hostsSnowman { for s in snowmen { s.build(into: &out) } }
        if let m = shovelAt {
            Mesh.ring(&out, cx: m.x, cy: m.y, r: 17, width: 1.5, color: (0.75, 0.86, 1, 0.75))
        }
    }

    private func rebuildMesh(_ p: Pile) {
        p.mesh.removeAll(keepingCapacity: true)
        let n = p.bins.count
        let base = Float(p.rect.maxY) - 0.5
        let x0 = Float(p.rect.minX)
        let bw = Self.binW
        func h(_ i: Int) -> Float { p.bins[max(0, min(n - 1, i))] }
        var i = 0
        while i < n {
            if !p.visible[i] || p.bins[i] < 0.25 { i += 1; continue }
            // Smooth top: height at a bin boundary = average of the neighbours.
            let l = x0 + Float(i) * bw, r = l + bw
            let hl = (i > 0 && p.visible[i - 1]) ? (h(i - 1) + h(i)) * 0.5 : 0
            let hr = (i < n - 1 && p.visible[i + 1]) ? (h(i) + h(i + 1)) * 0.5 : 0
            let hm = h(i)
            let m = l + bw * 0.5
            Mesh.snowColumn(&p.mesh, l: l, m: m, r: r, base: base, hl: hl, hm: hm, hr: hr)
            i += 1
        }
        if p.kind == .window && p.frost > 0.01 { buildWindowFrost(p) }
        if p.kind == .window {
            for (k, ic) in p.icicles.enumerated() where ic.len > 0.6 && k < p.icicleVisible.count && p.icicleVisible[k] {
                Mesh.icicle(&p.mesh, x: x0 + ic.x, top: Float(p.rect.minY) + 0.5, len: ic.len, width: ic.width, alpha: 0.85)
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

    private func buildMenuBar(into out: inout [Vertex]) {
        let y = H - Float(menuBarHeight)
        let bw = Self.binW
        for (i, h) in menuSnow.enumerated() where h > 0.2 {
            let l = Float(i) * bw
            Mesh.rect(&out, x: l, y: y - h * 0.5, w: bw, h: h, top: Mesh.snowTop, bottom: Mesh.snowBase)
        }
        for ic in menuIcicles where ic.len > 0.6 {
            Mesh.icicle(&out, x: ic.x, top: y, len: ic.len, width: ic.width, alpha: 0.85)
        }
        menuIceDirty = false
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
