import CoreGraphics
import Foundation

/// A little skier. Skiers ride along the snow at the bottom of the screen (skating at a steady pace),
/// jump up onto the Dock, ride across its snow, jump off the end (sometimes with a trick) and ski on
/// until they leave the screen. They leave a faint track in the snow. (They can also ride down a hill
/// on a window – `findHill` – which is how they started out.)
@MainActor
struct Skier {
    enum Phase { case riding, flying, landed }
    enum Trick { case none, flip, spin, grab }

    static let height: Float = 25            // about how tall it is standing (points)
    static let minHill: Float = 25           // a hill needs at least this much snow
    private static let slopeG: Float = 560   // gravity along the slope
    private static let airG: Float = 700
    private static let drag: Float = 0.3     // per second
    private static let minSpeed: Float = 60, maxSpeed: Float = 360
    private static let jackets: [RGBA] = [(0.9, 0.16, 0.2, 1), (0.16, 0.45, 0.95, 1), (1, 0.55, 0.1, 1),
                                          (0.14, 0.68, 0.36, 1), (0.6, 0.3, 0.86, 1), (0.98, 0.78, 0.12, 1)]

    var phase: Phase = .riding
    var pileKey: Int
    var hostRect: CGRect           // the window's frame at the start – if it changes, the skier falls
    var x: Float, y: Float         // between the boots, on the snow
    var dir: Float                 // +1 skis to the right, −1 to the left
    var speed: Float = 28          // along the slope (riding) or horizontal (landed)
    var vx: Float = 0, vy: Float = 0
    var angle: Float = 0           // tilt of the skis (follows the slope), radians
    var trick: Trick = .none
    var trickDur: Float = 1
    var airT: Float = 0
    var landedT: Float = 0
    var squash: Float = 0          // knees giving way after a landing, 0…1
    var tumbling = false           // the window underneath went away
    var alpha: Float = 0
    var lastBin = -1
    var screenW: Float = 10_000
    let jacket: RGBA, hat: RGBA
    let helmet: Bool
    var cruise: Float = 0          // > 0: riding along the bottom, skating at least this fast
    var ghost = false              // riding behind a window that reaches the bottom edge (drawn faded)

    /// A skier that rides along the bottom drift `ground`, entering at the screen edge.
    static func alongBottom(_ ground: Pile, dir: Float, width W: Float) -> Skier {
        var s = Skier(pile: ground, x: dir > 0 ? 6 : W - 6, dir: dir)
        s.cruise = Float.random(in: 150...210)
        s.speed = s.cruise
        return s
    }

    init(pile: Pile, x: Float, dir: Float) {
        pileKey = pile.key
        hostRect = pile.rect
        self.x = x
        self.dir = dir
        y = Float(pile.rect.maxY) + (Self.surface(pile, x) ?? 0)
        let j = Int.random(in: 0..<Self.jackets.count)
        jacket = Self.jackets[j]
        hat = Self.jackets[(j + Int.random(in: 1..<Self.jackets.count)) % Self.jackets.count]
        helmet = Bool.random()
        angle = atan(Self.slope(pile, x))
    }

    // MARK: Hill

    /// Snow height of bin `b` as drawn (a window in front limits it).
    private static func eff(_ p: Pile, _ b: Int) -> Float {
        b < p.limit.count ? min(p.bins[b], p.limit[b]) : p.bins[b]
    }

    /// Height smoothed over five visible bins (nil if bin `b` isn't visible).
    private static func smooth(_ p: Pile, _ b: Int) -> Float? {
        guard b >= 0, b < p.bins.count, p.visible[b] else { return nil }
        let w: [Float] = [1, 2, 3, 2, 1]
        var sum: Float = 0, n: Float = 0
        for k in -2...2 {
            let i = b + k
            guard i >= 0, i < p.bins.count, p.visible[i] else { continue }
            sum += eff(p, i) * w[k + 2]; n += w[k + 2]
        }
        return sum / n
    }

