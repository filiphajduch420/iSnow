import AppKit

/// [1.3 snowmen] Snowballs the user rolls: hold ⌥ Option + ⇧ Shift and move the cursor along the snow at the
/// bottom (or on the Dock). A ball appears at the cursor, rolls along, grows from the snow it picks up (leaving a
/// trough) and stays where it is when the keys are let go. A smaller ball rolled into (or dropped next to) a bigger
/// one is lifted on top; three stacked balls come alive as a snowman. Loose balls melt above zero, the plow
/// smashes them.
struct SnowYard {
    struct Stack {
        var id: Int
        var x: Float
        var baseY: Float
        var key: Int                  // surface: -1 bottom edge, -2 Dock
        var balls: [Float]            // radii, bottom first
        var spin: [Float]             // rotation of each ball (radians) – shows the rolling
        var lift: Float = 1           // 0…1: the top ball being lifted on, from `liftX`
        var liftX: Float = 0
        var age: Float = 0
        var wobble: Float = 0
    }

    private(set) var stacks: [Stack] = []
    private(set) var rolling: Int?          // id of the stack being rolled
    private var nextID = 1
    private var trail: Float = 0            // powder thrown up while rolling
    private var waitRelease = false         // a ball was just stacked: no new one until the keys are let go

    static let maxStacks = 8
    /// Self-built snowmen that may stand at the same time (on top of the "Number of snowmen" setting).
    static let maxBuilt = 3
    static let startRadius: Float = 3.5
    static let binW: Float = 4           // = Simulation.binW

    /// ⌥ is down right now (a click on a snowman then throws a snowball at it).
    @MainActor static var optionDown: Bool { NSEvent.modifierFlags.contains(.option) }

    var isEmpty: Bool { stacks.isEmpty }

    /// Something is moving: a ball being rolled or lifted, or wobbling.
    var isMoving: Bool { rolling != nil || stacks.contains { $0.lift < 1 || $0.wobble > 0.01 } }

    /// A surface the balls can be rolled on.
    struct Surface {
        let pile: Pile
        let top: Float                // y of the surface (without snow)
    }

    // MARK: Step

    /// `cursor` is non-nil while the roll gesture is held. `surfaceAt` picks the surface under the cursor,
    /// `surfaceFor` finds one by key, `height` is the (smoothed) snow height on a surface at x.
    /// Returns the stacks that just got their third ball (removed from the yard – they become snowmen).
    mutating func step(dt: Float, cursor: SIMD2<Float>?, maxRadius: Float, temperature: Float, plow: ClosedRange<Float>?,
                       debris: inout [Debris], surfaceAt: (SIMD2<Float>) -> Surface?, surfaceFor: (Int) -> Surface?,
                       height: (Int, Float) -> Float) -> [Stack] {
        if let m = cursor {
            if rolling == nil && !waitRelease { begin(at: m, surfaceAt: surfaceAt, height: height) }
            if let id = rolling { roll(id, toward: m, dt: dt, maxRadius: maxRadius, debris: &debris,
                                       surfaceFor: surfaceFor, height: height) }
        } else {
            waitRelease = false
            if let id = rolling { release(id, debris: &debris) }
        }

        var done: [Stack] = []
        var i = 0
        while i < stacks.count {
            var st = stacks[i]
            st.age += dt
            st.wobble = max(0, st.wobble - dt * 2.5)
            if let sf = surfaceFor(st.key) {
                let goal = sf.top + height(st.key, st.x) * 0.85
                st.baseY += (goal - st.baseY) * min(1, dt * 8)
            }
            if st.lift < 1 { st.lift = min(1, st.lift + dt / 0.55) }
            // Thaw (and very slowly even in frost, so forgotten balls don't stay forever).
            let melt = (temperature > 0.5 ? temperature * 0.03 : 0) + (st.age > 600 ? 0.02 : 0)
            if melt > 0 && st.id != rolling {
                for k in st.balls.indices { st.balls[k] -= melt * dt * (1 + Float(k) * 0.2) }
                while let last = st.balls.last, last < 2.5, st.balls.count > 1 { st.balls.removeLast(); st.spin.removeLast() }
            }
            var smash = st.balls[0] < 2.5 && st.id != rolling
            if let p = plow, p.contains(st.x - st.balls[0]) || p.contains(st.x + st.balls[0]) { smash = true }
            if smash {
                crumble(st, into: &debris)
                if rolling == st.id { rolling = nil }
                stacks.remove(at: i)
                continue
            }
            if st.balls.count >= 3 && st.lift >= 1 {
                done.append(st)
                stacks.remove(at: i)
                continue
            }
            stacks[i] = st
            i += 1
        }
        return done
    }

