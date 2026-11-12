import Foundation

// [1.3 tree] The Christmas tree's artwork: a layered fir with drooping branch tips, shaded in a few greens with
// needle strokes, snow resting on the branches, a bead garland spiralling around it, glossy baubles, a bevelled
// star with a pulsing glow and rays, Advent candles on the branch tips and wrapped presents.
// Positions are in tree units (multiplied by the tree size) relative to the foot of the trunk. `Christmas.tree`
// builds all of it once into a LightCache; only the bulbs, candle flames and the star's glow are re-lit per frame.
extension Christmas {
    /// One tier of branches. `outline` goes from the apex down the left side, along the bottom edge (branch tips
    /// and the notches between them) and back up the right side.
    struct TreeTier {
        enum Kind { case apex, side, tuft, tip, lobe, notch }
        var bottom, apex, half: Float
        var outline: [(x: Float, y: Float, kind: Kind)] = []
        var tips: [(Float, Float)] = []          // branch tips along the bottom edge, left to right

        /// Half width of the tier's body (without the tips) at height `y`.
        func body(at y: Float) -> Float { max(0, half * (apex - y) / (apex - bottom)) }
    }

    /// Small deterministic random numbers, so the tree looks the same every time it is rebuilt.
    struct TreeRandom {
        var state: UInt32
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
    }

    static let treeTiers: [TreeTier] = {
        // bottom of the body, apex, half width, number of branch tips along the bottom edge
        let spec: [(Float, Float, Float, Int)] = [(10, 46, 42, 8), (25, 60, 34, 7), (40, 72, 26, 5),
                                                   (54, 83, 18.5, 4), (67, 93, 11, 3)]
        return spec.enumerated().map { k, sp in
            var t = TreeTier(bottom: sp.0, apex: sp.1, half: sp.2)
            var rnd = TreeRandom(state: UInt32(17 + k * 131))
            let b = sp.0, a = sp.1, hw = sp.2, n = sp.3
            let tall = a - b
            // branch tips: the outer ones droop the most
            var tips: [(Float, Float)] = []
            for i in 0..<n {
                let u = Float(i) / Float(n - 1)
                var x = -hw + 2 * hw * u
                if i > 0 && i < n - 1 { x += rnd.range(-0.12, 0.12) * 2 * hw / Float(n - 1) }
                if i == 0 { x -= 1 } else if i == n - 1 { x += 1 }
                let droop = 1.2 + 2.2 * abs(x) / hw + rnd.range(0, 1.1)
                tips.append((x, b - droop))
            }
            t.tips = tips
            // a side: little tufts pointing down and out, larger towards the bottom
            func side(_ dir: Float, to tip: (Float, Float)) -> [(x: Float, y: Float, kind: TreeTier.Kind)] {
                var pts: [(x: Float, y: Float, kind: TreeTier.Kind)] = []
                let m = max(3, Int(tall / 6))
                for j in 1..<(2 * m) {
                    let u = Float(j) / Float(2 * m)
                    var x = tip.0 * pow(u, 0.92), y = a + (tip.1 + 1.5 - a) * u
                    if j % 2 == 1 {
                        x += dir * (0.6 + 1.6 * u + rnd.range(0, 0.6)); y -= 0.6 + 1.2 * u
                        pts.append((x, y, .tuft))
                    } else {
                        x -= dir * (0.3 + 0.5 * u)
                        pts.append((x, y, .side))
                    }
                }
                return pts
            }
            var o: [(x: Float, y: Float, kind: TreeTier.Kind)] = [(0, a, .apex)]
            o += side(-1, to: tips[0])
            for i in 0..<n {
                o.append((tips[i].0, tips[i].1, .tip))
                guard i < n - 1 else { break }
                let p = tips[i], q = tips[i + 1]
                let notch = ((p.0 + q.0) / 2 + rnd.range(-0.6, 0.6), b + 1.6 + rnd.range(0, 1.4))
                // each branch bulges a little below the straight line from the notch to its tip
                o.append((p.0 + (notch.0 - p.0) * 0.45, p.1 + (notch.1 - p.1) * 0.45 - 0.9, .lobe))
                o.append((notch.0, notch.1, .notch))
                o.append((q.0 + (notch.0 - q.0) * 0.45, q.1 + (notch.1 - q.1) * 0.45 - 0.9, .lobe))
            }
            o += side(1, to: tips[n - 1]).reversed()
            t.outline = o
            return t
        }
    }()

