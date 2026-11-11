import CoreGraphics
import Foundation

/// Christmas decorations: a decorated tree with presents, a garland of lights under the menu bar.
/// Everything is drawn as triangles; "glow" is a disc that fades to transparent.
enum Christmas {
    enum LightStyle: Int, CaseIterable, Identifiable, Sendable {
        case colorful, warmWhite, chase
        var id: Int { rawValue }
    }

    static let palette: [RGBA] = [(1, 0.18, 0.2, 1), (0.2, 0.85, 0.3, 1), (0.25, 0.55, 1, 1),
                                  (1, 0.8, 0.15, 1), (0.95, 0.35, 0.85, 1)]
    static let warm: RGBA = (1, 0.86, 0.55, 1)

    /// Brightness 0…1 of bulb `i` at time `t`.
    static func brightness(_ i: Int, _ t: Float, style: LightStyle) -> Float {
        switch style {
        case .chase:
            return (i + Int(t * 6)) % 4 == 0 ? 1 : 0.18
        case .colorful, .warmWhite:
            let ph = Float((i &* 2654435761) % 1000) / 1000 * 6.28
            let s = sin(t * (1.6 + Float(i % 5) * 0.35) + ph)
            return 0.35 + 0.65 * max(0, s)
        }
    }

    static func bulbColor(_ i: Int, style: LightStyle) -> RGBA {
        style == .warmWhite ? warm : palette[i % palette.count]
    }

    /// Light size and glow from the settings (set by the simulation before drawing).
    nonisolated(unsafe) static var bulbScale: Float = 1
    nonisolated(unsafe) static var glow: Float = 1

    static let glowSegments = 14, bulbSegments = 10

    /// Colours of a bulb at brightness `bIn`: the glow disc's centre, the bulb's centre and its rim.
    @inline(__always)
    static func bulbColors(_ c: RGBA, b bIn: Float, alpha: Float) -> (glow: RGBA, center: RGBA, rim: RGBA) {
        let b = bIn * min(1, 0.35 + 0.65 * glow)          // dimmer bulbs when the glow is turned down
        let lit: RGBA = (c.0 * (0.45 + 0.55 * b) + 0.25 * b, c.1 * (0.45 + 0.55 * b) + 0.25 * b,
                         c.2 * (0.45 + 0.55 * b) + 0.25 * b, alpha)
        return ((c.0, c.1, c.2, min(1, 0.45 * bIn * alpha * glow)),
                (min(1, lit.0 + 0.3 * b), min(1, lit.1 + 0.3 * b), min(1, lit.2 + 0.3 * b), alpha), lit)
    }

    static func bulb(_ out: inout [Vertex], x: Float, y: Float, r rIn: Float, color c: RGBA, b bIn: Float, alpha: Float) {
        var none: [LightCache.Slot]?
        bulb(&out, x: x, y: y, r: rIn, color: c, b: bIn, alpha: alpha, index: 0, slots: &none)
    }

    /// `slots` (when given) records where the bulb's vertices are, so a cached copy can be re-lit.
    private static func bulb(_ out: inout [Vertex], x: Float, y: Float, r rIn: Float, color c: RGBA, b bIn: Float,
                             alpha: Float, index: Int, slots: inout [LightCache.Slot]?) {
        let r = rIn * bulbScale
        let col = bulbColors(c, b: bIn, alpha: alpha)
        var glowStart = -1
        // glow
        if glow > 0.02 {
            glowStart = out.count
            Mesh.circle(&out, cx: x, cy: y, r: r * (2.2 + 1.1 * glow), center: col.glow,
                        rim: (c.0, c.1, c.2, 0), segments: glowSegments)
        }
        // bulb
        let bodyStart = out.count
        Mesh.circle(&out, cx: x, cy: y, r: r, center: col.center, rim: col.rim, segments: bulbSegments)
        slots?.append(LightCache.Slot(glow: Int32(glowStart), body: Int32(bodyStart), index: Int32(index), color: c, alpha: alpha))
    }

    /// Garland and tree geometry, built once: the shapes never change between frames, only the brightness
    /// of the bulbs (and the star's pulse), which `relight` writes into the copied vertices.
    struct LightCache {
        struct Slot { var glow, body, index: Int32; var color: RGBA; var alpha: Float }
        var key = SIMD8<Float>(repeating: .nan)   // what the geometry was built for (NaN: nothing yet)
        var occluders: [CGRect] = []
        var verts: [Vertex] = []
        var slots: [Slot] = []
        var pulse = -1                    // first vertex of the tree star's pulsing glow (-1 = none)

