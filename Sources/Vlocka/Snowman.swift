import CoreGraphics
import Foundation

/// Snowman on the Dock: rolls in its balls, stacks them, puts on a scarf, waves, throws snowballs,
/// and after a while falls apart and melts. Clicking it knocks it apart.
struct Snowman {
    enum Phase { case absent, rolling, dressing, standing, collapsing, melting }

    struct LooseBall { var x, y, vx, vy, r, life: Float }
    struct Carrot { var x, y, vy, alpha: Float; var lying: Bool }

    var phase: Phase = .absent
    var t: Float = 0
    var nextBuild: Float = 12
    var anchorX: Float = 0
    var baseY: Float = 0
    let radii: [Float] = [14, 10, 7]
    var levels = 3
    var scale: Float = 1
    var dress: Float = 0
    var hasCarrot = true
    var hits = 0
    var wobble: Float = 0
    var wave: Float = 0
    var nextWave: Float = 6
    var nextThrow: Float = 25
    var life: Float = 240
    var armThrow: Float = 0
    var loose: [LooseBall] = []
    var carrot: Carrot?
    var sizeScale: Float = 1
    var rebuildDelay: Float = 120
    var throwEvery: Float = 30
    var temperature: Float = -4

    // Where it stands. Keys match the simulation's surfaces (-2 = Dock, -1 = bottom edge).
    var hostKey = -2
    var hostRect: CGRect?
    var offsetX: Float = 0           // position relative to the host's left edge
    var userPlaced = false           // dragged somewhere by the user
    var carried = false              // being dragged right now
    var falling = false
    var vy: Float = 0
    var ghost = false                // faded because it covers a window

    @inline(__always) func R(_ k: Int) -> Float { radii[k] * scale * sizeScale }

    static let rollTime: Float = 1.8

    // MARK: Geometry

    func stackY(_ k: Int) -> Float {
        let r = [R(0), R(1), R(2)]
        let y0 = baseY + r[0] * 0.92
        if k == 0 { return y0 }
        let y1 = y0 + r[0] * 0.8 + r[1] * 0.8
        if k == 1 { return y1 }
        return y1 + r[1] * 0.8 + r[2] * 0.85
    }

    /// Position and radius of ball k (accounts for rolling while building).
    func ball(_ k: Int) -> (x: Float, y: Float, r: Float)? {
        guard k < levels else { return nil }
        let r = R(k)
        let wob = k > 0 ? sin(t * 32) * wobble * Float(k) * 1.2 : 0
        if phase == .rolling {
            let cur = Int(t / Self.rollTime)
            if k > cur { return nil }
            if k == cur {
                let u = (t - Float(k) * Self.rollTime) / Self.rollTime
                if u < 0.72 {
                    let p = u / 0.72
                    let ease = 1 - (1 - p) * (1 - p)
                    let rr = r * (0.35 + 0.65 * p)
                    let dist = 150 * sizeScale
                    return (anchorX - dist + dist * ease, baseY + rr * 0.92, rr)
                }
                let p = (u - 0.72) / 0.28
                let y0 = baseY + r * 0.92, y1 = stackY(k)
                let arc = sin(p * .pi) * 10 * sizeScale
                return (anchorX, y0 + (y1 - y0) * p + arc, r)
            }
        }
        return (anchorX + wob, stackY(k), r)
    }

    var handPosition: SIMD2<Float> {
        let y = stackY(1) + 8 * sizeScale
        return SIMD2(anchorX + R(1) + 13 * sizeScale, y)
    }

    var hitRect: CGRect? {
        guard !ghost || carried else { return nil }
        return bodyRect
    }

    /// Bounding box of the standing snowman (also used to check whether it covers a window).
    var bodyRect: CGRect? {
        guard phase == .standing || phase == .dressing, levels > 0 else { return nil }
        let r0 = R(0)
        let top = (ball(levels - 1).map { $0.y + $0.r } ?? baseY) + 4
        return CGRect(x: CGFloat(anchorX - r0 - 6), y: CGFloat(baseY), width: CGFloat(r0 * 2 + 12), height: CGFloat(top - baseY))
    }

    var isMoving: Bool {
        if carried || falling { return true }
        switch phase {
        case .rolling, .dressing, .collapsing, .melting: return true
        default: return wobble > 0.01 || wave > 0 || armThrow > 0.01 || !loose.isEmpty || carrot != nil
        }
    }

    // MARK: Step