    /// Advent candles standing on the branch tips, in the order they are lit (one per December day).
    /// Not on a tip right behind a present, where the candle would be half hidden.
    static let candleSpots: [(Float, Float)] = {
        var spots: [(Float, Float)] = []
        for tier in treeTiers {
            for p in tier.tips {
                let c = (p.0 * 0.9, p.1 + 2.2)
                if treeGifts.contains(where: { abs(c.0 - $0.0) < $0.1 / 2 + 1.5 && c.1 - 0.6 < giftTop($0) - 2 }) { continue }
                spots.append(c)
            }
        }
        spots = Array(spots.prefix(24))
        // light them spread out over the tree rather than row by row
        let order = spots.indices.sorted { a, b in
            (Float(a) * 0.618).truncatingRemainder(dividingBy: 1) < (Float(b) * 0.618).truncatingRemainder(dividingBy: 1)
        }
        return order.map { spots[$0] }
    }()

    /// Where the tree's twinkling lights sit: along a spiral that winds around the tree, like a real string.
    static let treeLightSpots: [(Float, Float)] = {
        var spots: [(Float, Float)] = []
        var rnd = TreeRandom(state: 977)
        for (yc, n) in [(Float(17), 7), (33, 6), (49, 5), (64, 4), (77, 3)] {
            for i in 0..<n {
                let th = -1.2 + 2.4 * (Float(i) + 0.5) / Float(n) + rnd.range(-0.12, 0.12)
                let y = yc - 3 * th + rnd.range(-1.2, 1.2)
                spots.append((treeRadius(at: y) * 0.82 * sin(th), y))
            }
        }
        return spots
    }()

    /// Half width of the whole tree's body at height `y` (the widest tier there).
    static func treeRadius(at y: Float) -> Float {
        treeTiers.reduce(0) { max($0, y >= $1.bottom ? $1.body(at: y) : 0) }
    }

    /// Presents in front of the trunk: offset, width, height, paper, ribbon.
    /// Back to front, so the small ones overlap the bigger ones behind them.
    /// They leave room for the Advent candles on the lowest branch tips.
    static let treeGifts: [(Float, Float, Float, RGBA, RGBA)] = [
        (-26, 14, 12, (0.80, 0.10, 0.16, 1), (0.98, 0.82, 0.42, 1)),
        (20, 13, 10, (0.15, 0.36, 0.72, 1), (0.95, 0.95, 0.97, 1)),
        (-6, 10, 7, (0.96, 0.93, 0.86, 1), (0.80, 0.12, 0.18, 1)),
        (-14, 8, 5.5, (0.13, 0.46, 0.30, 1), (0.98, 0.82, 0.42, 1)),
        (29, 7, 5, (0.98, 0.76, 0.26, 1), (0.80, 0.12, 0.18, 1)),
    ]

    /// Top of present `g` with its bow, in tree units.
    static func giftTop(_ g: (Float, Float, Float, RGBA, RGBA)) -> Float { g.2 + 1.15 * max(2.2, 0.2 * g.1) }

    /// Does a bauble at (`x`, `y`) with radius `r` and its lowest point `bottom` clash with a present?
    private static func hitsGift(x: Float, r: Float, bottom: Float) -> Bool {
        treeGifts.contains { abs(x - $0.0) < $0.1 / 2 + r + 0.6 && bottom < giftTop($0) + 0.8 }
    }

    // MARK: Drawing

    @inline(__always)
    private static func ramp(_ l: Float) -> RGBA {
        // deep shade → body green → lit needles → frosty tips
        let stops: [RGBA] = [(0.015, 0.13, 0.09, 1), (0.05, 0.27, 0.17, 1), (0.13, 0.43, 0.25, 1),
                             (0.30, 0.60, 0.34, 1), (0.52, 0.74, 0.48, 1)]
        let f = max(0, min(0.999, l)) * Float(stops.count - 1)
        let i = Int(f)
        return Mesh.mix(stops[i], stops[i + 1], f - Float(i))
    }