    private func index(_ id: Int) -> Int? { stacks.firstIndex { $0.id == id } }

    /// The gesture started (or the cursor came to the snow): grab a loose ball there, or start a new one
    /// if there is enough snow.
    private mutating func begin(at m: SIMD2<Float>, surfaceAt: (SIMD2<Float>) -> Surface?, height: (Int, Float) -> Float) {
        guard let sf = surfaceAt(m) else { return }
        let key = sf.pile.key
        if let st = stacks.first(where: { $0.key == key && $0.balls.count == 1 && $0.lift >= 1 && abs($0.x - m.x) < $0.balls[0] + 8 }) {
            rolling = st.id
            return
        }
        // Not inside another stack, and not on bare ground.
        guard stacks.count < Self.maxStacks,
              !stacks.contains(where: { $0.key == key && abs($0.x - m.x) < $0.balls[0] + Self.startRadius + 2 }),
              height(key, m.x) >= 2.5, binVisible(sf.pile, at: m.x) else { return }
        let r = Self.startRadius
        stacks.append(Stack(id: nextID, x: m.x, baseY: sf.top + height(key, m.x) * 0.85, key: key, balls: [r],
                            spin: [Float.random(in: 0...6.28)]))
        rolling = nextID
        nextID += 1
    }

    private mutating func roll(_ id: Int, toward m: SIMD2<Float>, dt: Float, maxRadius: Float, debris: inout [Debris],
                               surfaceFor: (Int) -> Surface?, height: (Int, Float) -> Float) {
        guard let i = index(id), let sf = surfaceFor(stacks[i].key) else { rolling = nil; return }
        var st = stacks[i]
        let p = sf.pile
        var r = st.balls[0]
        // Lift the cursor well above the snow and the ball is let go.
        if m.y > sf.top + height(st.key, st.x) + max(110, r * 4) { release(id, debris: &debris); return }
        let maxStep = 900 * dt
        var nx = st.x + max(-maxStep, min(maxStep, m.x - st.x))
        nx = max(Float(p.rect.minX) + r, min(Float(p.rect.maxX) - r, nx))
        let dir: Float = nx > st.x ? 1 : -1
        // Don't roll into places where the surface is hidden (under the Dock, behind the screen edge).
        if abs(nx - st.x) > 0.01 && !binVisible(p, at: nx + dir * r * 0.5) { nx = st.x }
        // Other balls on the same surface: a smaller ball climbs on top, otherwise it stops at the contact.
        for j in stacks.indices where j != i && stacks[j].key == st.key {
            let o = stacks[j]
            let reach = r + o.balls[0] * 0.92
            guard abs(nx - o.x) < reach else { continue }
            if Self.canStack(r, on: o) {
                stack(i, onto: j)
                waitRelease = true
                return
            }
            nx = o.x + (st.x < o.x ? -reach : reach)
        }
        let dx = nx - st.x
        if abs(dx) > 0.01 {
            // Pick up the snow the ball rolls over: the bins newly under its contact patch lose most of their snow.
            let foot = max(Self.binW, r * 0.45)
            let a = min(st.x, nx) + (dx > 0 ? foot : -foot)
            let b = max(st.x, nx) + (dx > 0 ? foot : -foot)
            let x0 = Float(p.rect.minX)
            let k0 = max(0, Int((a - x0) / Self.binW)), k1 = min(p.bins.count - 1, Int((b - x0) / Self.binW))
            var gained: Float = 0
            if k0 <= k1 && r < maxRadius {
                for k in k0...k1 where p.visible[k] && p.bins[k] > 0.3 {
                    let take = p.bins[k] * 0.6
                    p.bins[k] -= take
                    gained += take
                }
                if gained > 0 { p.dirty = true }
            }
            if gained > 0 {
                let area = Float.pi * r * r + gained * Self.binW * 0.55
                r = min(maxRadius, (area / .pi).squareRoot())
                trail += gained
                if trail > 3 {
                    trail = 0
                    debris.append(Debris(x: nx - dir * r * 0.8, y: st.baseY + 2, vx: -dir * .random(in: 20...70),
                                         vy: .random(in: 30...90), size: .random(in: 1.4...2.6), alpha: 0.85,
                                         lands: false, fade: 1.8))
                }
            }
            st.spin[0] -= dx / max(2, r)
            st.x = nx
            st.balls[0] = r
        }
        st.age = 0
        stacks[i] = st
    }

