import CoreGraphics
import Foundation

/// A penguin that visits now and then. It waddles in from one edge of the screen along the snow at the
/// bottom, stops to look around, belly-slides (toboggans) down every slope – the snow hills and the end of
/// the Dock – and pushes itself along with its feet, hops up onto the Dock and over it, sometimes slips and
/// falls over, waves to a snowman it passes, ducks when a snowball flies by and hurries away, flapping,
/// when the cursor comes close. Then it leaves at the other edge. Sometimes a chick follows it.
@MainActor
struct Penguin {
    enum Act { case walk, look, wave, duck, slide, air, fallen, getUp }
    typealias Floor = Skier.Floor

    private static let gravity: Float = 900
    private static let walkSpeed: Float = 34       // points per second at size 1
    private static let slopeG: Float = 520         // gravity along a slope while sliding
    private static let maxSlide: Float = 300

    var x: Float, y: Float                          // between the feet, on the snow
    var dir: Float                                  // +1 walks to the right, −1 to the left
    let chick: Bool
    let size: Float
    var hat = false, scarf = false                  // Christmas
    private(set) var act: Act = .walk
    private var actT: Float = 0                     // time in the current act
    private var actLen: Float = 0
    private var vx: Float = 0, vy: Float = 0
    private var speed: Float = 0                    // sliding speed
    private var diving = false                      // in the air belly first – lands sliding
    private var ph: Float = 0                       // waddle phase
    private var lie: Float = 0                      // 0 upright, 1 on its belly, −1 on its back
    private var tilt: Float = 0                     // slope under it (radians, + uphill ahead)
    private var squash: Float = 0
    private var flap: Float = 0                     // flapping, 0…1
    private var hurry: Float = 0                    // seconds left of hurrying away from the cursor
    private var nextLook: Float
    private var nextToboggan: Float
    private var kicks = 0, maxKicks = 0
    private var kickT: Float = 0
    private var headK: Float = 1                    // 1 profile ahead, 0 facing you, −1 looking back
    private var lastBin = -1, lastPileKey = Int.min
    private var ghost = false                       // behind a window that reaches the bottom edge
    private var alpha: Float = 1
    private var age: Float = 0
    private var greetedX: Float = -100_000          // the snowman it last waved to
    private let seed = Float.random(in: 0...100)
    /// The chick keeps a little behind its parent.
    var leaderX: Float?

    init(x: Float, y: Float, dir: Float, chick: Bool, size: Float) {
        self.x = x; self.y = y; self.dir = dir; self.chick = chick
        self.size = size * (chick ? 0.66 : 1)
        nextLook = Float.random(in: 3...7)
        nextToboggan = Float.random(in: 9...20)
    }

    /// Something visible is animating (full frame rate). Standing still looking around is not.
    var isMoving: Bool { act != .look || abs(headK - lookTarget) > 0.05 || squash > 0.02 || flap > 0.02 }

    /// Where the middle of the body is (for the cursor and snowballs).
    var center: SIMD2<Float> { SIMD2(x + dir * size * 2 * abs(lie) * 4, y + size * (12 - 5 * abs(lie))) }

    private var lookTarget: Float {
        switch act {
        case .look:
            let u = actT / max(0.1, actLen)
            return u < 0.18 ? 1 : u < 0.38 ? 0 : u < 0.7 ? -1 : u < 0.86 ? 0 : 1
        case .wave, .duck: return 0
        default: return 1
        }
    }

    // MARK: Reactions

    /// A snowball flies close by: duck.
    mutating func duck() {
        guard act == .walk || act == .look || act == .wave else { return }
        set(.duck, Float.random(in: 0.7...0.95))
    }

    /// Passing a standing snowman at `sx`: stop and wave (once per snowman). Returns true if it waves.
    mutating func greet(snowmanAt sx: Float) -> Bool {
        guard act == .walk, hurry <= 0, abs(sx - greetedX) > 30, (sx - x) * dir > 14 * size else { return false }
        greetedX = sx
        guard Float.random(in: 0..<1) < 0.7 else { return false }      // not every time
        set(.wave, 1.9)
        return true
    }

