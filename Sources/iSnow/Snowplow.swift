import Foundation

/// The snowplow truck. It comes by itself (autopilot) when the snow at the bottom gets deep, drives
/// across the whole screen – up onto the Dock and along it too – and ploughs: snow under the blade is
/// pushed ahead (a ridge builds up in front of it) and part of it is thrown up and aside as spray, so
/// the road behind it is clear. (`input` is a leftover hook for manual driving; nothing sets it now.)
struct Snowplow {
    var x: Float = -120             // centre of the truck (without the blade)
    var vx: Float = 0
    var facing: Float = 1           // +1 drives right, −1 left (the blade is always in front)
    var input: Float = 0            // −1, 0, +1 from the arrow keys
    var idle: Float = 0             // seconds without input
    var visible = false
    /// Autopilot: drives across the whole screen by itself (+1 to the right, −1 to the left), then leaves.
    private(set) var autopilot: Float = 0

    private var leaving = false
    private var leaveDir: Float = 0
    private var roll: Float = 0             // wheel rotation (radians)
    private var alpha: Float = 1            // fades while it drives in front of the Dock
    private var lift: Float = 0             // height it drives at: 0 on the ground, the Dock's top on the Dock
    private var onDock = false              // which drift the blade is working on (for lastFront)
    private var lastFront: Float?           // blade front in the previous frame (so fast frames don't skip bins)
    private var sprayAcc: Float = 0         // snow waiting to be thrown as spray (bin-heights)
    private var puffTimer: Float = 0
    private var puffs: [Puff] = []

    private struct Puff { var x, y, vx, age: Float }

    // Geometry in points at scale 1, measured forward from `x` (the blade side is +).
    private static let rear: Float = 46
    private static let bladeFront: Float = 56
    private static let wheelR: Float = 8.5
    private static let wheels: [Float] = [-30, 24]
    private static let topSpeed: Float = 260
    private static let autoSpeed: Float = 170
    private static let idleTimeout: Float = 8
    private static let ridgeTop: Float = 24          // the ridge in front of the blade grows up to this
    private static let ridgeMax: Float = 36          // … or a bit above deep snow, but never more than this
    private static let puffLife: Float = 1.1

    var isMoving: Bool { visible }

    /// Called every frame. `ground` is the bottom drift (bins of `binW` points from x = 0).
    /// Send the truck across the screen to clear the bottom (does nothing while it's already out).
    mutating func startAutopilot(leftToRight: Bool, screenWidth W: Float) {
        guard !visible else { return }
        autopilot = leftToRight ? 1 : -1
        visible = true
        facing = autopilot
        x = leftToRight ? -Self.bladeFront - 4 : W + Self.bladeFront + 4
        vx = autopilot * 120
        idle = 0
        leaving = false
        lastFront = nil
        sprayAcc = 0
        puffs = []
        alpha = 1
    }