    /// Returns true when the snowman wants to throw a snowball.
    mutating func step(dt: Float, debris: inout [Debris], shards: inout [Shard]) -> Bool {
        t += dt
        wobble = max(0, wobble - dt * 1.8)
        armThrow = max(0, armThrow - dt * 1.5)
        var wantsThrow = false

        switch phase {
        case .absent:
            // Too warm to build a snowman.
            if temperature <= 1 { nextBuild -= dt }
            if nextBuild <= 0 { start() }
        case .rolling:
            if t >= Self.rollTime * 3 { phase = .dressing; t = 0 }
        case .dressing:
            dress = min(1, t / 1.6)
            if t >= 1.6 { phase = .standing; t = 0 }
        case .standing:
            life -= dt
            if wave > 0 { wave = max(0, wave - dt) } else {
                nextWave -= dt
                if nextWave <= 0 { wave = 1.6; nextWave = .random(in: 7...14) }
            }
            nextThrow -= dt
            if nextThrow <= 0 { nextThrow = throwEvery * .random(in: 0.6...1.4); wantsThrow = true }
            if temperature > 0.5 && !carried {
                // Thaw: the snowman slowly shrinks.
                scale -= dt * temperature * 0.0035
                if scale < 0.35 { phase = .melting; t = (1 - scale) * 6 }
            }
            if life <= 0 && !carried { phase = .collapsing; t = 0; dropCarrot() }
        case .collapsing:
            if levels == 3 && t > 0.8 { popTop(debris: &debris, vx: 70) }
            if t > 2.4 { phase = .melting; t = 0 }
        case .melting:
            scale = min(scale, max(0.05, 1 - t / 6))
            if t >= 6 { reset(next: rebuildDelay * .random(in: 0.7...1.3)) }
        }

        // Loose balls and the carrot
        var i = 0
        while i < loose.count {
            var b = loose[i]
            b.life += dt
            b.vy -= 900 * dt
            b.x += b.vx * dt
            b.y += b.vy * dt
            let floor = baseY + b.r * 0.92
            if b.life < 1.1 && b.y < floor && b.vy < 0 {
                if b.vy < -120 { burst(&debris, x: b.x, y: floor - b.r * 0.5, n: 6, speed: 90) }
                b.y = floor
                b.vy = -b.vy * 0.3
                b.vx *= 0.9
            }
            if b.y < -30 { loose.swapAt(i, loose.count - 1); loose.removeLast(); continue }
            loose[i] = b
            i += 1
        }
        if var c = carrot {
            if !c.lying {
                c.vy -= 900 * dt
                c.y += c.vy * dt
                if c.y <= baseY + 1.5 * sizeScale { c.y = baseY + 1.5 * sizeScale; c.lying = true }
            } else {
                c.alpha -= dt * 0.25
            }
            carrot = c.alpha > 0 ? c : nil
        }
        return wantsThrow
    }

    private mutating func start() {
        phase = .rolling
        t = 0
        levels = 3
        scale = 1
        dress = 0
        hasCarrot = true
        hits = 0
        life = .random(in: 150...320)
        nextThrow = throwEvery * .random(in: 0.4...0.8)
        nextWave = .random(in: 3...6)
    }

    private mutating func reset(next: Float) {
        phase = .absent
        carried = false
        falling = false
        ghost = false
        t = 0
        nextBuild = next
        levels = 3
        scale = 1
        dress = 0
    }

    private mutating func dropCarrot() {
        guard hasCarrot, levels == 3 else { return }
        hasCarrot = false
        carrot = Carrot(x: anchorX + R(2) * 0.6, y: stackY(2), vy: 40, alpha: 1, lying: false)
    }

    private mutating func popTop(debris: inout [Debris], vx: Float) {
        guard levels > 0, let b = ball(levels - 1) else { return }
        if levels == 3 { dropCarrot() }
        loose.append(LooseBall(x: b.x, y: b.y, vx: vx, vy: 60, r: b.r, life: 0))
        burst(&debris, x: b.x, y: b.y, n: 8, speed: 110)
        levels -= 1
    }

    private func burst(_ debris: inout [Debris], x: Float, y: Float, n: Int, speed: Float) {
        for _ in 0..<n {
            let a = Float.random(in: 0.15...(.pi - 0.15))
            let v = Float.random(in: speed * 0.4...speed)
            debris.append(Debris(x: x, y: y, vx: cos(a) * v, vy: sin(a) * v, size: .random(in: 2...4.5), alpha: 1, lands: false))
        }
    }

    /// A click on the snowman. Returns true when it fights back (throws a snowball).
    mutating func hit(at p: SIMD2<Float>, debris: inout [Debris]) -> Bool {
        guard phase == .standing || phase == .dressing else { return false }
        hits += 1
        wobble = 1
        burst(&debris, x: p.x, y: p.y, n: 10, speed: 140)
        if hits % 3 == 0 {
            popTop(debris: &debris, vx: Bool.random() ? 80 : -80)
            if levels == 0 { reset(next: rebuildDelay * .random(in: 0.4...0.8)); return false }
        }
        return Bool.random()
    }

    mutating func buildNow() {
        if phase == .absent { nextBuild = 0 }
    }

    mutating func dismantle(into debris: inout [Debris]) {
        for k in 0..<levels { if let b = ball(k) { burst(&debris, x: b.x, y: b.y, n: 8, speed: 100) } }
        reset(next: 12)
        loose = []
        carrot = nil
    }

