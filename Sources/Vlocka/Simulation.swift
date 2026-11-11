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
    private var menuIcicles: [Icicle] = []
    private var menuIceDirty = true
    private var menuSnow: [Float] = []
    var snowman = Snowman()

    private var time: Double = 0
    private var spawnAcc: Double = 0
    private var wind: Float = 0
    private var meshTimer: Double = 0
    private var cfg = SimConfig()
    private var fullscreen = false
    private var lastMouse: SIMD2<Float>?
    private var tint: (Float, Float, Float) = (1, 1, 1)

    init(screenFrame: CGRect, visibleFrame: CGRect, hostsSnowman: Bool) {
        origin = screenFrame.origin
        size = screenFrame.size
        menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        dockBottomGuess = max(0, visibleFrame.minY - screenFrame.minY)
        self.hostsSnowman = hostsSnowman
        snowman.nextBuild = 12
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
        var seen = Set<Int>()
        var order: [Pile] = []
        let localOcc = occluders.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }

        func upsert(key: Int, kind: SurfaceKind, rect r: CGRect) -> Pile {
            seen.insert(key)
            if let p = piles[key] {
                if abs(p.rect.minX - r.minX) > 0.5 || abs(p.rect.minY - r.minY) > 0.5
                    || abs(p.rect.width - r.width) > 0.5 || abs(p.rect.height - r.height) > 0.5 {
                    let push = Float(r.midX - p.rect.midX) * 4
                    shake(p, push: max(-260, min(260, push)))
                    let resized = abs(p.rect.width - r.width) > 0.5
                    p.rect = r
                    if resized { p.resize(binW: Self.binW) }
                    p.lastMove = now
                    changed = true
                }
                return p
            }
            let p = Pile(key: key, kind: kind, rect: r, binW: Self.binW, now: now)
            p.cap = capFor(kind)
            piles[key] = p
            changed = true
            return p
        }

        // Windows (front to back); a window is occluded by the windows in front of it.
        var front: [CGRect] = localOcc
        for w in windows {
            let r = w.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            guard r.intersects(bounds) else { continue }
            if cfg.onWindows {
                let p = upsert(key: w.id, kind: .window, rect: r)
                if updateVisibility(p, occluders: front) { changed = true }
                order.append(p)
            }
            front.append(r)
        }
        // Dock
        var dockLocal: CGRect?
        if cfg.onDock, let d = dock?.offsetBy(dx: -origin.x, dy: -origin.y), d.intersects(bounds), d.maxY > 6 {
            dockLocal = d
            let p = upsert(key: Self.dockKey, kind: .dock, rect: d)
            if updateVisibility(p, occluders: localOcc) { changed = true }
            order.append(p)
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
        if updateGroundVisibility(g, dock: dockLocal) { changed = true }
        order.append(g)

        for (k, p) in piles where !seen.contains(k) {
            shake(p, push: 0)
            piles[k] = nil
            changed = true
        }
        landables = order
        if capsChanged || tintChanged {
            for p in order { p.cap = capFor(p.kind); p.dirty = true; p.bins = p.bins.map { min($0, p.cap) } }
        }
        if hostsSnowman { placeSnowman(dock: dockLocal) }
        return changed
    }

    private func capFor(_ k: SurfaceKind) -> Float {
        let w = Float(cfg.windowDepth)
        switch k {
        case .window: return w
        case .dock: return min(w * 0.55, 34)
        case .icon: return min(w * 0.4, 22)
        case .ground: return Float(cfg.groundDepth)
        }
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

    private func updateGroundVisibility(_ p: Pile, dock: CGRect?) -> Bool {
        var changed = false
        for i in 0..<p.bins.count {
            let x = (CGFloat(i) + 0.5) * CGFloat(Self.binW)
            var v = true
            if let d = dock, d.minY < 12, x >= d.minX - 4, x <= d.maxX + 4 { v = false }
            if p.visible[i] != v { p.visible[i] = v; changed = true }
        }
        if changed { p.dirty = true }
        return changed
    }

    // MARK: - Simulation step

    func step(dt: Double, now: Double, mouse: CGPoint? = nil) {
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
        if cfg.mouse, let mouse { stepMouse(SIMD2(Float(mouse.x), Float(mouse.y)), dt: fdt) } else { lastMouse = nil }
        let acc = Float(cfg.accumulation)

        // Flakes
        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            let oy = f.y
            f.phase += f.freq * fdt
            f.x += (wind * (0.35 + f.depth) + sin(f.phase) * f.amp + f.vx) * fdt
            f.y -= f.vy * fdt
            if f.vx != 0 { f.vx *= max(0, 1 - 2.5 * fdt); if abs(f.vx) < 1 { f.vx = 0 } }
            if f.depth > 0.3, let (p, b) = hit(x: f.x, oldY: oy, newY: f.y) {
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
                deposit(p, b, d.size * 0.35)
                debris.swapAt(i, debris.count - 1); debris.removeLast(); continue
            }
            if d.y < -20 || d.alpha <= 0 { debris.swapAt(i, debris.count - 1); debris.removeLast(); continue }
            if !d.lands { d.alpha -= fdt * 1.6 }
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
            if cfg.melt > 0 {
                let m = Float(cfg.melt) / 60 * tick
                for p in landables {
                    var any = false
                    for k in p.bins.indices where p.bins[k] > 0 { p.bins[k] = max(0, p.bins[k] - m); any = true }
                    if any { p.dirty = true }
                }
                for k in menuSnow.indices where menuSnow[k] > 0 { menuSnow[k] = max(0, menuSnow[k] - m * 0.2) }
            }
            for p in landables where p.kind == .window {
                guard cfg.icicles else {
                    if !p.icicles.isEmpty { p.icicles = []; p.icicleVisible = []; p.iceDirty = true }
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
                for k in p.icicles.indices where p.icicles[k].len < p.icicles[k].maxLen {
                    p.icicles[k].len = min(p.icicles[k].maxLen, p.icicles[k].len + p.icicles[k].rate * tick)
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
                for k in menuIcicles.indices where menuIcicles[k].len < menuIcicles[k].maxLen {
                    menuIcicles[k].len = min(menuIcicles[k].maxLen, menuIcicles[k].len + menuIcicles[k].rate * tick)
                    menuIceDirty = true
                }
            } else if !menuIcicles.isEmpty || menuSnow.contains(where: { $0 > 0 }) {
                menuIcicles = []
                for k in menuSnow.indices { menuSnow[k] = 0 }
                menuIceDirty = true
            }
        }

        if hostsSnowman { stepSnowman(dt: fdt) }
    }

    /// Does anything still need animating? If not, the display link goes to sleep.
    var isAnimating: Bool {
        if !cfg.paused && !fullscreen { return true }
        if !flakes.isEmpty || !debris.isEmpty || !shards.isEmpty || !snowballs.isEmpty { return true }
        return hostsSnowman && snowman.isMoving
    }

    // MARK: - Drift physics

    private func hit(x: Float, oldY: Float, newY: Float) -> (Pile, Int)? {
        for p in landables {
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
    private func shake(_ p: Pile, push: Float) {
        let n = p.bins.count
        var spawned = 0
        for i in stride(from: 0, to: n, by: 2) where p.bins[i] > 0.6 && p.visible[i] && spawned < 120 {
            let h = p.bins[i]
            let x = Float(p.rect.minX) + (Float(i) + 0.5) * Self.binW
            debris.append(Debris(x: x, y: Float(p.rect.maxY) + h * 0.5,
                                 vx: push * Float.random(in: 0.3...1) + Float.random(in: -25...25),
                                 vy: Float.random(in: 0...60), size: min(9, 2.5 + h * 0.45) * Float.random(in: 0.7...1.25),
                                 alpha: 1, lands: true))
            spawned += 1
        }
        for (k, ic) in p.icicles.enumerated() where ic.len > 2 && (k < p.icicleVisible.count && p.icicleVisible[k]) {
            shards.append(Shard(x: Float(p.rect.minX) + ic.x, y: Float(p.rect.minY), vy: 0, len: ic.len, width: ic.width))
        }
        if debris.count > 2500 { debris.removeFirst(debris.count - 2500) }
        for i in 0..<n { p.bins[i] = 0 }
        p.icicles = []
        p.icicleVisible = []
        p.dirty = true
        p.iceDirty = true
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
        let size = (1.4 + depth * depth * 5.2) * Float(cfg.flakeSize)
        let vy = (22 + 58 * depth + Float.random(in: 0...12)) * Float(cfg.fallSpeed)
        flakes.append(Flake(x: Float.random(in: -20...(W + 20)), y: H + size, vx: 0, vy: vy,
                            phase: Float.random(in: 0...(2 * .pi)), freq: Float.random(in: 0.5...1.6),
                            amp: Float.random(in: 5...22) * depth, depth: depth, size: size, alpha: 0.5 + 0.5 * depth,
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
        for p in landables where p.kind != .ground {
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

    // MARK: - Snowman

    private func placeSnowman(dock: CGRect?) {
        if let d = dock, d.minY < size.height / 2 {
            snowman.baseY = Float(d.maxY)
            snowman.anchorX = Float(d.maxX) - 46 * snowman.sizeScale
        } else {
            snowman.baseY = Float(dockBottomGuess)
            snowman.anchorX = W * 0.5 + 180
        }
    }

    private func stepSnowman(dt: Float) {
        guard cfg.snowman else {
            if snowman.phase != .absent { snowman.dismantle(into: &debris) }
            return
        }
        if cfg.paused || fullscreen { return }
        snowman.sizeScale = Float(cfg.snowmanSize)
        snowman.rebuildDelay = Float(cfg.snowmanBreak) * 60
        snowman.throwEvery = Float(cfg.throwEvery)
        let wantsThrow = snowman.step(dt: dt, debris: &debris, shards: &shards)
        if wantsThrow && cfg.snowballs { throwSnowball() }
    }

    func throwSnowball() {
        let targets = landables.filter { ($0.kind == .window || $0.kind == .icon) && $0.visible.contains(true) }
        guard let p = targets.randomElement() else { return }
        let idx = p.visible.indices.filter { p.visible[$0] }
        guard let b = idx.randomElement() else { return }
        let tx = Float(p.rect.minX) + (Float(b) + 0.5) * Self.binW
        let ty = Float(p.rect.maxY) + p.bins[b] + 2
        let hand = snowman.handPosition
        let dist = hypot(tx - hand.x, ty - hand.y)
        let T = max(0.6, min(1.7, dist / 420))
        let vx = (tx - hand.x) / T
        let vy = (ty - hand.y) / T + 0.5 * 600 * T
        snowballs.append(Snowball(x: hand.x, y: hand.y, vx: vx, vy: vy, t: 0, duration: T, target: p.key, tx: tx))
        snowman.armThrow = 1
    }

    func snowmanClicked(at p: CGPoint) {
        guard hostsSnowman else { return }
        let fightBack = snowman.hit(at: SIMD2(Float(p.x), Float(p.y)), debris: &debris)
        if fightBack && cfg.snowballs { throwSnowball() }
    }

    var snowmanHitRect: CGRect? { hostsSnowman && !fullscreen ? snowman.hitRect : nil }

    func buildSnowmanNow() { if hostsSnowman { snowman.buildNow() } }

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
        for d in debris { out.append(Particle(x: d.x, y: d.y, size: d.size, alpha: max(0, d.alpha))) }
        for s in snowballs { out.append(Particle(x: s.x, y: s.y, size: 7.5, alpha: 1)) }
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
        if hostsSnowman { snowman.build(into: &out) }
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
        if p.kind == .window {
            for (k, ic) in p.icicles.enumerated() where ic.len > 0.6 && k < p.icicleVisible.count && p.icicleVisible[k] {
                Mesh.icicle(&p.mesh, x: x0 + ic.x, top: Float(p.rect.minY) + 0.5, len: ic.len, width: ic.width, alpha: 0.85)
            }
        }
        p.dirty = false
        p.iceDirty = false
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