    /// `dock` is the Dock's frame (local coordinates) – the truck climbs onto it and clears its snow
    /// (`dockPile`) too.
    mutating func step(dt: Float, screenWidth W: Float, ground: Pile?, binW: Float, debris: inout [Debris],
                       dock: CGRect? = nil, dockPile: Pile? = nil) {
        guard dt > 0 else { return }
        if input != 0 { autopilot = 0 }          // the arrow keys take over
        if !visible {
            guard input != 0 else { return }
            // Drive in from the edge behind the direction pressed.
            visible = true
            facing = input
            x = input > 0 ? -Self.bladeFront - 4 : W + Self.bladeFront + 4
            vx = input * 150
            idle = 0
            leaving = false
            lastFront = nil
            sprayAcc = 0
            puffs = []
            alpha = 1
        }
        if input != 0 || autopilot != 0 { idle = 0; leaving = false } else { idle += dt }
        if !leaving && autopilot == 0 && idle > Self.idleTimeout {
            leaving = true
            leaveDir = x < W / 2 ? -1 : 1
        }

        // Where the truck wants to go: off the screen, in from the edge, or where the arrow keys say.
        let lo = Self.bladeFront, hi = W - Self.bladeFront
        var dir: Float = 0, speed: Float = 0
        if autopilot != 0 {
            dir = autopilot; speed = Self.autoSpeed
        } else if leaving {
            dir = leaveDir; speed = 220
        } else if x < lo - 0.5 || x > hi + 0.5 {
            dir = x < lo ? 1 : -1
            speed = input == dir ? Self.topSpeed : 150
        } else if input != 0 {
            dir = input; speed = Self.topSpeed
        }
        let before = vx
        if dir != 0 && dir != facing {
            // Stop, then turn around – the blade always faces the way it drives.
            vx = Self.approach(vx, 0, 900 * dt)
            if abs(vx) < 12 { facing = dir; lastFront = nil }
        } else if dir != 0 {
            vx = Self.approach(vx, dir * speed, (vx * dir < 0 ? 900 : 620) * dt)
        } else {
            vx = Self.approach(vx, 0, 480 * dt)
        }
        let oldX = x
        x += vx * dt
        if autopilot != 0 {
            // Autopilot: straight across and out the other side (the ridge goes off the edge with it).
            if (autopilot > 0 && x > W + Self.bladeFront + 12) || (autopilot < 0 && x < -Self.bladeFront - 12) {
                visible = false
                autopilot = 0
                vx = 0
                lastFront = nil
                puffs = []
                return
            }
        } else if !leaving {
            // Keep it on the screen once it is in.
            if vx > 0 && x > hi && oldX <= hi + 0.5 { x = hi; vx = 0 }
            if vx < 0 && x < lo && oldX >= lo - 0.5 { x = lo; vx = 0 }
        } else if x < -Self.bladeFront - 12 || x > W + Self.bladeFront + 12 {
            // Gone.
            visible = false
            vx = 0
            idle = 0
            leaving = false
            lastFront = nil
            puffs = []
            return
        }
        roll += (x - oldX) / Self.wheelR

        // Over the Dock it drives up a short ramp and along the Dock's top edge.
        var targetLift: Float = 0
        if let d = dock, d.minY < 20 {
            let ramp: Float = 34
            let inside = min(x - Float(d.minX), Float(d.maxX) - x)
            targetLift = Float(d.maxY) * max(0, min(1, (inside + ramp * 0.5) / ramp))
        }
        lift = targetLift
        let nowOnDock = dock != nil && lift > Float(dock!.maxY) * 0.8
        if nowOnDock != onDock { onDock = nowOnDock; lastFront = nil }

        if onDock, let dp = dockPile, let d = dock {
            plough(dp, origin: Float(d.minX), binW: binW, debris: &debris)
        } else if !onDock, lift < 2, let g = ground {
            plough(g, origin: 0, binW: binW, debris: &debris)
        }

        // Fade while it is at ground level in front of the Dock (or a window reaching the bottom edge).
        var target: Float = 1
        if let g = ground, lift < 4 {
            let b = Int(x / binW)
            if b >= 0 && b < g.visible.count && !g.visible[b] { target = 0.3 }
        }
        alpha = Self.approach(alpha, target, 3 * dt)

        // Exhaust: a puff now and then, quicker while accelerating.
        let revving = abs(vx - before) > 1 || abs(vx) > 30
        puffTimer += dt * (revving ? 3 : 1)
        if puffTimer > 0.4 {
            puffTimer = 0
            puffs.append(Puff(x: x - facing * 8, y: 48, vx: -facing * 14 - vx * 0.15, age: 0))
        }
        var i = 0
        while i < puffs.count {
            puffs[i].age += dt
            puffs[i].x += puffs[i].vx * dt
            puffs[i].y += 22 * dt
            if puffs[i].age > Self.puffLife { puffs.swapAt(i, puffs.count - 1); puffs.removeLast() } else { i += 1 }
        }
    }