    /// Trunk, snow mound, the tiers with their snow, the garland and the baubles (no lights, star or presents).
    /// `snow` 0…1: how much snow lies on the branches (a dusting … heavy), it follows the drift at the tree.
    static func treeBody(_ out: inout [Vertex], x cx: Float, baseY: Float, scale s: Float, style: LightStyle,
                         snow: Float = 0) {
        @inline(__always) func P(_ x: Float, _ y: Float) -> (Float, Float) { (cx + x * s, baseY + y * s) }
        // trunk, rounded by a darker right side
        let bark: RGBA = (0.36, 0.22, 0.12, 1), barkDark: RGBA = (0.2, 0.12, 0.06, 1)
        Mesh.rect(&out, x: cx - 4 * s, y: baseY - 1 * s, w: 8 * s, h: 13 * s, top: barkDark, bottom: bark)
        Mesh.rect(&out, x: cx + 1.2 * s, y: baseY - 1 * s, w: 2.8 * s, h: 13 * s, top: (0.12, 0.07, 0.04, 1), bottom: barkDark)
        // a mound of snow around the foot of the trunk
        snowBlob(&out, c: P(0, 0.6), rx: (24 + 5 * snow) * s, ry: (4.6 + 1.4 * snow) * s, angle: 0, segments: 14)

        let tiers = treeTiers
        for (k, tier) in tiers.enumerated() {
            if k > 0 { tierShadow(&out, tier, below: tiers[k - 1], P: P, s: s) }
            tierFill(&out, tier, k: k, P: P, s: s)
            tierSnow(&out, tier, k: k, snow: snow, P: P, s: s)
        }
        garland(&out, P: P, s: s)
        baubles(&out, P: P, s: s, style: style)
    }

    /// The soft shadow a tier casts on the one below it.
    private static func tierShadow(_ out: inout [Vertex], _ t: TreeTier, below: TreeTier,
                                   P: (Float, Float) -> (Float, Float), s: Float) {
        let edge = t.outline.filter { $0.kind == .tip || $0.kind == .lobe || $0.kind == .notch }
        func alpha(_ p: (x: Float, y: Float, kind: TreeTier.Kind)) -> Float {
            0.62 * max(0, min(1, (below.body(at: p.y) - abs(p.x) - 1) / 4))
        }
        for i in 0..<(edge.count - 1) {
            let p = edge[i], q = edge[i + 1]
            let ap = alpha(p), aq = alpha(q)
            if ap <= 0 && aq <= 0 { continue }
            let sh: RGBA = (0, 0.06, 0.03, 0)
            let p0 = P(p.x, p.y + 1), q0 = P(q.x, q.y + 1), p1 = P(p.x + 0.3 * p.x / t.half, p.y - 4.5)
            let q1 = P(q.x + 0.3 * q.x / t.half, q.y - 4.5)
            Mesh.v(&out, p0.0, p0.1, (sh.0, sh.1, sh.2, ap)); Mesh.v(&out, q0.0, q0.1, (sh.0, sh.1, sh.2, aq))
            Mesh.v(&out, q1.0, q1.1, sh)
            Mesh.v(&out, p0.0, p0.1, (sh.0, sh.1, sh.2, ap)); Mesh.v(&out, q1.0, q1.1, sh); Mesh.v(&out, p1.0, p1.1, sh)
        }
    }