    private mutating func set(_ a: Act, _ len: Float = 0) {
        act = a; actT = 0; actLen = len
    }

    // MARK: Step

    /// Advances the penguin. `floor(x, y)` is the top of the snow on the highest surface below a point.
    /// Returns false when it has left the screen.
    mutating func step(dt rawDt: Float, width W: Float, mouse: SIMD2<Float>?, paused: Bool,
                       debris: inout [Debris], floor: Floor) -> Bool {
        let dt = min(rawDt, 1.0 / 20)
        actT += dt
        age += dt
        squash = max(0, squash - dt * 3)
        flap = max(0, flap - dt * 1.5)
        hurry = max(0, hurry - dt)
        kickT = max(0, kickT - dt)
        if hurry > 0 { flap = 1 }
        headK += (lookTarget - headK) * min(1, dt * 9)

        // The cursor comes close: flap and hurry away from it.
        if let m = mouse, hurry <= 0, act == .walk || act == .look || act == .wave || act == .duck {
            let c = center
            if abs(m.x - c.x) < 46 * size + 14 && abs(m.y - c.y) < 40 * size + 14 {
                hurry = 2.6
                dir = m.x < c.x ? 1 : -1
                squash = 0.6
                set(.walk)
            }
        }

        // The lying pose (belly down or on its back) eases in and out.
        let lieTarget: Float = act == .slide || (act == .air && diving) ? 1 : act == .fallen ? -1 : 0
        lie += (lieTarget - lie) * min(1, dt * (lieTarget == 0 ? 7 : 11))

        switch act {
        case .walk: walk(dt, width: W, paused: paused, debris: &debris, floor: floor)
        case .look, .wave, .duck:
            if act == .duck { squash = max(squash, 0.9) }
            settle(dt, floor: floor)
            if actT > actLen || (paused && act != .duck) { set(.walk) }
        case .slide: slide(dt, debris: &debris, floor: floor)
        case .air: fly(dt, debris: &debris, floor: floor)
        case .fallen:
            settle(dt, floor: floor)
            if actT > actLen { set(.getUp, 0.5) }
        case .getUp:
            settle(dt, floor: floor)
            if actT > actLen { set(.walk); squash = 0.4 }
        }
        tilt *= act == .slide ? 1 : max(0, 1 - dt * 8)

        // Lost somewhere (stuck in a loop of hops): fade out.
        if age > 150 { alpha = max(0, alpha - dt / 0.6); if alpha <= 0 { return false } }
        return x > -34 && x < W + 34 && y > -40
    }

    /// An auto-hiding Dock came up right under it: it is tossed up onto the Dock with a startled flap.
    mutating func liftedByDock(to top: Float) {
        y = top
        act = .air; actT = 0; diving = false
        vx = dir * 30; vy = 150
        flap = 1; squash = 0.5
    }

    /// Standing: stay on the snow.
    private mutating func settle(_ dt: Float, floor: Floor) {
        let g = floor(x, y + 10 * size)
        y += (g.top - y) * min(1, dt * 14)
    }