    /// The blade scrapes the bins it passed over since the last frame. The snow goes into a ridge
    /// right ahead of it (never above the drift's cap/limit); the overflow and a bit more fly as spray.
    private mutating func plough(_ g: Pile, origin: Float, binW: Float, debris: inout [Debris]) {
        let d = facing
        // The scraped range ends a little inside the curled top, so the ridge leans on the blade. It reaches
        // back under the whole truck: snow that slides off the ridge's back (or falls) under it is taken along.
        // Positions are relative to the drift's left edge (`origin`); spray is placed in screen coordinates.
        let front = x - origin + d * (Self.bladeFront - 3), back = x - origin - d * Self.rear
        let base = Float(g.rect.maxY)
        let prev = lastFront ?? front
        lastFront = front
        guard vx * d > 4 else { return }            // only while driving forward
        let a = d > 0 ? min(back, prev) : front
        let b = d > 0 ? front : max(back, prev)
        let n = g.bins.count
        let i0 = max(0, Int((a / binW - 0.5).rounded(.up)))
        let i1 = min(n - 1, Int((b / binW - 0.5).rounded(.down)))
        guard i0 <= i1, i1 < g.visible.count else { return }
        var load: Float = 0
        for i in i0...i1 where g.visible[i] && g.bins[i] > 0 {
            load += g.bins[i]
            g.bins[i] = 0
        }
        guard load > 0.02 else { return }
        g.dirty = true

        // The ridge: a few bins ahead of the blade, tallest right at the blade.
        var spare = load * 0.85
        var thrown = load * 0.15
        let first = d > 0 ? i1 + 1 : i0 - 1
        // It stands out of deep snow too: a bit taller than the drift just beyond it.
        let beyond = first + Int(d) * 6
        let deep = beyond >= 0 && beyond < n ? g.bins[beyond] : 0
        let ridgeTop = min(Self.ridgeMax, max(Self.ridgeTop, deep + 8))
        for k in 0..<5 {
            let j = first + Int(d) * k
            // It never grows in front of the Dock.
            guard spare > 0, j >= 0, j < n, j < g.visible.count, g.visible[j] else { break }
            let lim = j < g.limit.count ? min(g.cap, max(0, g.limit[j])) : g.cap
            let top = min(lim, ridgeTop - Float(k) * 4.5)
            let add = min(spare, max(0, top - g.bins[j]))
            g.bins[j] += add
            spare -= add
        }
        thrown += spare

        // Spray from the top of the blade – only where snow is drawn (not in front of the Dock).
        let fb = Int(front / binW)
        guard fb >= 0, fb < n, fb < g.visible.count, g.visible[fb] else { return }
        sprayAcc += thrown
        var budget = min(40, max(0, 8800 - debris.count))
        let speed = abs(vx)
        while sprayAcc > 1.2 && budget > 0 {
            if Bool.random() {
                // A clump that lands further ahead (and gets ploughed again) – it always outruns the truck,
                // so nothing lands on the cleared road.
                let size = Float.random(in: 2.4...5)
                debris.append(Debris(x: origin + front + d * Float.random(in: 0...6), y: base + Float.random(in: 14...26),
                                     vx: d * (speed + Float.random(in: 70...200)), vy: Float.random(in: 110...260),
                                     size: size, alpha: 1, lands: true))
                sprayAcc -= size * 0.5
            } else {
                // Powder thrown aside – out of the picture, it just fades.
                debris.append(Debris(x: origin + front + d * Float.random(in: -4...4), y: base + Float.random(in: 16...28),
                                     vx: d * Float.random(in: 10...150) + Float.random(in: -50...50),
                                     vy: Float.random(in: 80...240), size: Float.random(in: 1.5...4), alpha: 0.9,
                                     lands: false, fade: 1.1))
                sprayAcc -= 1.5
            }
            budget -= 1
        }
        if budget == 0 { sprayAcc = min(sprayAcc, 20) }     // too much at once: the rest just vanishes
    }

    private static func approach(_ v: Float, _ target: Float, _ step: Float) -> Float {
        v < target ? min(target, v + step) : max(target, v - step)
    }

    // MARK: - Drawing