    /// The tier's needles: a fan from a dark heart to lighter tips, branch streaks and needle strokes.
    private static func tierFill(_ out: inout [Vertex], _ t: TreeTier, k: Int,
                                 P: (Float, Float) -> (Float, Float), s: Float) {
        var rnd = TreeRandom(state: UInt32(4021 + k * 77))
        let tall = t.apex - t.bottom
        let heart = (Float(0), t.bottom + 0.36 * tall)
        let hc = P(heart.0, heart.1)
        let lit = { (x: Float) -> Float in -0.22 * x / t.half }          // light comes from the upper left
        var cols: [RGBA] = []
        for p in t.outline {
            var l: Float
            switch p.kind {
            case .apex: l = 0.3
            case .side: l = 0.38
            case .tuft: l = 0.62
            case .tip: l = 0.8
            case .lobe: l = 0.55
            case .notch: l = 0.2
            }
            cols.append(ramp(l + lit(p.x) + rnd.range(-0.07, 0.07)))
        }
        let heartCol = ramp(0.1)
        let n = t.outline.count
        for i in 0..<n {
            let j = (i + 1) % n
            let a = P(t.outline[i].x, t.outline[i].y), b = P(t.outline[j].x, t.outline[j].y)
            Mesh.v(&out, hc.0, hc.1, heartCol); Mesh.v(&out, a.0, a.1, cols[i]); Mesh.v(&out, b.0, b.1, cols[j])
        }
        // a lit branch running out to every tip along the bottom
        for tip in t.tips {
            let root = (tip.0 * 0.3, t.bottom + 0.42 * tall)
            let dx = tip.0 - root.0, dy = tip.1 - root.1
            let len = max(0.01, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len * 1.7, ny = dx / len * 1.7
            let c0 = ramp(0.5 + lit(tip.0)), c1 = ramp(0.92 + lit(tip.0))
            let r0 = P(root.0 + nx, root.1 + ny), r1 = P(root.0 - nx, root.1 - ny), e = P(tip.0, tip.1 + 0.4)
            Mesh.v(&out, r0.0, r0.1, (c0.0, c0.1, c0.2, 0)); Mesh.v(&out, r1.0, r1.1, (c0.0, c0.1, c0.2, 0))
            Mesh.v(&out, e.0, e.1, (c1.0, c1.1, c1.2, 0.9))
        }
        // needle strokes: short light and dark dashes hanging down and out from the heart of the tier
        let count = Int(t.half * 0.9)
        for _ in 0..<count {
            let u = pow(rnd.next(), 0.8)
            let y = t.bottom + 1.5 + (tall - 5) * (1 - u)
            let x = rnd.range(-0.9, 0.9) * t.body(at: y)
            let dx = x - 0, dy = y - (t.apex + tall * 0.4)
            let len = max(0.01, (dx * dx + dy * dy).squareRoot())
            let l = rnd.range(2.2, 4.4)
            let ex = x + dx / len * l, ey = y + dy / len * l
            let w: Float = 0.45
            let light = rnd.next() < 0.62
            let c: RGBA = light ? ramp(0.78 + lit(x)) : ramp(0.04)
            let a0 = P(x - dy / len * w, y + dx / len * w), a1 = P(x + dy / len * w, y - dx / len * w), e = P(ex, ey)
            let alpha: Float = light ? 0.7 : 0.35
            Mesh.v(&out, a0.0, a0.1, (c.0, c.1, c.2, alpha)); Mesh.v(&out, a1.0, a1.1, (c.0, c.1, c.2, alpha))
            Mesh.v(&out, e.0, e.1, (c.0, c.1, c.2, alpha * 0.3))
        }
    }

    /// Snow resting on the upper side of the branches (and a dusting on some of the side tufts). With more
    /// `snow` (0…1) the lumps grow, more branches carry one and they spread further in along the branch.
    /// Every random number is drawn whatever the amount, so the lumps stay put while they grow.
    private static func tierSnow(_ out: inout [Vertex], _ t: TreeTier, k: Int, snow: Float,
                                 P: (Float, Float) -> (Float, Float), s: Float) {
        var rnd = TreeRandom(state: UInt32(733 + k * 19))
        let tall = t.apex - t.bottom
        let grow = 0.85 + 0.5 * snow
        for (i, tip) in t.tips.enumerated() {
            let skip = rnd.next(), size = rnd.next(), second = rnd.next(), third = rnd.next()
            let inner = i > 0 && i < t.tips.count - 1
            if inner && skip < 0.24 * (1 - snow) { continue }
            // a lump lying on the branch just behind its tip, following the branch's slope
            let root = (tip.0 * 0.3, t.bottom + 0.42 * tall)
            var dx = tip.0 - root.0, dy = tip.1 - root.1
            let len = max(0.01, (dx * dx + dy * dy).squareRoot())
            dx /= len; dy /= len
            let ang = atan2(dy, dx)
            // snow settles nearly level: the lump only partly follows the branch's slope
            let flat = (abs(ang) > .pi / 2 ? ang - .pi * (ang > 0 ? 1 : -1) : ang) * 0.4
            let c = (tip.0 - dx * 2.5, tip.1 - dy * 2.5 + 1.15 + 0.25 * snow)
            snowBlob(&out, c: P(c.0, c.1), rx: (2.0 + 0.6 * size) * grow * s, ry: (1.15 + 0.3 * size) * grow * s,
                     angle: flat, segments: 10, belly: 0.5)
            if second < 0.35 + 0.55 * snow {
                let c2 = (tip.0 - dx * 6.4, tip.1 - dy * 6.4 + 1.5 + 0.3 * snow)
                snowBlob(&out, c: P(c2.0, c2.1), rx: 1.6 * grow * s, ry: 0.8 * grow * s, angle: flat, segments: 8,
                         belly: 0.5)
            }
            if third < snow - 0.3 {
                let c3 = (tip.0 - dx * 10, tip.1 - dy * 10 + 1.8)
                snowBlob(&out, c: P(c3.0, c3.1), rx: 1.3 * grow * s, ry: 0.65 * grow * s, angle: flat, segments: 7,
                         belly: 0.5)
            }
        }
        for p in t.outline where p.kind == .tuft && p.y < t.bottom + tall * 0.6 {
            guard rnd.next() < 0.35 + 0.45 * snow else { continue }
            let dir: Float = p.x < 0 ? 1 : -1
            snowBlob(&out, c: P(p.x + dir * 1.3, p.y + 0.9), rx: 1.5 * grow * s, ry: 0.65 * grow * s,
                     angle: dir * -0.35, segments: 7, belly: 0.55)
        }
    }

    /// A soft lump of snow: an ellipse, bright on top and cool underneath, with the snow grain and glints.
    /// `belly` < 1 flattens the underside, so it lies on a branch like a cap.
    static func snowBlob(_ out: inout [Vertex], c: (Float, Float), rx: Float, ry: Float, angle: Float, segments: Int,
                         belly: Float = 1) {
        let m = Mesh.snowMaterial(kind: 2, anchor: c)
        let ca = cos(angle), sa = sin(angle)
        @inline(__always) func col(_ up: Float) -> RGBA {
            // up: −1 underside … 1 top
            let t = max(0, min(1, 0.5 + 0.5 * up))
            let lo: RGBA = (0.74, 0.82, 0.93, 0.96), hi: RGBA = (1, 1, 1, 1)
            let k = Mesh.mix(lo, hi, t)
            return (k.0 + m.r, k.1 + m.g, k.2 + m.b, k.3)
        }
        var prev: (Float, Float, RGBA)?
        let center = col(0.7)
        for i in 0...segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            let lx = cos(a) * rx, ly = sin(a) * ry * (sin(a) < 0 ? belly : 1)
            let p = (c.0 + lx * ca - ly * sa, c.1 + lx * sa + ly * ca, col(sin(a)))
            if let q = prev {
                Mesh.v(&out, c.0, c.1 + ry * 0.2, center); Mesh.v(&out, q.0, q.1, q.2); Mesh.v(&out, p.0, p.1, p.2)
            }
            prev = p
        }
    }