    private mutating func walk(_ dt: Float, width W: Float, paused: Bool, debris: inout [Debris], floor: Floor) {
        var spd = Self.walkSpeed * (chick ? 0.82 : 1) * (0.8 + 0.2 * size)
        if hurry > 0 { spd *= 2.4 } else if paused { spd *= 1.7 }
        if let lx = leaderX {
            // The chick: catch up when it falls behind, wait when it gets too close.
            let gap = (lx - x) * dir
            if gap > 70 { spd *= 1.5 } else if gap < 26 * size / 0.66 && gap > -10 { spd *= 0.15 }
        }
        let phaseRate = 2 * Float.pi * 1.7 * (hurry > 0 ? 1.8 : 1) / (0.75 + 0.25 * size)
        ph += dt * phaseRate * min(1, spd / (Self.walkSpeed * 0.5))
        let nx = x + dir * spd * dt

        // Something higher ahead within hopping height (the Dock, a low window): hop up onto it.
        let ob = floor(nx + dir * 9 * size, y + 130)
        let rise = ob.top - y
        if rise > 9 * size && rise < 130 {
            act = .air; actT = 0; diving = false
            vy = (2 * Self.gravity * (rise + 14 * size)).squareRoot()
            vx = dir * max(70, spd * 1.4)
            flap = 1
            squash = 0.5
            return
        }
        let g = floor(nx, y + 10 * size)
        if g.top < y - 9 * size {
            // An edge (the end of the Dock, a window's drift): dive off it belly first.
            act = .air; actT = 0; diving = true
            vx = dir * max(85, spd * 2.2)
            vy = 90
            kicks = 0; maxKicks = Int.random(in: 1...2)
            puff(&debris, 5)
            return
        }
        x = nx
        y += (g.top - y) * min(1, dt * 18)
        updateGhost(g.pile)
        if g.pile != nil { lastPileKey = g.pile!.key }

        // Downhill ahead: belly-slide down it.
        let here = floor(x, y + 10 * size).top
        let ahead = floor(x + dir * 14 * size, y + 10 * size).top
        let further = floor(x + dir * 30 * size, y + 10 * size).top
        let wall = floor(x + dir * 34 * size, y + 130).top - y > 9 * size     // about to hop up onto something
        if !paused && hurry <= 0 && !wall && here - ahead > 3.5 * size && here - further > 6 * size {
            startSlide(speed: 60, kicks: 0)
            return
        }
        // Slipping on a slope now and then.
        if abs(here - ahead) > 2.5 * size && Float.random(in: 0..<1) < dt * 0.05 {
            set(.fallen, Float.random(in: 0.9...1.4)); squash = 0.5
            return
        }
        guard !paused, hurry <= 0, leaderX == nil else { return }
        // Now and then: stop and look around, or toboggan along on the flat, pushing with the feet.
        let inside = x > 50 && x < W - 50
        nextLook -= dt
        nextToboggan -= dt
        if nextLook <= 0 && inside {
            nextLook = Float.random(in: 5...11)
            set(.look, Float.random(in: 1.5...2.6))
        } else if nextToboggan <= 0 && inside {
            nextToboggan = Float.random(in: 12...26)
            startSlide(speed: 40, kicks: Int.random(in: 2...3))
        }
    }

    private mutating func startSlide(speed s: Float, kicks k: Int) {
        set(.slide)
        speed = s
        kicks = 0; maxKicks = k
        kickT = k > 0 ? 0.4 : 0
        squash = 0.5
        lastBin = -1
    }

    private mutating func slide(_ dt: Float, debris: inout [Debris], floor: Floor) {
        let nx = x + dir * speed * dt
        // Bumping into something higher: stop and get up (then it hops).
        let ob = floor(nx + dir * 18 * size, y + 130)
        if ob.top - y > 10 * size {
            speed = 0
            set(.getUp, 0.45)
            return
        }
        let g = floor(nx, y + 8 * size)
        if g.top < y - 7 * size {
            // Off an edge: fly on belly first.
            act = .air; actT = 0; diving = true
            vx = dir * max(speed, 60); vy = 20
            return
        }
        x = nx
        y += (g.top - y) * min(1, dt * 26)
        updateGhost(g.pile)
        let l = floor(x - 6 * size, y + 10 * size).top, r = floor(x + 6 * size, y + 10 * size).top
        let s = max(-1.2, min(1.2, (r - l) / (12 * size) * dir))         // > 0 uphill
        tilt += (atan(s) * 0.9 - tilt) * min(1, dt * 10)
        speed += (-Self.slopeG * s / (1 + s * s).squareRoot() - 14 - 0.32 * speed) * dt
        if kickT > 0.25 { speed += 150 * dt }                              // pushing off
        speed = max(0, min(Self.maxSlide, speed))
        if let p = g.pile { carve(p) }
        if speed > 70 { spray(&debris, speed * dt * 0.06) }
        if speed < 34 && s > -0.06 && kickT <= 0 {
            if kicks < maxKicks {
                kicks += 1
                kickT = 0.45
            } else if speed < 14 {
                set(.getUp, 0.5)
            }
        }
    }