        /// Empties the cache for new geometry (keeping its storage); returns the slot list to fill.
        mutating func reset(key: SIMD8<Float>, occluders: [CGRect]) -> [Slot]? {
            self.key = key
            self.occluders = occluders
            verts.removeAll(keepingCapacity: true)
            pulse = -1
            var s = slots
            slots = []
            s.removeAll(keepingCapacity: true)
            return s
        }

        /// Brightness of each bulb at `t` written into `out[base...]` (a copy of `verts`); `fade` = tree ghost alpha.
        /// Relies on `Mesh.circle`'s layout: one triangle per segment, centre vertex first, then two rim
        /// vertices (and no snow material on these small, coloured discs).
        func relight(_ out: inout [Vertex], base: Int, t: Float, style: LightStyle, fade a: Float) {
            out.withUnsafeMutableBufferPointer { buf in
                @inline(__always) func paint(_ i: Int, _ c: RGBA) {
                    buf[i].r = c.0; buf[i].g = c.1; buf[i].b = c.2; buf[i].a = a < 1 ? c.3 * a : c.3
                }
                for s in slots {
                    let col = bulbColors(s.color, b: brightness(Int(s.index), t, style: style), alpha: s.alpha)
                    if s.glow >= 0 {
                        let g = base + Int(s.glow)
                        for k in 0..<glowSegments { paint(g + 3 * k, col.glow) }
                    }
                    let o = base + Int(s.body)
                    for k in 0..<bulbSegments {
                        paint(o + 3 * k, col.center); paint(o + 3 * k + 1, col.rim); paint(o + 3 * k + 2, col.rim)
                    }
                }
                if pulse >= 0 {
                    let c = starGlow(t)
                    for k in 0..<starGlowSegments { paint(base + pulse + 3 * k, c) }
                }
            }
        }
    }

    // MARK: Garland under the menu bar

    /// `skip(x)` hides the part of the garland behind an open menu.
    static func garland(_ out: inout [Vertex], width W: Float, y top: Float, t: Float, style: LightStyle,
                        skip: (Float) -> Bool = { _ in false }) {
        var none: [LightCache.Slot]?
        garland(&out, width: W, y: top, t: t, style: style, slots: &none, skip: skip)
    }

    /// Same picture as `garland`, from `cache`. `occluders` are what `skip` depends on (open menus).
    static func garland(_ out: inout [Vertex], cache: inout LightCache, width W: Float, y top: Float, t: Float,
                        style: LightStyle, occluders: [CGRect], skip: (Float) -> Bool) {
        let key = SIMD8<Float>(W, top, Float(style.rawValue), bulbScale, glow, 0, 0, 0)
        if cache.key != key || cache.occluders != occluders {
            var slots = cache.reset(key: key, occluders: occluders)
            garland(&cache.verts, width: W, y: top, t: t, style: style, slots: &slots, skip: skip)
            cache.slots = slots ?? []
        }
        let base = out.count
        out.append(contentsOf: cache.verts)
        cache.relight(&out, base: base, t: t, style: style, fade: 1)
    }

    private static func garland(_ out: inout [Vertex], width W: Float, y top: Float, t: Float, style: LightStyle,
                                slots: inout [LightCache.Slot]?, skip: (Float) -> Bool) {
        let k = bulbScale
        let span: Float = 150, sag: Float = 11 * (0.6 + 0.4 * k), spacing: Float = 19 * max(0.7, k)
        let wire: RGBA = (0.12, 0.2, 0.12, 0.9)
        var x0: Float = 0
        var bulbIndex = 0
        while x0 < W {
            let x1 = min(W, x0 + span)
            let len = x1 - x0
            func yAt(_ x: Float) -> Float {
                let u = (x - x0) / len
                return top - 2 - sag * 4 * u * (1 - u) * (len / span)
            }
            // wire
            let steps = 12
            for k in 0..<steps {
                let xa = x0 + len * Float(k) / Float(steps), xb = x0 + len * Float(k + 1) / Float(steps)
                if skip(xa) || skip(xb) { continue }
                Mesh.line(&out, (xa, yAt(xa)), (xb, yAt(xb)), width: 1.2, color: wire)
            }
            // bulbs hang slightly below the wire
            var x = x0 + spacing * 0.5
            while x < x1 - 4 {
                if skip(x) { bulbIndex += 1; x += spacing; continue }
                let y = yAt(x) - 3.5 * k
                let c = bulbColor(bulbIndex, style: style)
                Mesh.line(&out, (x, yAt(x)), (x, y + 2), width: 1, color: wire)
                bulb(&out, x: x, y: y, r: 2.6, color: c, b: brightness(bulbIndex, t, style: style), alpha: 1,
                     index: bulbIndex, slots: &slots)
                bulbIndex += 1
                x += spacing
            }
            x0 = x1
        }
    }