    /// Keys let go: the ball stays. If it is next to a bigger ball it is lifted on top; a crumb is dropped.
    private mutating func release(_ id: Int, debris: inout [Debris]) {
        rolling = nil
        guard let i = index(id) else { return }
        let st = stacks[i]
        let r = st.balls[0]
        if let j = stacks.indices.first(where: { $0 != i && stacks[$0].key == st.key
                && abs(stacks[$0].x - st.x) < r + stacks[$0].balls[0] + 14 && Self.canStack(r, on: stacks[$0]) }) {
            stack(i, onto: j)
            return
        }
        if r < 4.5 {
            crumble(st, into: &debris)
            stacks.remove(at: i)
        }
    }

    static func canStack(_ r: Float, on o: Stack) -> Bool {
        guard o.balls.count < 3, o.lift >= 1, let top = o.balls.last else { return false }
        return r <= top * 0.97 && r >= max(4, top * 0.35)
    }

    private mutating func stack(_ i: Int, onto j: Int) {
        let st = stacks[i]
        stacks[j].balls.append(st.balls[0])
        stacks[j].spin.append(st.spin[0])
        stacks[j].lift = 0
        stacks[j].liftX = st.x
        stacks[j].wobble = 1
        stacks[j].age = 0
        if rolling == st.id { rolling = nil }
        stacks.remove(at: i)
    }

    private func binVisible(_ p: Pile, at x: Float) -> Bool {
        let b = Int((x - Float(p.rect.minX)) / Self.binW)
        return b >= 0 && b < p.visible.count && p.visible[b]
    }

    private func crumble(_ st: Stack, into debris: inout [Debris]) {
        for (k, r) in st.balls.enumerated() {
            let y = Self.ballY(st, k)
            for _ in 0..<max(4, Int(r / 2)) {
                let a = Float.random(in: 0.2...(.pi - 0.2)), v = Float.random(in: 40...150)
                debris.append(Debris(x: st.x + .random(in: -r...r) * 0.6, y: y, vx: cos(a) * v, vy: sin(a) * v,
                                     size: .random(in: 2...4.5), alpha: 1, lands: true))
            }
        }
    }

    mutating func crumbleAll(into debris: inout [Debris]) {
        for st in stacks { crumble(st, into: &debris) }
        stacks = []
        rolling = nil
    }

    /// Drop a stack in directly (snapshots).
    mutating func place(x: Float, baseY: Float, key: Int, balls: [Float]) {
        stacks.append(Stack(id: nextID, x: x, baseY: baseY, key: key, balls: balls, spin: balls.map { _ in .random(in: 0...6.28) }))
        nextID += 1
    }

    // MARK: Geometry and drawing

    /// Centre height of ball k – the same stacking as `Snowman.stackY`, so a finished stack turns into a
    /// snowman without a jump.
    static func ballY(_ st: Stack, _ k: Int) -> Float {
        let b = st.balls
        var y = st.baseY + b[0] * 0.92
        if k >= 1, b.count > 1 { y += b[0] * 0.8 + b[1] * 0.8 }
        if k >= 2, b.count > 2 { y += b[1] * 0.8 + b[2] * 0.85 }
        return y
    }

    func build(into out: inout [Vertex]) {
        for st in stacks {
            for (k, r) in st.balls.enumerated() {
                var x = st.x + (k > 0 ? sin(st.age * 30) * st.wobble * Float(k) * 1.2 : 0)
                var y = Self.ballY(st, k)
                if k == st.balls.count - 1 && k > 0 && st.lift < 1 {
                    // Lifted on: an arc from where it was rolled to the top of the stack.
                    let p = st.lift, e = p * p * (3 - 2 * p)
                    let y0 = st.baseY + r * 0.92
                    x = st.liftX + (st.x - st.liftX) * e
                    y = y0 + (y - y0) * e + sin(p * .pi) * (8 + r * 0.6)
                }
                Self.ball(&out, x: x, y: y, r: r, spin: st.spin[k])
            }
        }
    }