    /// Champagne-gold beads spiralling around the tree.
    private static func garland(_ out: inout [Vertex], P: (Float, Float) -> (Float, Float), s: Float) {
        let bead: RGBA = (1, 0.96, 0.82, 1), beadRim: RGBA = (0.8, 0.64, 0.34, 1)
        for yc in [Float(26), 45, 63] {
            var th: Float = -1.3
            while th < 1.3 {
                let y = yc - 3.6 * th
                let r = treeRadius(at: y) * 0.9
                let p = P(r * sin(th), y + 1.2 * cos(th))
                Mesh.circle(&out, cx: p.0, cy: p.1, r: 0.68 * s, center: bead, rim: beadRim, segments: 5)
                th += 1.75 / max(4, r * abs(cos(th)) + 3.6)
            }
        }
    }

    /// Glossy baubles, most of them hanging from branch tips, a few drop-shaped.
    private static func baubles(_ out: inout [Vertex], P: (Float, Float) -> (Float, Float), s: Float,
                                style: LightStyle) {
        // the baubles match the lights: classic, warm gold, icy, or soft pastel
        let colors: [RGBA] = switch style {
        case .warmWhite: [(0.74, 0.08, 0.12, 1), (0.93, 0.70, 0.24, 1), (0.92, 0.84, 0.70, 1), (0.66, 0.30, 0.16, 1)]
        case .icicle: [(0.80, 0.85, 0.92, 1), (0.30, 0.56, 0.88, 1), (0.93, 0.95, 0.99, 1), (0.12, 0.24, 0.58, 1)]
        case .pastel: [(0.95, 0.58, 0.70, 1), (0.52, 0.82, 0.70, 1), (0.93, 0.80, 0.52, 1), (0.70, 0.60, 0.92, 1)]
        case .colorful, .chase: [(0.78, 0.06, 0.12, 1), (0.93, 0.70, 0.22, 1), (0.14, 0.33, 0.80, 1), (0.80, 0.83, 0.88, 1)]
        }
        var rnd = TreeRandom(state: 5309)
        var n = 0
        var placed: [(x: Float, y: Float, r: Float)] = []
        for (k, tier) in treeTiers.enumerated() where k >= 1 && k < 4 {
            for (i, tip) in tier.tips.enumerated() where (i + k) % 2 == 1 {
                let r: Float = k < 2 ? rnd.range(2.6, 3.0) : rnd.range(2.2, 2.6)
                let drop = n % 4 == 2
                let hang: Float = drop ? 2.2 : 1.4
                let x = tip.0 * 0.92, y = tip.1 - hang - r
                // none hanging into the presents under the tree
                if hitsGift(x: x, r: r, bottom: y - r * (drop ? 1.9 : 1)) { continue }
                bauble(&out, P: P, x: x, y: y, r: r, hook: (tip.0 * 0.92, tip.1 + 0.8), color: colors[n % colors.count],
                       drop: drop, s: s)
                placed.append((x, y - (drop ? r * 0.45 : 0), r * (drop ? 1.3 : 1)))
                n += 1
            }
        }
        // a few more nestled in the branches
        for p: (Float, Float) in [(-15, 31), (11, 37), (-5, 54), (-27, 20), (2, 19), (29, 19)] {
            let r = rnd.range(2.3, 2.8)
            if hitsGift(x: p.0, r: r, bottom: p.1 - r) { continue }
            // not on top of a hanging one
            if placed.contains(where: { q in
                let dx = q.x - p.0, dy = q.y - p.1, d = q.r + r + 1.2
                return dx * dx + dy * dy < d * d
            }) { continue }
            bauble(&out, P: P, x: p.0, y: p.1, r: r, hook: nil, color: colors[n % colors.count], drop: false, s: s)
            n += 1
        }
    }