    func build(into out: inout [Vertex], t: Float) {
        let start = out.count
        let d = facing, cx = x
        let shake = sin(t * 23) * 0.6 * min(1, abs(vx) / Self.topSpeed)    // the body rattles a little on the road
        // Body points (sprung, they rattle) and unsprung points (wheels, blade); dx is measured forward.
        func p(_ dx: Float, _ dy: Float) -> (Float, Float) { (cx + dx * d, dy + shake) }
        func u(_ dx: Float, _ dy: Float) -> (Float, Float) { (cx + dx * d, dy) }
        /// Convex polygon with a vertical gradient between y0 (bottom colour) and y1 (top colour).
        func poly(_ pts: [(Float, Float)], _ bottom: RGBA, _ top: RGBA, y0: Float, y1: Float) {
            func col(_ y: Float) -> RGBA { Mesh.mix(bottom, top, max(0, min(1, (y - shake - y0) / (y1 - y0)))) }
            for k in 1..<(pts.count - 1) {
                Mesh.v(&out, pts[0].0, pts[0].1, col(pts[0].1))
                Mesh.v(&out, pts[k].0, pts[k].1, col(pts[k].1))
                Mesh.v(&out, pts[k + 1].0, pts[k + 1].1, col(pts[k + 1].1))
            }
        }
        func box(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ c: RGBA, _ c2: RGBA? = nil) {
            poly([p(x0, y0), p(x1, y0), p(x1, y1), p(x0, y1)], c, c2 ?? c, y0: y0, y1: y1)
        }

        let yellowTop: RGBA = (1, 0.8, 0.2, 1), yellowBot: RGBA = (0.94, 0.56, 0.08, 1)
        let trim: RGBA = (0.72, 0.4, 0.05, 1)
        let dark: RGBA = (0.16, 0.16, 0.19, 1)
        let snow: RGBA = (1, 1, 1, 0.97), snowRim: RGBA = (0.85, 0.9, 0.97, 0.97)

        // Exhaust puffs behind everything
        for f in puffs {
            let k = f.age / Self.puffLife
            let c: RGBA = (0.62, 0.63, 0.67, 0.42 * (1 - k))
            Mesh.circle(&out, cx: f.x, cy: f.y + shake, r: 2.5 + k * 7, center: c, rim: (c.0, c.1, c.2, 0), segments: 12)
        }
        // Exhaust pipe behind the cab
        Mesh.line(&out, p(-8, 26), p(-8, 47), width: 2.6, color: (0.5, 0.52, 0.56, 1))
        Mesh.line(&out, p(-8, 46), p(-8, 48), width: 3.4, color: (0.3, 0.3, 0.34, 1))

        // Chassis
        box(-44, 6, 40, 12, dark)
        // Dump body at the back, with ribs, a tail light and snow on top
        box(-46, 12, -6, 32, yellowBot, yellowTop)
        box(-47, 31, -5, 34, trim)
        for rx: Float in [-37, -27, -17] { Mesh.line(&out, p(rx, 14), p(rx, 30), width: 1.4, color: trim) }
        box(-47.5, 15, -45.5, 20, (0.9, 0.12, 0.1, 1))
        box(-46, 34, -6, 35.5, snow)
        for (k, sx) in [Float(-41), -33, -24, -15, -9].enumerated() {
            let c = p(sx, 35.5)
            Mesh.circle(&out, cx: c.0, cy: c.1, r: k % 2 == 0 ? 3.6 : 2.8, center: snow, rim: snowRim, segments: 12)
        }
        // Cab with a slanted windshield
        poly([p(-4, 12), p(22, 12), p(22, 30), p(16, 43), p(-4, 43)], yellowBot, yellowTop, y0: 12, y1: 43)
        box(-5, 42, 17, 44.5, trim)
        box(-5, 44.5, 3, 46, snow)
        Mesh.line(&out, p(-1, 14), p(-1, 27), width: 1, color: trim)                  // door seam
        box(11, 23.5, 16, 25, dark)                                                    // handle
        // Window with the driver in a red bobble hat
        poly([p(1.5, 28), p(19, 28), p(14.5, 40), p(1.5, 40)], (0.42, 0.62, 0.86, 1), (0.74, 0.89, 1, 1), y0: 28, y1: 40)
        let head = p(8.5, 32.6)
        Mesh.circle(&out, cx: head.0, cy: head.1, r: 3.5, center: (1, 0.86, 0.72, 1), rim: (0.93, 0.74, 0.6, 1), segments: 12)
        Mesh.tri(&out, p(5, 34), p(12, 34), p(8, 38.6), (0.86, 0.12, 0.14, 1))
        Mesh.disc(&out, cx: p(8, 38.8).0, cy: p(8, 38.8).1, r: 1.2, color: (1, 1, 1, 1))
        Mesh.line(&out, p(4.5, 29.5), p(8.5, 38.5), width: 1.6, color: (1, 1, 1, 0.35))   // glare
        // Hood, grille and headlight
        poly([p(22, 12), p(39, 12), p(39, 25), p(22, 29)], yellowBot, yellowTop, y0: 12, y1: 29)
        box(36.5, 13.5, 39.5, 22.5, dark)
        for gy: Float in [15.5, 18, 20.5] { Mesh.line(&out, p(36.5, gy), p(39.5, gy), width: 0.8, color: (0.4, 0.4, 0.45, 1)) }
        let lamp = p(38.6, 24.2)
        Mesh.circle(&out, cx: lamp.0, cy: lamp.1, r: 7, center: (1, 0.95, 0.7, 0.35), rim: (1, 0.95, 0.7, 0), segments: 12)
        Mesh.disc(&out, cx: lamp.0, cy: lamp.1, r: 1.9, color: (1, 0.97, 0.78, 1))

        // Wheels: dark wheel wells, black tyres, yellow rims with slots that turn
        for wx in Self.wheels {
            let c = u(wx, Self.wheelR)
            Mesh.disc(&out, cx: c.0, cy: c.1 + 0.5 + shake, r: Self.wheelR + 2.2, color: (0.12, 0.11, 0.12, 1))
            Mesh.circle(&out, cx: c.0, cy: c.1, r: Self.wheelR, center: (0.24, 0.24, 0.26, 1), rim: (0.05, 0.05, 0.06, 1), segments: 18)
            Mesh.circle(&out, cx: c.0, cy: c.1, r: 4.8, center: (1, 0.84, 0.3, 1), rim: (0.86, 0.6, 0.12, 1), segments: 14)
            for k in 0..<3 {
                let ang = -roll + Float(k) * 2 * .pi / 3
                Mesh.line(&out, (c.0 + cos(ang) * 1.6, c.1 + sin(ang) * 1.6), (c.0 + cos(ang) * 4.2, c.1 + sin(ang) * 4.2),
                          width: 1.5, color: (0.35, 0.22, 0.05, 1))
            }
            Mesh.disc(&out, cx: c.0, cy: c.1, r: 1.3, color: (0.3, 0.3, 0.32, 1))
        }

        // Plough: arms from the hood, a curved orange moldboard and a steel cutting edge
        Mesh.line(&out, p(38, 14), u(48, 9), width: 3, color: dark)
        Mesh.line(&out, p(38, 20), u(48.5, 16), width: 2.4, color: dark)
        let segs = 8
        func face(_ s: Float) -> Float { 52 + 4 * s - 8 * sin(.pi * s) }           // concave side faces forward
        for k in 0..<segs {
            let s0 = Float(k) / Float(segs), s1 = Float(k + 1) / Float(segs)
            let y0 = 0.5 + 24 * s0, y1 = 0.5 + 24 * s1
            let steel = k == 0
            let c0: RGBA = steel ? (0.62, 0.65, 0.7, 1) : Mesh.mix((0.82, 0.28, 0.05, 1), (1, 0.5, 0.12, 1), s0)
            let c1: RGBA = steel ? (0.75, 0.78, 0.82, 1) : Mesh.mix((0.82, 0.28, 0.05, 1), (1, 0.5, 0.12, 1), s1)
            let a = u(face(s0) - 4, y0), b = u(face(s0), y0), c = u(face(s1), y1), e = u(face(s1) - 4, y1)
            Mesh.v(&out, a.0, a.1, c0); Mesh.v(&out, b.0, b.1, c0); Mesh.v(&out, c.0, c.1, c1)
            Mesh.v(&out, a.0, a.1, c0); Mesh.v(&out, c.0, c.1, c1); Mesh.v(&out, e.0, e.1, c1)
        }
        // A few hazard stripes on the blade's back and a marker rod on top
        for sy: Float in [7, 13, 19] {
            let s = (sy - 0.5) / 24
            Mesh.line(&out, u(face(s) - 4, sy), u(face(s + 0.08) - 4, sy + 2.4), width: 1.3, color: (0.15, 0.12, 0.1, 0.8))
        }
        Mesh.line(&out, u(face(1) - 2, 24), u(53, 38), width: 1.1, color: (0.1, 0.1, 0.1, 1))
        Mesh.disc(&out, cx: u(53, 38.5).0, cy: 38.5, r: 1.7, color: (1, 0.42, 0.08, 1))

        // Flashing beacon on the roof
        let beacon = p(7, 48.5)
        box(4, 44.5, 10, 46.5, dark)
        let flash = pow(0.5 + 0.5 * sin(t * 9), 2)
        Mesh.circle(&out, cx: beacon.0, cy: beacon.1, r: 9 + 13 * flash, center: (1, 0.6, 0.1, 0.12 + 0.5 * flash),
                    rim: (1, 0.6, 0.1, 0), segments: 18)
        Mesh.circle(&out, cx: beacon.0, cy: beacon.1, r: 3.2,
                    center: (1, 0.75 + 0.2 * flash, 0.3 + 0.4 * flash, 1), rim: (0.95, 0.45, 0.05, 1), segments: 12)

        if alpha < 1 { for i in start..<out.count { out[i].a *= alpha } }
        if lift > 0 { for i in start..<out.count { out[i].y += lift } }   // driving on the Dock
    }
}