    /// Smoothed snow height at x (relative to the window's top edge), nil outside the visible drift.
    static func surface(_ p: Pile, _ x: Float) -> Float? {
        let u = (x - Float(p.rect.minX)) / Simulation.binW - 0.5
        let b0 = Int(u.rounded(.down))
        let t = u - Float(b0)
        switch (smooth(p, b0), smooth(p, b0 + 1)) {
        case let (a?, b?): return a + (b - a) * t
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// dh/dx of the smoothed surface.
    static func slope(_ p: Pile, _ x: Float) -> Float {
        guard let l = surface(p, x - 3), let r = surface(p, x + 3) else { return 0 }
        return (r - l) / 6
    }

    /// The tallest hill on a window: where to start and which way to go (the longer way down).
    static func findHill(in piles: [Pile], ceiling: Float) -> (pile: Pile, x: Float, dir: Float)? {
        var best: (Pile, Int, Float)?
        for p in piles where p.kind == .window && p.parkedSince == nil {
            for b in p.bins.indices where p.visible[b] {
                guard let h = smooth(p, b), h >= minHill, h > (best?.2 ?? 0),
                      Float(p.rect.maxY) + h + height + 4 <= ceiling else { continue }
                best = (p, b, h)
            }
        }
        guard let (p, b, h) = best else { return nil }
        // Count the visible run and the drop on each side.
        // A run that ends in the middle of the window runs into a window in front – avoid that side.
        func run(_ step: Int) -> (len: Int, drop: Float, blocked: Bool) {
            var i = b, low = h
            while i + step >= 0 && i + step < p.bins.count && p.visible[i + step] {
                i += step
                low = min(low, smooth(p, i) ?? low)
            }
            let next = i + step
            return (abs(i - b), h - low, next >= 6 && next < p.bins.count - 6)
        }
        let l = run(-1), r = run(1)
        guard max(l.len, r.len) >= 8 else { return nil }
        let score = { (s: (len: Int, drop: Float, blocked: Bool)) in Float(s.len) * 4 + s.drop * 2 }
        let dir: Float
        if l.len < 6 || r.len < 6 {
            dir = l.len < 6 ? 1 : -1
        } else if l.blocked != r.blocked {
            dir = l.blocked ? 1 : -1
        } else if abs(score(l) - score(r)) < 0.2 * max(score(l), score(r)) {
            dir = Bool.random() ? 1 : -1
        } else {
            dir = score(r) > score(l) ? 1 : -1
        }
        return (p, Float(p.rect.minX) + (Float(b) + 0.5) * Simulation.binW, dir)
    }

    // MARK: Step

    typealias Floor = (Float, Float) -> (top: Float, pile: Pile?)

    /// An auto-hiding Dock came up right under the skier: it is launched into the air off the Dock.
    mutating func liftedByDock(to top: Float) {
        y = top
        phase = .flying
        vx = dir * max(speed, 60); vy = 160
        airT = 0; trick = .none
    }

    /// Advances the skier. `host` is the drift it started on (nil if gone), `floor(x, y)` the top of the
    /// highest surface (with its snow) below a point. Returns false when the skier is gone.
    mutating func step(dt rawDt: Float, host: Pile?, width W: Float, debris: inout [Debris], floor: Floor) -> Bool {
        let dt = min(rawDt, 1.0 / 20)
        screenW = W
        squash = max(0, squash - dt * 3.5)
        if landedT == 0 { alpha = min(1, alpha + dt / 0.3) }      // fades in; out after landing
        switch phase {
        case .riding: ride(dt, host: host, debris: &debris, floor: floor)
        case .flying: fly(dt, host: host, debris: &debris, floor: floor)
        case .landed:
            landedT += dt
            speed = max(0, speed - (speed * 0.45 + 12) * dt)
            x += dir * speed * dt
            let f = floor(x, y + 6)
            if f.top < y - 4 {
                // The surface ends: off the edge again.
                phase = .flying; vx = dir * max(speed, 30); vy = 0; airT = 0; trick = .none
            } else {
                y = f.top
                if let p = f.pile { carve(p) }
                angle += (0 - angle) * min(1, dt * 10)
                if speed > 60 { spray(&debris, amount: speed * dt * 0.08) }
            }
            if landedT > 1.1 { alpha = max(0, 1 - (landedT - 1.1) / 0.5) }
            if alpha <= 0 { return false }
        }
        return x > -50 && x < W + 50 && y > -40
    }

    private mutating func ride(_ dt: Float, host: Pile?, debris: inout [Debris], floor: Floor) {
        guard let p = host, p.rect == hostRect, p.parkedSince == nil else {
            // The window moved or went away: the skier falls with it.
            tumbling = true
            takeOff(vx: dir * speed * 0.5, vy: 40, floor: floor, trick: false)
            return
        }
        let sl = Self.slope(p, x)
        let s = sl * dir                          // > 0 uphill
        let inv = 1 / (1 + s * s).squareRoot()
        speed += (-Self.slopeG * s * inv - Self.drag * speed) * dt
        speed = min(Self.maxSpeed, max(Self.minSpeed, speed))
        if cruise > 0 { speed = max(speed, cruise) }        // skating along the bottom
        let vh = speed * inv
        let nx = x + dir * vh * dt
        // End of the visible drift ahead: jump.
        let ahead = Int(((nx + dir * 2) - Float(p.rect.minX)) / Simulation.binW)
        guard ahead >= 0, ahead < p.bins.count, p.visible[ahead], let h = Self.surface(p, nx) else {
            if cruise > 0 && p.kind == .ground {
                if ahead < 0 || ahead >= p.bins.count {
                    // The edge of the screen: ski off it.
                    x = nx; y = Float(p.rect.maxY); ghost = false
                    return
                }
                // Something hides the bottom drift ahead: the Dock (jump up onto it) or a window that
                // reaches down to the bottom edge (ride on behind it, faded).
                let ob = floor(nx + dir * 26, y + 140)      // only what's within jumping height
                let rise = ob.top - y
                if rise > 8 && rise < 140 {
                    let up = (2 * Self.airG * (rise + 24)).squareRoot()
                    takeOff(vx: dir * max(vh, 170), vy: up, floor: floor, trick: false)
                    return
                }
                x = nx; y = Float(p.rect.maxY); ghost = true
                return
            }
            takeOff(vx: dir * max(vh, 120), vy: vh * sl * dir + 120, floor: floor, trick: true)
            return
        }
        ghost = false
        x = nx
        let base = Float(p.rect.maxY)
        // Fast over a sharp crest: the snow drops away faster than gravity pulls – a short hop.
        if speed > 170, let h2 = Self.surface(p, x + dir * 10) {
            let flight = 10 / vh
            let ballistic = h + sl * dir * 10 - 0.5 * Self.airG * flight * flight
            if h2 < ballistic - 4 {
                y = base + h
                takeOff(vx: dir * vh, vy: vh * sl * dir, floor: floor, trick: false)
                return
            }
        }
        y = base + h
        angle += (max(-0.95, min(0.95, atan(sl))) - angle) * min(1, dt * 14)
        carve(p)
        if speed > 110 { spray(&debris, amount: speed * dt * 0.12) }
    }

    private mutating func takeOff(vx: Float, vy: Float, floor: Floor, trick wantsTrick: Bool) {
        phase = .flying
        self.vx = vx
        self.vy = vy
        airT = 0
        trick = .none
        guard wantsTrick, !tumbling else { return }
        // A jump: take off a little slower if that keeps the landing on the screen, and fit a trick
        // into the time in the air.
        let full = flight(vx: vx, floor: floor)
        var t = full.time
        if !full.onScreen {
            for f: Float in [0.8, 0.65, 0.5, 0.4] {
                let slower = flight(vx: vx * f, floor: floor)
                if slower.onScreen { self.vx = vx * f; t = slower.time; break }
            }
        }
        if t > 0.75 {
            trick = [.flip, .flip, .spin, .grab].randomElement() ?? .none
            trickDur = min(t * 0.78, 1.1)
        } else if t > 0.45 && Bool.random() {
            trick = .grab
            trickDur = t * 0.8
        }
    }

    /// How long a jump with horizontal speed `vx` (and the current vy) stays in the air, and whether it
    /// comes down on the screen.
    private func flight(vx: Float, floor: Floor) -> (time: Float, onScreen: Bool) {
        var px = x, py = y, pvy = vy, t: Float = 0
        let h: Float = 1.0 / 60
        while t < 3 {
            let oy = py
            pvy -= Self.airG * h; px += vx * h; py += pvy * h; t += h
            if px < 30 || px > screenW - 30 { return (t, false) }
            if pvy < 0 && py <= floor(px, oy).top { return (t, true) }
        }
        return (t, false)
    }

    private mutating func fly(_ dt: Float, host: Pile?, debris: inout [Debris], floor: Floor) {
        airT += dt
        let oy = y
        vy -= Self.airG * dt
        x += vx * dt
        y += vy * dt
        let target = max(-0.6, min(0.6, atan(vy / max(1, abs(vx))) * (vx < 0 ? -1 : 1))) * 0.5
        angle += (target - angle) * min(1, dt * 6)
        guard vy < 0 else { return }
        let f = floor(x, oy)
        guard y <= f.top else { return }
        y = f.top
        trick = .none
        if cruise > 0, !tumbling, let p = f.pile, p.parkedSince == nil, Self.surface(p, x) != nil {
            // Riding along the bottom: land on the Dock or back on the ground and keep going.
            pileKey = p.key
            hostRect = p.rect
            phase = .riding
            speed = max(cruise, abs(vx))
            squash = 0.8
            lastBin = -1
            if debris.count < 9000 {
                for _ in 0..<10 {
                    debris.append(Debris(x: x + Float.random(in: -8...8), y: y + 1,
                                         vx: dir * Float.random(in: 0...80) + Float.random(in: -40...40),
                                         vy: Float.random(in: 30...110), size: Float.random(in: 1.4...2.8),
                                         alpha: 0.9, lands: false, fade: 1.3))
                }
            }
            return
        }
        if !tumbling, let p = f.pile, p === host, p.rect == hostRect, Self.surface(p, x) != nil {
            // Back on the same hill after a hop: keep riding.
            phase = .riding
            speed = max(Self.minSpeed, abs(vx))
            squash = 0.5
            return
        }
        phase = .landed
        speed = abs(vx)
        squash = 1
        tumbling = false
        if debris.count < 9000 {
            for _ in 0..<16 {
                debris.append(Debris(x: x + Float.random(in: -8...8), y: y + 1,
                                     vx: dir * Float.random(in: 0...90) + Float.random(in: -50...50),
                                     vy: Float.random(in: 30...130), size: Float.random(in: 1.4...3),
                                     alpha: 0.9, lands: false, fade: 1.3))
            }
        }
    }

    /// A faint ski track: lower each bin the skier crosses a little.
    private mutating func carve(_ p: Pile) {
        let b = Int((x - Float(p.rect.minX)) / Simulation.binW)
        guard b >= 0, b < p.bins.count, b != lastBin else { return }
        lastBin = b
        if p.visible[b] && p.bins[b] > 2 { p.bins[b] -= 0.7; p.dirty = true }
    }

    /// Powder kicked up behind the skis.
    private func spray(_ debris: inout [Debris], amount: Float) {
        guard debris.count < 9000 else { return }
        var n = Int(amount)
        if Float.random(in: 0..<1) < amount - Float(n) { n += 1 }
        for _ in 0..<n {
            debris.append(Debris(x: x - dir * Float.random(in: 4...9), y: y + 1.5,
                                 vx: -dir * speed * Float.random(in: 0.08...0.3), vy: Float.random(in: 20...80),
                                 size: Float.random(in: 1...2.2), alpha: 0.8, lands: false, fade: 1.8))
        }
    }

    // MARK: Drawing

    /// The skier in side view, facing `dir`. Built in local points (x forward, y up from the snow), then
    /// tilted with the slope, rotated for a flip and squeezed for a spin.
    func build(into out: inout [Vertex], t: Float) {
        guard alpha > 0.01 else { return }
        let start = out.count
        // Trick progress
        let prog = trick == .none ? 0 : min(1, airT / max(0.1, trickDur))
        let ease = prog * prog * (3 - 2 * prog)
        let flip: Float = trick == .flip ? dir * 2 * .pi * ease : 0
        let squeeze: Float = trick == .spin ? cos(2 * .pi * ease) : 1
        let grab: Float = trick == .grab ? sin(.pi * min(1, prog * 1.15)) : 0
        let k = dir * (abs(squeeze) < 0.12 ? (squeeze < 0 ? -0.12 : 0.12) : squeeze)
        let ca = cos(angle), sa = sin(angle), cf = cos(flip), sf = sin(flip)
        let pivot: Float = 11
        func P(_ dx: Float, _ dy: Float) -> (Float, Float) {
            // flip around the hips, then tilt with the slope around the boots
            let lx = dx * k, ly = dy - pivot
            let rx = lx * cf - ly * sf, ry = lx * sf + ly * cf + pivot
            return (x + rx * ca - ry * sa, y + rx * sa + ry * ca)
        }
        func line(_ a: (Float, Float), _ b: (Float, Float), _ w: Float, _ c: RGBA) { Mesh.line(&out, P(a.0, a.1), P(b.0, b.1), width: w, color: c) }
        func fan(_ c: (Float, Float), _ r: Float, _ a0: Float, _ a1: Float, _ col: RGBA, _ n: Int = 10) {
            let o = P(c.0, c.1)
            var prev = P(c.0 + cos(a0) * r, c.1 + sin(a0) * r)
            for i in 1...n {
                let a = a0 + (a1 - a0) * Float(i) / Float(n)
                let q = P(c.0 + cos(a) * r, c.1 + sin(a) * r)
                Mesh.tri(&out, o, prev, q, col)
                prev = q
            }
        }
        func dot(_ c: (Float, Float), _ r: Float, _ col: RGBA) { fan(c, r, 0, 2 * .pi, col) }
        func shade(_ c: RGBA, _ f: Float) -> RGBA { (c.0 * f, c.1 * f, c.2 * f, c.3) }

        // Pose: knees bend more at speed, in a grab and after a landing.
        let fast = phase == .riding ? min(1, speed / Self.maxSpeed) : (phase == .flying ? 0.4 : 0.2)
        let c = min(1, 0.22 + 0.4 * fast + 0.6 * grab + 0.5 * squash)
        let ankle: (Float, Float) = (0.2, 3)
        let knee: (Float, Float) = (3.4 + 1.6 * c, 8.2 - 1.6 * c)
        let hip: (Float, Float) = (-2.2 - 1.2 * c, 11.8 - 2.6 * c)
        let shoulder: (Float, Float) = (0.6 + 2.2 * c, 18.6 - 3.4 * c)
        let head: (Float, Float) = (shoulder.0 + 1.3 + 0.6 * c, shoulder.1 + 3.7)
        let flail = tumbling ? sin(t * 22) * 2.5 : 0
        let hand: (Float, Float) = tumbling ? (shoulder.0 + 2 + flail, shoulder.1 + 6)
            : grab > 0.3 ? (5 + 2 * grab, 3.5) : (6.2 + 1.2 * c, 12.6 - 2.2 * c)
        let farHand: (Float, Float) = tumbling ? (shoulder.0 - 3 - flail, shoulder.1 + 5.5) : (hand.0 - 1.4, hand.1 + 0.6)
        // Poles: down and back when slow, tucked under the arms when fast or in the air.
        let tuck = tumbling ? 0.2 : min(1, fast * 1.4 + (phase == .flying ? 0.5 : 0))
        let pdx = -(0.55 + 0.4 * tuck), pdy = -(0.83 - 0.6 * tuck)
        let pn = (pdx * pdx + pdy * pdy).squareRoot()
        func poleTip(_ h: (Float, Float)) -> (Float, Float) { (h.0 + pdx / pn * 14, h.1 + pdy / pn * 14) }

        let pants: RGBA = (0.17, 0.19, 0.26, 1), pantsFar: RGBA = (0.11, 0.12, 0.17, 1)
        let boot: RGBA = (0.08, 0.08, 0.1, 1)
        let ski: RGBA = (0.14, 0.15, 0.19, 1), skiFar: RGBA = (0.3, 0.32, 0.37, 1)
        let pole: RGBA = (0.72, 0.75, 0.8, 1)
        let glove: RGBA = (0.1, 0.1, 0.12, 1)
        let skin: RGBA = (0.98, 0.8, 0.68, 1)

        // Far side first: ski, pole, leg, arm
        let fo: Float = 2.4, fu: Float = 0.9               // the far ski sits a little ahead and higher
        line((-10 + fo, 1 + fu), (9.5 + fo, 1 + fu), 1.5, skiFar)
        line((9.5 + fo, 1 + fu), (12 + fo, 2.8 + fu), 1.4, skiFar)
        line(farHand, poleTip(farHand), 0.9, shade(pole, 0.75))
        line((hip.0 + 0.8, hip.1), (knee.0 + fo * 0.5, knee.1 + fu), 3.2, pantsFar)
        line((knee.0 + fo * 0.5, knee.1 + fu), (ankle.0 + fo, ankle.1 + fu), 3, pantsFar)
        line((ankle.0 + fo - 1.2, 2.4 + fu), (ankle.0 + fo + 2.4, 2.4 + fu), 2.6, boot)
        line(shoulder, farHand, 2.3, shade(jacket, 0.7))
        dot(farHand, 1.3, glove)

        // Near ski with a coloured tip
        line((-10, 1), (9.5, 1), 1.6, ski)
        line((9.5, 1), (12, 2.8), 1.5, ski)
        line((5, 1), (9.5, 1), 1.6, jacket)
        // Near leg
        line(hip, knee, 3.4, pants)
        line(knee, ankle, 3.1, pants)
        dot(knee, 1.6, pants)
        line((ankle.0 - 1.4, 2.3), (ankle.0 + 2.6, 2.3), 2.8, boot)
        // Body: jacket with a darker hem, rounded at the shoulders and hips
        dot(hip, 2.6, shade(jacket, 0.8))
        line(hip, shoulder, 5.6, jacket)
        dot(shoulder, 2.8, jacket)
        line((hip.0 + (shoulder.0 - hip.0) * 0.08, hip.1 + (shoulder.1 - hip.1) * 0.08),
             (hip.0 + (shoulder.0 - hip.0) * 0.22, hip.1 + (shoulder.1 - hip.1) * 0.22), 5.8, shade(jacket, 0.78))
        // Head: face, then a helmet or a bobble hat, then goggles
        line(shoulder, (head.0 - 0.3, head.1 - 1.5), 2, skin)
        dot(head, 3, skin)
        if helmet {
            fan((head.0 - 0.2, head.1 + 0.2), 3.5, -0.12, .pi + 0.45, hat, 12)
            line((head.0 - 3.2, head.1 + 1.0), (head.0 + 3.3, head.1 + 0.3), 0.7, shade(hat, 0.75))
        } else {
            fan((head.0 - 0.2, head.1 + 0.4), 3.3, 0, .pi, hat, 12)
            line((head.0 - 3.6, head.1 + 0.6), (head.0 + 3.2, head.1 + 0.6), 1.5, (0.96, 0.96, 0.96, 1))
            dot((head.0 - 0.9, head.1 + 4.1), 1.5, (0.97, 0.97, 0.97, 1))
        }
        line((head.0 - 2.8, head.1 + 0.4), (head.0 + 0.8, head.1 + 0.4), 0.9, (0.12, 0.12, 0.15, 1))  // strap
        line((head.0 + 0.6, head.1 + 0.4), (head.0 + 3.7, head.1 + 0.4), 2.3, (0.12, 0.12, 0.15, 1))
        line((head.0 + 1.3, head.1 + 0.5), (head.0 + 3.3, head.1 + 0.5), 1.2, (1, 0.62, 0.16, 1))
        // Near arm and pole
        line(hand, poleTip(hand), 1, pole)
        line(poleTip(hand), (poleTip(hand).0 + 0.4, poleTip(hand).1 + 1.6), 2.2, shade(pole, 0.7))
        let elbow: (Float, Float) = tumbling ? (shoulder.0 + 2.5, shoulder.1 + 2) : ((shoulder.0 + hand.0) / 2 + 0.6, (shoulder.1 + hand.1) / 2 - 0.8)
        line(shoulder, elbow, 2.5, shade(jacket, 0.88))
        line(elbow, hand, 2.4, shade(jacket, 0.88))
        dot(hand, 1.4, glove)

        let a = alpha * (ghost ? 0.3 : 1)
        if a < 1 { for i in start..<out.count { out[i].a *= a } }
    }
}