    private static func bauble(_ out: inout [Vertex], P: (Float, Float) -> (Float, Float), x: Float, y: Float, r: Float,
                               hook: (Float, Float)?, color c: RGBA, drop: Bool, s: Float) {
        let gold: RGBA = (0.86, 0.68, 0.3, 1)
        // soft shadow on the needles behind it
        let sp = P(x + 0.7 * r, y - 0.8 * r)
        Mesh.circle(&out, cx: sp.0, cy: sp.1, r: r * 1.15 * s, center: (0, 0.04, 0.02, 0.4), rim: (0, 0.04, 0.02, 0),
                    segments: 8)
        if let h = hook {
            let a = P(h.0, h.1), b = P(x, y + r)
            Mesh.line(&out, a, b, width: 0.3 * s, color: (0.8, 0.7, 0.45, 0.8))
        }
        let light: RGBA = (min(1, c.0 * 1.15 + 0.3), min(1, c.1 * 1.15 + 0.3), min(1, c.2 * 1.15 + 0.3), 1)
        let dark: RGBA = (c.0 * 0.45, c.1 * 0.45, c.2 * 0.5, 1)
        let center = P(x - 0.3 * r, y + 0.3 * r)
        // body: a fan from a bright spot (upper left) to a dark rim; a drop is longer and pointed at the bottom
        let seg = 12
        var prev: (Float, Float)?
        for i in 0...seg {
            let a = Float(i) / Float(seg) * 2 * .pi + .pi / 2
            var px = cos(a) * r, py = sin(a) * r
            if drop && py < 0 {
                let f = -py / r
                py *= 1.9
                px *= 1 - 0.35 * f * f
            }
            let p = P(x + px, y + py)
            if let q = prev {
                Mesh.v(&out, center.0, center.1, Mesh.mix(c, light, 0.55))
                Mesh.v(&out, q.0, q.1, i == 1 ? dark : Mesh.mix(c, dark, 0.7))
                Mesh.v(&out, p.0, p.1, Mesh.mix(c, dark, 0.7))
            }
            prev = p
        }
        // bounce light along the lower right rim
        let bl = P(x + 0.45 * r, y - (drop ? 0.9 : 0.5) * r)
        Mesh.circle(&out, cx: bl.0, cy: bl.1, r: r * 0.45 * s, center: (light.0, light.1, light.2, 0.3),
                    rim: (light.0, light.1, light.2, 0), segments: 6)
        // cap
        let cap = P(x - 0.32 * r, y + r - 0.25)
        Mesh.rect(&out, x: cap.0, y: cap.1, w: 0.64 * r * s, h: 0.9 * s, top: (1, 0.9, 0.6, 1), bottom: gold)
        // specular highlight
        let hp = P(x - 0.38 * r, y + 0.42 * r)
        Mesh.circle(&out, cx: hp.0, cy: hp.1, r: max(0.6, r * 0.24 * s), center: (1, 1, 1, 0.95), rim: (1, 1, 1, 0.55),
                    segments: 6)
    }

    // MARK: Star