    /// A rolled ball: a shaded snow ball with packed-snow layer lines and a few lumps that turn with it.
    static func ball(_ out: inout [Vertex], x: Float, y: Float, r: Float, spin: Float) {
        // Lumps first, so the ball covers their inner half and only bumps show on the rim.
        if r >= 5 {
            for k in 0..<4 {
                let a = spin + Float(k) * 1.57 + 0.4
                Mesh.circle(&out, cx: x + cos(a) * r * 0.9, cy: y + sin(a) * r * 0.9, r: max(1, r * 0.16),
                            center: (0.95, 0.97, 1, 1), rim: (0.8, 0.86, 0.95, 1), segments: 10)
            }
        }
        Mesh.circle(&out, cx: x, cy: y, r: r, center: (1, 1, 1, 1), rim: (0.78, 0.84, 0.94, 1))
        guard r >= 4 else { return }
        // A faint spiral – the layers of snow it was rolled up from – turning with the ball.
        let line: RGBA = (0.76, 0.82, 0.93, 0.5)
        let w = max(0.6, r * 0.06)
        let n = 16
        var prev = (x + cos(spin) * r * 0.16, y + sin(spin) * r * 0.16)
        for k in 1...n {
            let u = Float(k) / Float(n)
            let a = spin + u * 5.6, rad = r * (0.16 + 0.58 * u)
            let p = (x + cos(a) * rad, y + sin(a) * rad)
            Mesh.line(&out, prev, p, width: w, color: line)
            prev = p
        }
    }

    /// The snowball in the hand while ⌥ is held over a snowman (aiming).
    static func aimBall(_ out: inout [Vertex], at m: SIMD2<Float>, t: Float) {
        let bob = sin(t * 6) * 1.2
        Mesh.circle(&out, cx: m.x + 13, cy: m.y - 10 + bob, r: 6.5, center: (1, 1, 1, 1), rim: (0.78, 0.84, 0.94, 1),
                    segments: 18)
    }
}

/// Debug scenes for `--snapshot` (ISNOW_BUILD, ISNOW_FIGHT, ISNOW_PARTY).
@MainActor
enum SnowmenDemo {
    static func setUp(_ sim: Simulation, env: [String: String]) {
        if env["ISNOW_PARTY"] != nil { sim.seasonalHat = .party; sim.sparklers = true }
    }

    /// Runs right before the picture is taken.
    static func stage(_ sim: Simulation, env: [String: String], t: inout Double, dt: Double) {
        func step(_ n: Int, mouse: CGPoint? = nil, roll: Bool = false, shovel: Bool = false) {
            sim.rollKeys = roll
            for _ in 0..<n { sim.step(dt: dt, now: t, mouse: mouse, shovel: shovel || roll); t += dt }
        }
        /// Roll along the bottom from x0 to x1 at `speed` points per second, keys held.
        func rollPath(_ x0: CGFloat, _ x1: CGFloat, y: CGFloat = 14, speed: CGFloat = 260, release: Bool = true) {
            step(6, mouse: CGPoint(x: x0, y: y), roll: true)
            let n = max(1, Int(abs(x1 - x0) / speed / CGFloat(dt)))
            for k in 1...n { step(1, mouse: CGPoint(x: x0 + (x1 - x0) * CGFloat(k) / CGFloat(n), y: y), roll: true) }
            if release { step(2, mouse: CGPoint(x: x1, y: y)) }
        }
        if env["ISNOW_BUILD"] != nil {
            // Left of the Dock: a big ball, a middle one rolled into it, then a head → a snowman.
            rollPath(300, 120)
            rollPath(10, 75, release: false)
            rollPath(75, 100, speed: 120)
            step(30)
            rollPath(30, 55, release: false)
            rollPath(55, 100, speed: 120)
            step(Int(2.4 / dt))
            print("yard:", sim.yardSummary)
            // Right of the Dock: a ball half rolled, keys still held.
            rollPath(1185, 990, release: false)
        }
        if env["ISNOW_FIGHT"] != nil { sim.demoFight(t: &t, dt: dt) }
    }
}