    private mutating func fly(_ dt: Float, debris: inout [Debris], floor: Floor) {
        let oy = y
        vy -= Self.gravity * dt
        x += vx * dt
        y += vy * dt
        if diving {
            let target = max(-0.7, min(0.3, atan(vy / max(1, abs(vx))) * 0.6))
            tilt += (target - tilt) * min(1, dt * 8)
        }
        guard vy < 0 else { return }
        let f = floor(x, oy)
        guard y <= f.top else { return }
        y = f.top
        if diving {
            diving = false
            startSlide(speed: max(60, abs(vx) * 0.9), kicks: maxKicks)
            kickT = 0
            puff(&debris, 10)
        } else if Float.random(in: 0..<1) < 0.08 {
            set(.fallen, Float.random(in: 0.9...1.3)); squash = 1
            puff(&debris, 6)
        } else {
            set(.walk); squash = 1
            puff(&debris, 6)
        }
    }

    private mutating func updateGhost(_ p: Pile?) {
        ghost = false
        guard let p, p.kind == .ground else { return }
        let b = Int((x - Float(p.rect.minX)) / Simulation.binW)
        if b >= 0 && b < p.visible.count { ghost = !p.visible[b] }
    }

    /// A shallow belly track: lower each bin it slides over a little.
    private mutating func carve(_ p: Pile) {
        let b = Int((x - Float(p.rect.minX)) / Simulation.binW)
        guard b >= 0, b < p.bins.count, b != lastBin || p.key != lastPileKey else { return }
        lastBin = b; lastPileKey = p.key
        if p.visible[b] && p.bins[b] > 3 { p.bins[b] -= 0.6 * size; p.dirty = true }
    }

    private func spray(_ debris: inout [Debris], _ amount: Float) {
        guard debris.count < 9000, !ghost else { return }
        var n = Int(amount)
        if Float.random(in: 0..<1) < amount - Float(n) { n += 1 }
        for _ in 0..<n {
            debris.append(Debris(x: x + dir * Float.random(in: 8...16) * size, y: y + 1.5,
                                 vx: dir * speed * Float.random(in: 0.1...0.4), vy: Float.random(in: 20...70),
                                 size: Float.random(in: 1...2), alpha: 0.8, lands: false, fade: 1.8))
        }
    }

    private func puff(_ debris: inout [Debris], _ n: Int) {
        guard !ghost else { return }
        for _ in 0..<n where debris.count < 9000 {
            debris.append(Debris(x: x + Float.random(in: -8...8) * size, y: y + 1,
                                 vx: Float.random(in: -50...50), vy: Float.random(in: 25...90),
                                 size: Float.random(in: 1.2...2.4), alpha: 0.85, lands: false, fade: 1.5))
        }
    }

    // MARK: Drawing