    // MARK: Santa's sleigh

    struct Sleigh {
        var x, y, dir, t: Float          // dir: +1 flies to the right, −1 to the left
    }

    /// Santa in his sleigh pulled by reindeer (Rudolph in front), drawn facing the flight direction.
    static func sleigh(_ out: inout [Vertex], _ sl: Sleigh, t: Float) {
        let d = sl.dir, x = sl.x, y = sl.y
        func p(_ dx: Float, _ dy: Float) -> (Float, Float) { (x + dx * d, y + dy) }
        let brown: RGBA = (0.45, 0.28, 0.15, 1), dark: RGBA = (0.3, 0.18, 0.1, 1)
        let red: RGBA = (0.82, 0.1, 0.12, 1), gold: RGBA = (0.98, 0.8, 0.25, 1)
        // Reins
        Mesh.line(&out, p(-8, 8), p(90, 10), width: 0.9, color: (0.35, 0.2, 0.1, 0.9))
        // Reindeer: three, the leader with a glowing red nose
        for k in 0..<3 {
            let rx = 34 + Float(k) * 28
            let bob = sin(t * 9 + Float(k)) * 2
            let legA = sin(t * 12 + Float(k) * 1.3) * 4
            Mesh.line(&out, p(rx - 6, 2 + bob), p(rx - 8 + legA, -8 + bob), width: 1.6, color: dark)
            Mesh.line(&out, p(rx + 6, 2 + bob), p(rx + 8 - legA, -8 + bob), width: 1.6, color: dark)
            Mesh.circle(&out, cx: p(rx, 5 + bob).0, cy: y + 5 + bob, r: 7, center: (0.55, 0.36, 0.2, 1), rim: brown, segments: 12)
            let head = p(rx + 10, 13 + bob)
            Mesh.line(&out, p(rx + 5, 7 + bob), head, width: 3, color: brown)
            Mesh.circle(&out, cx: head.0, cy: head.1, r: 3.4, center: (0.58, 0.38, 0.22, 1), rim: brown, segments: 10)
            Mesh.line(&out, (head.0, head.1 + 2), (head.0 - 2 * d, head.1 + 9), width: 1, color: dark)
            Mesh.line(&out, (head.0 - 1 * d, head.1 + 6), (head.0 - 5 * d, head.1 + 8), width: 0.9, color: dark)
            if k == 2 {
                let nose = (head.0 + 3.2 * d, head.1 - 0.5)
                Mesh.circle(&out, cx: nose.0, cy: nose.1, r: 6, center: (1, 0.2, 0.2, 0.45), rim: (1, 0.2, 0.2, 0), segments: 12)
                Mesh.disc(&out, cx: nose.0, cy: nose.1, r: 1.5, color: (1, 0.15, 0.15, 1))
            }
        }
        // Sleigh body with a golden runner
        Mesh.line(&out, p(-30, -10), p(4, -10), width: 1.6, color: gold)
        Mesh.line(&out, p(4, -10), p(9, -4), width: 1.6, color: gold)
        Mesh.tri(&out, p(-28, -7), p(2, -7), p(4, 8), red)
        Mesh.tri(&out, p(-28, -7), p(4, 8), p(-30, 10), red)
        Mesh.rect(&out, x: min(p(-30, 0).0, p(4, 0).0), y: y + 7, w: 34, h: 2.2, top: gold, bottom: gold)
        // Santa: red coat, white beard, hat with a bobble
        Mesh.circle(&out, cx: p(-14, 0).0, cy: y + 14, r: 7, center: (0.92, 0.15, 0.15, 1), rim: red, segments: 12)
        Mesh.circle(&out, cx: p(-12, 0).0, cy: y + 23, r: 4.2, center: (1, 0.86, 0.75, 1), rim: (0.95, 0.78, 0.66, 1), segments: 10)
        Mesh.circle(&out, cx: p(-11, 0).0, cy: y + 20, r: 3.6, center: (1, 1, 1, 1), rim: (0.9, 0.92, 0.96, 1), segments: 10)
        Mesh.tri(&out, p(-17, 25), p(-7, 25), p(-19, 33), red)
        Mesh.disc(&out, cx: p(-19, 0).0, cy: y + 33, r: 1.6, color: (1, 1, 1, 1))
        // A sack of presents
        Mesh.circle(&out, cx: p(-24, 0).0, cy: y + 12, r: 6, center: (0.75, 0.55, 0.3, 1), rim: (0.55, 0.38, 0.2, 1), segments: 10)
    }