    /// The star's glow and rays: exactly `starGlowSegments` triangles, each starting with its centre vertex
    /// (that is what `LightCache.relight` re-paints to make it pulse).
    static func treeStarGlow(_ out: inout [Vertex], x: Float, y: Float, s: Float, t: Float) {
        let c = starGlow(t)
        let eve = starBoost > 1
        let gr = 15 * s * (eve ? 1.6 : 1)
        let rim: RGBA = (1, 0.88, 0.4, 0)
        let disc = starGlowSegments - 2 * starRays
        for k in 0..<disc {
            let a0 = Float(k) / Float(disc) * 2 * .pi, a1 = Float(k + 1) / Float(disc) * 2 * .pi
            Mesh.v(&out, x, y, c)
            Mesh.v(&out, x + cos(a0) * gr, y + sin(a0) * gr, rim)
            Mesh.v(&out, x + cos(a1) * gr, y + sin(a1) * gr, rim)
        }
        // rays: long ones out of the star's points, short ones between; each a tapering pair of triangles
        for k in 0..<starRays {
            let long = k % 2 == 0
            let ang = Float.pi / 2 + Float(k) * .pi / 5
            let len = (long ? 25 : 15) * s * (eve ? 1.5 : 1)
            let w = (long ? 1.5 : 1.0) * s * (eve ? 1.3 : 1)
            let tip = (x + cos(ang) * len, y + sin(ang) * len)
            let nx = -sin(ang) * w, ny = cos(ang) * w
            let side: RGBA = (1, 0.93, 0.65, eve ? 0.32 : 0.16)
            Mesh.v(&out, x, y, c); Mesh.v(&out, x + nx, y + ny, side); Mesh.v(&out, tip.0, tip.1, (1, 0.93, 0.65, 0))
            Mesh.v(&out, x, y, c); Mesh.v(&out, tip.0, tip.1, (1, 0.93, 0.65, 0)); Mesh.v(&out, x - nx, y - ny, side)
        }
    }

    static let starRays = 10

    /// A five-pointed star with bevelled (two-tone) arms and a darker gold rim.
    static func bevelStar(_ out: inout [Vertex], cx: Float, cy: Float, r: Float, s: Float) {
        let rimC: RGBA = (0.62, 0.38, 0.06, 1)
        let lightC: RGBA = (1, 0.97, 0.72, 1), midC: RGBA = (1, 0.82, 0.28, 1), darkC: RGBA = (0.86, 0.56, 0.1, 1)
        func points(_ r: Float) -> [(tip: (Float, Float), l: (Float, Float), rr: (Float, Float), a: Float)] {
            (0..<5).map { k in
                let a0 = Float.pi / 2 + Float(k) * 2 * .pi / 5
                let inner = r * 0.46
                return ((cx + cos(a0) * r, cy + sin(a0) * r),
                        (cx + cos(a0 - .pi / 5) * inner, cy + sin(a0 - .pi / 5) * inner),
                        (cx + cos(a0 + .pi / 5) * inner, cy + sin(a0 + .pi / 5) * inner), a0)
            }
        }
        for p in points(r + 1.1 * s) {
            Mesh.tri(&out, (cx, cy), p.l, p.tip, rimC)
            Mesh.tri(&out, (cx, cy), p.tip, p.rr, rimC)
        }
        let lx: Float = -0.55, ly: Float = 0.83                      // light from the upper left
        for p in points(r) {
            // each half of an arm faces the direction halfway between the arm and its inner corner
            for (half, corner) in [(-1 as Float, p.l), (1, p.rr)] {
                let fa = p.a + half * .pi / 10
                let d = cos(fa) * lx + sin(fa) * ly                 // −1 … 1
                let face = d >= 0 ? Mesh.mix(midC, lightC, d) : Mesh.mix(midC, darkC, -d)
                let apex = Mesh.mix(face, (1, 1, 0.9, 1), 0.35)
                if half < 0 {
                    Mesh.v(&out, cx, cy, apex); Mesh.v(&out, corner.0, corner.1, face); Mesh.v(&out, p.tip.0, p.tip.1, face)
                } else {
                    Mesh.v(&out, cx, cy, apex); Mesh.v(&out, p.tip.0, p.tip.1, face); Mesh.v(&out, corner.0, corner.1, face)
                }
            }
        }
    }

    // MARK: Candles and presents

    /// The wax of an Advent candle standing on a branch tip, in a little gold holder (the flame is a bulb).
    static func treeCandle(_ out: inout [Vertex], x: Float, y: Float, s: Float) {
        Mesh.rect(&out, x: x - 1.25 * s, y: y - 0.6 * s, w: 2.5 * s, h: 1.1 * s, top: (1, 0.86, 0.45, 1),
                  bottom: (0.72, 0.5, 0.16, 1))
        Mesh.rect(&out, x: x - 0.8 * s, y: y + 0.5 * s, w: 1.6 * s, h: 4 * s, top: (1, 0.98, 0.93, 1),
                  bottom: (0.9, 0.86, 0.78, 1))
        Mesh.rect(&out, x: x + 0.25 * s, y: y + 0.5 * s, w: 0.55 * s, h: 4 * s, top: (0.88, 0.84, 0.76, 1),
                  bottom: (0.76, 0.71, 0.63, 1))
        Mesh.line(&out, (x, y + 4.5 * s), (x, y + 5.2 * s), width: 0.35 * s, color: (0.2, 0.15, 0.1, 1))
    }