    // MARK: Drawing

    func build(into out: inout [Vertex]) {
        let start = out.count
        buildBody(into: &out)
        if ghost && !carried {
            for i in start..<out.count { out[i].a *= 0.22 }
        }
    }

    private func buildBody(into out: inout [Vertex]) {
        let center: RGBA = (1, 1, 1, 1)
        let rim: RGBA = (0.78, 0.84, 0.94, 1)
        let dark: RGBA = (0.13, 0.13, 0.17, 1)
        let brown: RGBA = (0.38, 0.25, 0.14, 1)
        let s = sizeScale

        if phase != .absent {
            // Arms behind the body
            if dress > 0, levels >= 2, let m = ball(1) {
                let a = brown.3 * dress
                let col: RGBA = (brown.0, brown.1, brown.2, a)
                let left = (m.x - m.r * 0.85, m.y + 1 * s)
                let lTip = (left.0 - 14 * s, left.1 + 7 * s)
                Mesh.line(&out, left, lTip, width: 1.7 * s, color: col)
                Mesh.line(&out, (lTip.0 + 4 * s, lTip.1 - 2 * s), (lTip.0 + 1 * s, lTip.1 + 4 * s), width: 1.2 * s, color: col)
                let base: Float = 0.45
                let waveA = wave > 0 ? sin(wave * 11) * 0.55 + 0.5 : 0
                let ang = base + waveA + armThrow * 0.9
                let right = (m.x + m.r * 0.85, m.y + 1 * s)
                let rTip = (right.0 + cos(ang) * 15 * s, right.1 + sin(ang) * 15 * s)
                Mesh.line(&out, right, rTip, width: 1.7 * s, color: col)
            }
            for k in 0..<3 {
                guard let b = ball(k) else { continue }
                Mesh.circle(&out, cx: b.x, cy: b.y, r: b.r, center: center, rim: rim)
            }
            if dress > 0 {
                let a = dress
                if levels >= 2, let m = ball(1) {
                    // buttons
                    Mesh.disc(&out, cx: m.x, cy: m.y + 2.5 * s, r: 1.2 * s, color: (dark.0, dark.1, dark.2, a))
                    Mesh.disc(&out, cx: m.x, cy: m.y - 2.5 * s, r: 1.2 * s, color: (dark.0, dark.1, dark.2, a))
                }
                if levels >= 3, let h = ball(2), let m = ball(1) {
                    // scarf
                    let red: RGBA = (0.85, 0.17, 0.22, a)
                    let neckY = (h.y - h.r * 0.75 + m.y + m.r * 0.75) / 2
                    Mesh.rect(&out, x: m.x - m.r * 0.78, y: neckY - 1.8 * s, w: m.r * 1.56, h: 3.6 * s, top: red, bottom: (0.7, 0.1, 0.16, a))
                    let sway = sin(t * 2.2) * 1.2 * s
                    Mesh.line(&out, (m.x + m.r * 0.45, neckY), (m.x + m.r * 0.62 + sway, neckY - 9 * s), width: 3 * s, color: red)
                    // eyes and mouth
                    Mesh.disc(&out, cx: h.x - 2.4 * s, cy: h.y + 1.8 * s, r: 1.05 * s, color: (dark.0, dark.1, dark.2, a))
                    Mesh.disc(&out, cx: h.x + 2.2 * s, cy: h.y + 1.8 * s, r: 1.05 * s, color: (dark.0, dark.1, dark.2, a))
                    for k in 0..<3 {
                        let sx = h.x - 2 * s + Float(k) * 2 * s
                        Mesh.disc(&out, cx: sx, cy: h.y - 3 * s + (k == 1 ? -0.6 * s : 0), r: 0.6 * s, color: (dark.0, dark.1, dark.2, a))
                    }
                    if hasCarrot {
                        let orange: RGBA = (0.98, 0.52, 0.12, a)
                        Mesh.tri(&out, (h.x + 0.5 * s, h.y + 0.8 * s), (h.x + 0.5 * s, h.y - 1.4 * s), (h.x + h.r + 6 * s, h.y - 0.6 * s), orange)
                    }
                }
            }
        }
        for b in loose { Mesh.circle(&out, cx: b.x, cy: b.y, r: b.r, center: center, rim: rim, segments: 20) }
        if let c = carrot {
            let orange: RGBA = (0.98, 0.52, 0.12, max(0, c.alpha))
            let s = sizeScale
            if c.lying {
                Mesh.tri(&out, (c.x - 1 * s, c.y + 1.2 * s), (c.x - 1 * s, c.y - 1.2 * s), (c.x + 8 * s, c.y), orange)
            } else {
                Mesh.tri(&out, (c.x - 1.2 * s, c.y + 1 * s), (c.x + 1.2 * s, c.y + 1 * s), (c.x, c.y - 8 * s), orange)
            }
        }
    }
}