    // MARK: Tree

    /// Bounding box of the tree standing at (x, baseY).
    static func treeRect(x: Float, baseY: Float, scale s: Float) -> CGRect {
        CGRect(x: CGFloat(x - 48 * s), y: CGFloat(baseY), width: CGFloat(96 * s), height: CGFloat(112 * s))
    }

    static func tree(_ out: inout [Vertex], x: Float, baseY: Float, scale s: Float, t: Float,
                     style: LightStyle, alpha a: Float) {
        var none: [LightCache.Slot]?
        var pulse = -1
        tree(&out, x: x, baseY: baseY, scale: s, t: t, style: style, alpha: a, slots: &none, pulse: &pulse)
    }

    /// Same picture as `tree`, from `cache` (rebuilt when the tree moves or the settings change).
    static func tree(_ out: inout [Vertex], cache: inout LightCache, x: Float, baseY: Float, scale s: Float, t: Float,
                     style: LightStyle, alpha a: Float) {
        let key = SIMD8<Float>(x, baseY, s, Float(style.rawValue), bulbScale, glow, a, 0)
        if cache.key != key {
            var slots = cache.reset(key: key, occluders: [])
            tree(&cache.verts, x: x, baseY: baseY, scale: s, t: t, style: style, alpha: a, slots: &slots, pulse: &cache.pulse)
            cache.slots = slots ?? []
        }
        let base = out.count
        out.append(contentsOf: cache.verts)
        cache.relight(&out, base: base, t: t, style: style, fade: a)
    }

    static let starGlowSegments = 18
    static func starGlow(_ t: Float) -> RGBA {
        let pulse = 0.75 + 0.25 * sin(t * 2.3)
        return (1, 0.88, 0.4, 0.45 * pulse)
    }