    /// A wrapped present standing on `y`: shaded box with a lid, ribbon both ways and a bow on top.
    static func giftBox(_ out: inout [Vertex], x: Float, y: Float, w: Float, h: Float, color c: RGBA, ribbon r: RGBA,
                        s: Float, shadow: Bool = true) {
        func shade(_ c: RGBA, _ k: Float) -> RGBA { (min(1, c.0 * k), min(1, c.1 * k), min(1, c.2 * k), c.3) }
        func lift(_ c: RGBA, _ k: Float) -> RGBA { (c.0 + (1 - c.0) * k, c.1 + (1 - c.1) * k, c.2 + (1 - c.2) * k, c.3) }
        // contact shadow in the snow
        if shadow { Mesh.circle(&out, cx: x + 0.6 * s, cy: y + 0.3 * s, r: w * 0.62, center: (0.1, 0.16, 0.3, 0.28),
                    rim: (0.1, 0.16, 0.3, 0), segments: 12) }
        let lidH = max(1.8 * s, h * 0.2)
        let body = h - lidH
        // box: lit on the left, darker on the right
        Mesh.quad(&out, x: x - w / 2, y: y, w: w, h: body, bl: shade(c, 0.72), br: shade(c, 0.55),
                  tr: shade(c, 0.7), tl: shade(c, 0.95))
        // lid, a touch wider, lighter on top
        Mesh.quad(&out, x: x - w / 2 - 0.6 * s, y: y + body, w: w + 1.2 * s, h: lidH, bl: shade(c, 0.85),
                  br: shade(c, 0.68), tr: shade(c, 0.95), tl: lift(c, 0.25))
        Mesh.rect(&out, x: x - w / 2 - 0.6 * s, y: y + body - 0.5 * s, w: w + 1.2 * s, h: 0.5 * s,
                  top: (0, 0, 0, 0.25), bottom: (0, 0, 0, 0))
        // ribbons with a sheen
        let rw = max(1.6 * s, w * 0.16)
        Mesh.quad(&out, x: x - rw / 2, y: y, w: rw, h: h, bl: shade(r, 0.78), br: shade(r, 0.66),
                  tr: shade(r, 0.9), tl: lift(r, 0.35))
        let hy = y + body * 0.48
        Mesh.quad(&out, x: x - w / 2, y: hy, w: w, h: rw * 0.85, bl: shade(r, 0.8), br: shade(r, 0.66),
                  tr: shade(r, 0.85), tl: lift(r, 0.3))
        // bow: two loops, a knot and two tails
        let top = y + h, lr = max(2.2 * s, w * 0.2)
        for d: Float in [-1, 1] {
            let lc = (x + d * lr * 0.95, top + lr * 0.55)
            var prev: (Float, Float)?
            let ang = d * 0.45
            for i in 0...10 {
                let a = Float(i) / 10 * 2 * .pi
                let px = cos(a) * lr, py = sin(a) * lr * 0.58
                let p = (lc.0 + px * cos(ang) - py * sin(ang), lc.1 + px * sin(ang) + py * cos(ang))
                if let q = prev {
                    Mesh.v(&out, lc.0 - d * lr * 0.2, lc.1 + lr * 0.12, lift(r, 0.3))
                    Mesh.v(&out, q.0, q.1, shade(r, 0.72)); Mesh.v(&out, p.0, p.1, shade(r, 0.72))
                }
                prev = p
            }
            // the loop's hollow
            Mesh.circle(&out, cx: lc.0 + d * lr * 0.12, cy: lc.1 - lr * 0.02, r: lr * 0.3, center: shade(r, 0.5),
                        rim: shade(r, 0.62), segments: 6)
            Mesh.tri(&out, (x, top + 0.2 * s), (x + d * lr * 0.9, top - lidH * 0.9), (x + d * lr * 0.45, top - lidH * 1.1),
                     shade(r, 0.75))
        }
        Mesh.circle(&out, cx: x, cy: top + lr * 0.4, r: lr * 0.38, center: lift(r, 0.35), rim: shade(r, 0.7), segments: 8)
    }
}