    /// The penguin in side view, facing `dir`. Built in local points (x forward, y up from the feet), then
    /// rocked by the waddle, laid down on its belly or back and squashed after landings.
    func build(into out: inout [Vertex], t: Float) {
        guard alpha > 0.01 else { return }
        let start = out.count
        let s = size
        let walking = act == .walk
        let sway: Float = walking ? sin(ph) * 0.11 : act == .wave ? sin(actT * 6) * 0.04 : 0
        let bob: Float = walking ? abs(cos(ph)) * 0.9 : 0
        let lean: Float = act == .getUp ? -0.15 * (1 - actT / max(0.1, actLen)) : hurry > 0 ? -0.12 : 0
        let la = min(1, abs(lie))
        let theta = -lie * .pi / 2 + tilt * la + (sway + lean) * (1 - la)
        let ct = cos(theta), st = sin(theta)
        let sq = 1 - 0.24 * squash, sw = 1 + 0.12 * squash
        let pv: Float = 7.5
        // Lying on its belly it keeps its head up, looking ahead: the head turns back up around the neck.
        var headMode = false
        let hRot = max(0, lie) * .pi / 2 * 0.8, hc = cos(hRot), hs = sin(hRot)
        let neck: (Float, Float) = (0.5, 15.5)
        func P(_ dx0: Float, _ dy0: Float) -> (Float, Float) {
            var dx = dx0, dy = dy0
            if headMode {
                let ux = dx - neck.0, uy = dy - neck.1
                dx = neck.0 + ux * hc - uy * hs; dy = neck.1 + ux * hs + uy * hc
            }
            let lx = dx * sw, ly = dy * sq - pv
            let rx = lx * ct - ly * st, ry = lx * st + ly * ct + pv
            return (x + rx * dir * s, y + (ry + bob * (1 - la)) * s)
        }
        func line(_ a: (Float, Float), _ b: (Float, Float), _ w: Float, _ c: RGBA) {
            Mesh.line(&out, P(a.0, a.1), P(b.0, b.1), width: w * s, color: c)
        }
        func tri(_ a: (Float, Float), _ b: (Float, Float), _ c: (Float, Float), _ col: RGBA) {
            Mesh.tri(&out, P(a.0, a.1), P(b.0, b.1), P(c.0, c.1), col)
        }
        /// An egg-shaped blob: `widen` makes it wider at the bottom. Lit from the top left (in its own frame).
        func blob(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, _ c: RGBA, _ rim: RGBA, widen: Float = 0, n: Int = 18) {
            let o = P(cx - rx * 0.15, cy + ry * 0.2)
            func pt(_ a: Float) -> (Float, Float) { P(cx + cos(a) * (rx - widen * sin(a)), cy + sin(a) * ry) }
            var prev = pt(0)
            for i in 1...n {
                let q = pt(Float(i) / Float(n) * 2 * .pi)
                Mesh.v(&out, o.0, o.1, c); Mesh.v(&out, prev.0, prev.1, rim); Mesh.v(&out, q.0, q.1, rim)
                prev = q
            }
        }
        func dot(_ cx: Float, _ cy: Float, _ r: Float, _ c: RGBA) { blob(cx, cy, r, r, c, c, n: 10) }
        /// A flipper hanging from `root` at angle `a` (radians in the body frame; −π/2 hangs down).
        func flipper(_ root: (Float, Float), _ a: Float, _ len: Float, _ w: Float, _ c: RGBA) {
            let dx = cos(a), dy = sin(a), nx = -dy, ny = dx
            let r0 = (root.0 + nx * w * 0.5, root.1 + ny * w * 0.5), r1 = (root.0 - nx * w * 0.5, root.1 - ny * w * 0.5)
            let m0 = (root.0 + dx * len * 0.55 + nx * w * 0.5, root.1 + dy * len * 0.55 + ny * w * 0.5)
            let m1 = (root.0 + dx * len * 0.55 - nx * w * 0.42, root.1 + dy * len * 0.55 - ny * w * 0.42)
            let tip = (root.0 + dx * len, root.1 + dy * len)
            tri(r0, r1, m1, c); tri(r0, m1, m0, c); tri(m0, m1, tip, c)
        }

        let back: RGBA = chick ? (0.56, 0.58, 0.64, 1) : (0.2, 0.22, 0.3, 1)
        let backRim: RGBA = chick ? (0.4, 0.42, 0.48, 1) : (0.06, 0.065, 0.09, 1)
        let headC: RGBA = (0.17, 0.18, 0.25, 1), headRim: RGBA = (0.05, 0.055, 0.08, 1)
        let belly: RGBA = (1, 1, 1, 1), bellyRim: RGBA = chick ? (0.82, 0.83, 0.88, 1) : (0.8, 0.85, 0.93, 1)
        let orange: RGBA = (1, 0.6, 0.12, 1), orangeDark: RGBA = (0.86, 0.42, 0.06, 1)
        let flipC: RGBA = chick ? (0.48, 0.5, 0.56, 1) : (0.13, 0.14, 0.2, 1)

        // Feet: step in turn while waddling, kick back while sliding, paddle in the air when on its back.
        var nearStep: Float = 0, farStep: Float = 0, nearLift: Float = 0, farLift: Float = 0
        if walking {
            nearStep = sin(ph) * 2.2; farStep = -nearStep
            nearLift = max(0, cos(ph)) * 1.6; farLift = max(0, -cos(ph)) * 1.6
        } else if act == .fallen {
            nearLift = max(0, sin(t * 18)) * 2.5; farLift = max(0, -sin(t * 18)) * 2.5
        } else if act == .slide && kickT > 0 {
            let k = sin((0.45 - kickT) / 0.45 * .pi)
            nearStep = -k * 2.5; nearLift = -k * 2.2; farStep = nearStep * 0.8; farLift = nearLift * 0.8
        }
        // Feet point ahead when standing and trail behind, soles up, when lying on the belly.
        let fdx = 1 - max(0, lie), fdy = -max(0, lie)
        let fn = max(0.01, (fdx * fdx + fdy * fdy).squareRoot())
        func foot(_ bx: Float, _ lift: Float, _ c: RGBA) {
            let ux = fdx / fn, uy = fdy / fn
            let heel = (bx - 1.2 * ux, 0.9 + lift - 1.2 * uy), toe = (bx + 4.2 * ux, 0.9 + lift + 4.2 * uy)
            line(heel, toe, 2, c)
            dot(toe.0, toe.1 + 0.1, 1.05, c)
        }

        // Flippers: hang at the sides and swing with the waddle; flap when hurrying or hopping; one
        // waves at a snowman; both swept back while sliding.
        var nearA: Float = -.pi / 2 - 0.2 + (walking ? sin(ph) * 0.16 : 0)
        var farA: Float = nearA - (walking ? sin(ph) * 0.3 : 0.1)
        if flap > 0.01 {
            let f = (0.5 + 0.5 * sin(t * 26 + seed)) * 1.25 * flap
            nearA += f; farA += f * 0.9
        }
        if act == .wave {
            let u = min(1, actT / 0.25) * min(1, max(0, (actLen - actT) / 0.25))
            nearA = -.pi / 2 - 0.28 + u * (2.3 + sin(actT * 13) * 0.45)
        }
        if act == .slide || (act == .air && diving) { nearA = -.pi / 2 - 0.12; farA = nearA - 0.08 }
        if act == .fallen { nearA = -.pi / 2 + 0.9 + sin(t * 14) * 0.4; farA = nearA - 0.5 }
        if act == .duck { nearA = -.pi / 2 + 1.2; farA = nearA }

        let hx: Float = 1.6, hy: Float = 21.6, hr: Float = chick ? 6.4 : 5.7
        // Far side first
        flipper((1.6, 16.2), farA, 10, 3.4, Mesh.mix(flipC, (0, 0, 0, 1), 0.35))
        foot(-0.8 + farStep, farLift, orangeDark)
        // Tail
        let tl = max(0, lie)
        tri((-6.4, 4.2), (-5.2, 1.8), (-10 + 4 * tl, 1.4 - 4.4 * tl), backRim)
        // Body, head and belly
        blob(0, 11, 7.4, 10.6, back, backRim, widen: 1.1)
        headMode = true
        blob(hx, hy, hr, hr * 0.96, headC, headRim)
        headMode = false
        blob(2.7, 9.0, 5.0, 8.4, belly, bellyRim)
        headMode = true
        if chick {
            // A fluffy chick: white face mask.
            blob(hx + 1.6, hy - 0.4, hr * 0.62, hr * 0.6, belly, (0.86, 0.87, 0.92, 1))
        }
        headMode = false
        // Scarf at the neck, with a tail that flutters behind
        if scarf {
            let red: RGBA = (0.86, 0.12, 0.16, 1), redDark: RGBA = (0.64, 0.07, 0.1, 1)
            let fl = sin(t * 9 + seed) * (walking || act == .slide ? 1.2 : 0.4)
            line((-3.8, 15.8), (-8.2, 11.8 + fl), 2.4, redDark)
            line((-6, 16.6), (6.6, 17.2), 3, red)
            line((-5.6, 17.6), (6.2, 18.2), 0.7, (1, 1, 1, 0.8))
        }
        foot(1.0 + nearStep, nearLift, orange)
        flipper((2.4, 16.4), nearA, 10.5, 3.8, flipC)

        // Face: in profile (looking ahead or back) or turned to you.
        headMode = true
        let k = headK
        let blink = act == .duck || (t + seed).truncatingRemainder(dividingBy: 3.4) < 0.12
        let eyeRing: RGBA = (1, 1, 1, 1), pupil: RGBA = (0.04, 0.04, 0.06, 1)
        let cheek: RGBA = (1, 0.55, 0.62, 0.4)
        func eye(_ ex: Float, _ ey: Float, ring: Bool) {
            if blink {
                line((ex - 1.3, ey - 0.1), (ex + 1.3, ey - 0.1), 0.7, pupil)
                return
            }
            if ring { dot(ex, ey, 1.95, eyeRing) }
            dot(ex + 0.3, ey, 1.2, pupil)
            dot(ex + 0.65, ey + 0.5, 0.48, (1, 1, 1, 1))
        }
        if abs(k) < 0.45 {
            // Facing you: two eyes, a small beak pointing down, rosy cheeks.
            eye(hx - 2.3, hy + 1, ring: !chick)
            eye(hx + 2.3, hy + 1, ring: !chick)
            dot(hx - 3.7, hy - 1.6, 1.15, cheek)
            dot(hx + 3.7, hy - 1.6, 1.15, cheek)
            tri((hx - 1.3, hy - 0.4), (hx + 1.3, hy - 0.4), (hx, hy - 2.8), orange)
        } else {
            let m: Float = k > 0 ? 1 : -1
            func fx(_ v: Float) -> Float { hx + (v - hx) * m }
            eye(fx(hx + 1.9), hy + 1.1, ring: !chick)
            if chick { dot(fx(hx + 1.2), hy - 1.6, 1.0, cheek) }
            let tip: Float = chick ? 3.2 : 4.6
            tri((fx(hx + hr - 1.6), hy + 0.7), (fx(hx + hr - 1.4), hy - 1.5), (fx(hx + hr - 1.4 + tip), hy - 0.5), orange)
            line((fx(hx + hr - 1.2), hy - 0.55), (fx(hx + hr - 1.6 + tip * 0.85), hy - 0.55), 0.45, orangeDark)
        }
        if hat {
            // A Santa hat flopping back, with a white brim and a bobble.
            let red: RGBA = (0.88, 0.1, 0.13, 1)
            let m: Float = k < -0.45 ? -1 : 1
            func fx(_ v: Float) -> Float { hx + (v - hx) * m }
            let flop = sin(t * 5 + seed) * (walking ? 0.6 : 0.2)
            tri((fx(hx - 4.8), hy + 3.4), (fx(hx + 4.6), hy + 3.9), (fx(hx - 6.8 + flop), hy + 9.6), red)
            line((fx(hx - 5.4), hy + 3.4), (fx(hx + 5.2), hy + 4.0), 2.3, (1, 1, 1, 1))
            dot(fx(hx - 6.9 + flop), hy + 9.7, 1.5, (1, 1, 1, 1))
        }

        let a = alpha * (ghost ? 0.3 : 1)
        if a < 1 { for i in start..<out.count { out[i].a *= a } }
    }
}