    private static func tree(_ out: inout [Vertex], x: Float, baseY: Float, scale s: Float, t: Float,
                             style: LightStyle, alpha a: Float, slots: inout [LightCache.Slot]?, pulse: inout Int) {
        let start = out.count
        // presents
        let gifts: [(Float, Float, Float, RGBA, RGBA)] = [(-30, 15, 12, (0.85, 0.15, 0.2, 1), (1, 0.85, 0.3, 1)),
                                                         (24, 13, 10, (0.2, 0.45, 0.9, 1), (1, 1, 1, 1)),
                                                         (-12, 11, 8, (0.95, 0.75, 0.2, 1), (0.85, 0.15, 0.2, 1))]
        // trunk
        Mesh.rect(&out, x: x - 5 * s, y: baseY, w: 10 * s, h: 14 * s, top: (0.42, 0.26, 0.13, 1), bottom: (0.3, 0.18, 0.09, 1))
        // three tiers, bottom first
        let tiers: [(w: Float, y: Float, h: Float)] = [(84, 10, 40), (64, 34, 36), (44, 58, 34)]
        for (k, tier) in tiers.enumerated() {
            let by = baseY + tier.y * s, hw = tier.w * s / 2, ty = by + tier.h * s
            let dark: RGBA = (0.05, 0.30 + Float(k) * 0.03, 0.14, 1)
            let light: RGBA = (0.16, 0.55, 0.24, 1)
            Mesh.v(&out, x - hw, by, dark); Mesh.v(&out, x + hw, by, dark); Mesh.v(&out, x, ty, light)
            // snow along the tier's lower edge (little scallops)
            let n = Int(tier.w / 8)
            for i in 0..<n {
                let xa = x - hw + Float(i) * (2 * hw / Float(n)), xb = xa + 2 * hw / Float(n)
                let snow: RGBA = (1, 1, 1, 0.95)
                Mesh.tri(&out, (xa, by - 0.5), (xb, by - 0.5), ((xa + xb) / 2, by + 3.2 * s), snow)
            }
        }
        // ornaments
        let balls: [(Float, Float)] = [(-22, 20), (14, 18), (30, 15), (-8, 30), (-18, 44), (16, 42), (0, 54), (-8, 68), (9, 66)]
        let ballColors: [RGBA] = [(0.9, 0.12, 0.18, 1), (0.98, 0.78, 0.2, 1), (0.25, 0.5, 0.95, 1)]
        for (i, p) in balls.enumerated() {
            let c = ballColors[i % ballColors.count]
            let cx = x + p.0 * s, cy = baseY + p.1 * s
            Mesh.circle(&out, cx: cx, cy: cy, r: 2.8 * s, center: (min(1, c.0 + 0.35), min(1, c.1 + 0.35), min(1, c.2 + 0.35), 1),
                        rim: (c.0 * 0.7, c.1 * 0.7, c.2 * 0.7, 1), segments: 12)
        }
        // twinkling lights
        let lights: [(Float, Float)] = [(-34, 13), (-10, 16), (6, 24), (26, 22), (-26, 33), (-2, 38), (22, 35),
                                        (-14, 52), (4, 48), (18, 54), (-4, 62), (12, 74), (-12, 76), (0, 84)]
        for (i, p) in lights.enumerated() {
            bulb(&out, x: x + p.0 * s, y: baseY + p.1 * s, r: 1.5 * s, color: bulbColor(i + 3, style: style),
                 b: brightness(i + 7, t, style: style), alpha: 1, index: i + 7, slots: &slots)
        }
        // star with a soft pulse
        let sy = baseY + 94 * s
        pulse = out.count - start
        Mesh.circle(&out, cx: x, cy: sy, r: 16 * s, center: starGlow(t), rim: (1, 0.88, 0.4, 0), segments: starGlowSegments)
        star(&out, cx: x, cy: sy, r: 7.5 * s, color: (1, 0.86, 0.2, 1))
        // presents in front of the trunk
        for g in gifts {
            let gx = x + g.0 * s, w = g.1 * s, h = g.2 * s
            Mesh.rect(&out, x: gx - w / 2, y: baseY, w: w, h: h, top: g.3, bottom: (g.3.0 * 0.75, g.3.1 * 0.75, g.3.2 * 0.75, 1))
            Mesh.rect(&out, x: gx - 1.2 * s, y: baseY, w: 2.4 * s, h: h, top: g.4, bottom: g.4)
            Mesh.rect(&out, x: gx - w / 2, y: baseY + h * 0.55, w: w, h: 2.2 * s, top: g.4, bottom: g.4)
            Mesh.circle(&out, cx: gx - 2 * s, cy: baseY + h + 1.5 * s, r: 2 * s, center: g.4, rim: g.4, segments: 8)
            Mesh.circle(&out, cx: gx + 2 * s, cy: baseY + h + 1.5 * s, r: 2 * s, center: g.4, rim: g.4, segments: 8)
        }
        if a < 1 { for i in start..<out.count { out[i].a *= a } }
    }

    static func star(_ out: inout [Vertex], cx: Float, cy: Float, r: Float, color: RGBA) {
        let inner = r * 0.45
        for k in 0..<5 {
            let a0 = Float.pi / 2 + Float(k) * 2 * .pi / 5
            let aL = a0 - .pi / 5, aR = a0 + .pi / 5
            let tip = (cx + cos(a0) * r, cy + sin(a0) * r)
            let l = (cx + cos(aL) * inner, cy + sin(aL) * inner)
            let rr = (cx + cos(aR) * inner, cy + sin(aR) * inner)
            Mesh.tri(&out, (cx, cy), l, tip, color)
            Mesh.tri(&out, (cx, cy), tip, rr, color)
        }
    }
}
