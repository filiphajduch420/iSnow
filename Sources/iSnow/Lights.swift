import CoreGraphics
import Foundation

/// Christmas lights: the bulbs, their twinkling, and the strings under the menu bar and along the front window.
/// Everything is drawn as triangles; "glow" is a few soft discs that fade to transparent.
extension Christmas {
    enum LightStyle: Int, CaseIterable, Identifiable, Sendable {
        case colorful, warmWhite, chase
        case icicle, pastel                 // [1.3 lights] stored values stay backward compatible
        var id: Int { rawValue }
    }

    /// How a bulb is drawn: a round fairy light (the default), a C9-style glass bulb hanging from its socket
    /// (`x`, `y` = the socket on the wire, `angle` tilts it, 0 = straight down), or a tiny LED.
    enum BulbShape: Sendable { case round, glass, led }

    static let palette: [RGBA] = [(1, 0.18, 0.2, 1), (0.2, 0.85, 0.3, 1), (0.25, 0.55, 1, 1),
                                  (1, 0.8, 0.15, 1), (0.95, 0.35, 0.85, 1)]
    static let pastels: [RGBA] = [(1, 0.62, 0.72, 1), (0.62, 0.86, 1, 1), (0.7, 0.96, 0.72, 1),
                                  (1, 0.9, 0.6, 1), (0.84, 0.72, 1, 1)]
    static let warm: RGBA = (1, 0.86, 0.55, 1)
    static let coolWhite: RGBA = (0.78, 0.89, 1, 1)

    /// Brightness 0…1 (a sparkle may briefly go above 1) of bulb `i` at time `t`.
    static func brightness(_ i: Int, _ t: Float, style: LightStyle) -> Float {
        let b = steadyBrightness(i, t, style: style)
        guard flash > 0 else { return b }
        // Midnight on New Year's Eve: every light flashes together.
        let on: Float = Int(t * 7) % 2 == 0 ? 1 : 0.08
        return b + (on - b) * min(1, flash)
    }

    /// Cheap deterministic noise 0…1 for bulb `i`.
    @inline(__always)
    static func hash01(_ i: Int, _ salt: UInt32) -> Float {
        var h = (UInt32(truncatingIfNeeded: i) &* 0x9E37_79B1) ^ (salt &* 0x85EB_CA77)
        h ^= h >> 16; h = h &* 0x7FEB_352D; h ^= h >> 15
        return Float(h & 0xFFFF) / 65535
    }

    /// Organic twinkle: every bulb breathes at its own pace and phase with a smooth ease (it lingers when
    /// fully lit and when dimmed), and now and then one sparkles – a quick bright flash.
    @inline(__always)
    private static func twinkle(_ i: Int, _ t: Float, speed: Float, depth: Float, sparkle: Float) -> Float {
        let u = 0.5 + 0.5 * sin(t * speed * (0.7 + 0.6 * hash01(i, 2)) + hash01(i, 1) * 6.283)
        var b = 1 - depth * (1 - u * u * (3 - 2 * u))
        let period: Float = 4.5
        let tt = t / period + hash01(i, 3)
        let cycle = tt.rounded(.down)
        if hash01(i &+ Int(cycle) &* 131, 4) < sparkle {
            let f = (tt - cycle) * period                 // seconds into this period
            if f < 0.45 { let s = sin(f * (Float.pi / 0.45)); b += 0.6 * s * s }
        }
        return b
    }

    private static func steadyBrightness(_ i: Int, _ t: Float, style: LightStyle) -> Float {
        if i >= candleIndex {                            // Advent candles flicker softly whatever the style
            let ph = Float(i % 97) * 0.7
            return 0.8 + 0.2 * sin(t * 9.3 + ph) * sin(t * 5.1 + ph * 1.7)
        }
        switch style {
        case .chase:
            // One bulb in four lit, the pattern stepping along with a quick, soft cross-fade.
            let pos = t * 5, step = Int(pos.rounded(.down)), f = pos - Float(step)
            let cur: Float = (i + step) % 4 == 0 ? 1 : 0, prev: Float = (i + step + 3) % 4 == 0 ? 1 : 0
            let e = min(1, f / 0.35)
            return 0.16 + 0.84 * (prev + (cur - prev) * e * e * (3 - 2 * e))
        case .colorful:
            return twinkle(i, t, speed: 1.3, depth: 0.6, sparkle: 0.12)
        case .pastel:
            return twinkle(i, t, speed: 0.9, depth: 0.35, sparkle: 0.1)
        case .warmWhite:
            return twinkle(i, t, speed: 0.7, depth: 0.22, sparkle: 0.06)
        case .icicle:
            // `i` = strand · 8 + LED number from the top: a drop of light now and then runs down a strand.
            var b = twinkle(i, t, speed: 1.1, depth: 0.22, sparkle: 0.04)
            let strand = i >> 3, k = Float(i & 7)
            let tt = t / 3.4 + hash01(strand, 5)
            let cycle = tt.rounded(.down)
            if hash01(strand &+ Int(cycle) &* 977, 6) < 0.3 {
                let pos = (tt - cycle) * 3.4 / 1.3 * 6 - 0.8      // LEDs travelled (over about 1.3 s)
                b = b * 0.8 + 0.9 * max(0, 1 - abs(k - pos) * 0.9)
            }
            return b
        }
    }

    static func bulbColor(_ i: Int, style: LightStyle) -> RGBA {
        switch style {
        case .warmWhite: return warm
        case .icicle: return coolWhite
        case .pastel: return pastels[i % pastels.count]
        case .colorful, .chase: return palette[i % palette.count]
        }
    }

    /// Light size and glow from the settings (set by the simulation before drawing).
    nonisolated(unsafe) static var bulbScale: Float = 1
    nonisolated(unsafe) static var glow: Float = 1

    static let glowSegments = 12, bulbSegments = 10

    /// Every colour a lit bulb is painted with, by role (see `role…` below).
    struct LightPaint {
        var hot, body, rim, halo1, halo2, halo3: RGBA
        @inline(__always) subscript(role: UInt8) -> RGBA {
            switch role {
            case 0: return hot
            case 1: return body
            case 2: return rim
            case 3: return halo1
            case 4: return halo2
            default: return halo3
            }
        }
    }
    // Vertex roles: what a vertex is painted with when the bulb is relit (`fixed` = never changes).
    static let roleHot: UInt8 = 0, roleBody: UInt8 = 1, roleRim: UInt8 = 2
    static let roleHalo1: UInt8 = 3, roleHalo2: UInt8 = 4, roleHalo3: UInt8 = 5, roleFixed: UInt8 = 255

    @inline(__always)
    static func lightPaint(_ c: RGBA, b bIn: Float, alpha: Float) -> LightPaint {
        let b = bIn * min(1, 0.72 + 0.28 * glow)          // a little calmer bulbs when the glow is turned down
        let on = min(1, b), over = max(0, b - 1)
        @inline(__always) func shade(_ k: Float, _ add: Float) -> RGBA {
            (min(1, c.0 * k + add), min(1, c.1 * k + add), min(1, c.2 * k + add), alpha)
        }
        let body = shade(0.36 + 0.64 * on, 0.08 * on)
        let rim = shade(0.2 + 0.5 * on, 0)
        let w = min(1, 0.55 * on * on + 0.6 * over)       // how white-hot the filament spot is
        let hot: RGBA = (body.0 + (1 - body.0) * w, body.1 + (1 - body.1) * w * 0.95,
                         body.2 + (1 - body.2) * w * 0.85, alpha)
        let hc: RGBA = (min(1, c.0 * 0.85 + 0.2), min(1, c.1 * 0.85 + 0.2), min(1, c.2 * 0.85 + 0.2), 0)
        let h = b * alpha * glow
        return LightPaint(hot: hot, body: body, rim: rim,
                          halo1: (hc.0, hc.1, hc.2, min(1, 0.62 * h)),
                          halo2: (hc.0, hc.1, hc.2, min(1, 0.3 * h)),
                          halo3: (c.0, c.1, c.2, min(0.6, 0.13 * h)))
    }

    /// Which parts of a bulb to draw: strings draw all glows first, then the wire, then the bulbs on top.
    enum BulbParts: Sendable { case all, glow, body }

    static func bulb(_ out: inout [Vertex], x: Float, y: Float, r rIn: Float, color c: RGBA, b bIn: Float, alpha: Float,
                     shape: BulbShape = .round, angle: Float = 0) {
        var none: [LightCache.Slot]?
        bulb(&out, x: x, y: y, r: rIn, color: c, b: bIn, alpha: alpha, index: 0, slots: &none, shape: shape, angle: angle)
    }

    /// `slots` (when given) records where the bulb's vertices are and how each is painted, so a cached copy can
    /// be re-lit. For `.glass`, (`x`, `y`) is the socket on the wire; otherwise the bulb's centre.
    static func bulb(_ out: inout [Vertex], x: Float, y: Float, r rIn: Float, color c: RGBA, b bIn: Float,
                     alpha: Float, index: Int, slots: inout [LightCache.Slot]?, shape: BulbShape = .round,
                     angle: Float = 0, parts: BulbParts = .all, whiteSocket: Bool = false) {
        let r = rIn * bulbScale
        let p = lightPaint(c, b: bIn, alpha: alpha)
        // Axis pointing from the socket to the tip, and across.
        let dx = sin(angle), dy = -cos(angle), nx = -dy, ny = dx
        let glassLen = 2.5 * r, cap = 0.95 * r
        // centre of the light: the glass's widest part for a hanging bulb
        let (cx, cy) = shape == .glass ? (x + dx * (cap + glassLen * 0.36), y + dy * (cap + glassLen * 0.36)) : (x, y)
        var roles: [UInt8]? = slots == nil ? nil : []
        var start = out.count
        if parts != .body && glow > 0.02 {
            let g = glow, clear: RGBA = (p.halo1.0, p.halo1.1, p.halo1.2, 0)
            switch shape {
            case .glass:
                // light cast on the wall below the bulb, then a soft halo and a brighter one close around the glass
                let rx = r * (3.4 + 1.5 * g), ry = rx * 0.78
                fan(&out, &roles, cx: cx, cy: cy - ry * 0.35, rx: rx, ry: ry, segments: glowSegments,
                    center: p.halo3, roleHalo3, rim: (c.0, c.1, c.2, 0), roleFixed)
                fan(&out, &roles, cx: cx, cy: cy, rx: r * (2.5 + g), ry: r * (2.5 + g), segments: glowSegments,
                    center: p.halo2, roleHalo2, rim: clear, roleFixed)
                fan(&out, &roles, cx: cx, cy: cy, rx: r * (1.9 + 0.5 * g), ry: r * (1.9 + 0.5 * g), segments: glowSegments,
                    center: p.halo1, roleHalo1, rim: clear, roleFixed)
            case .round:
                fan(&out, &roles, cx: cx, cy: cy, rx: r * (2.4 + 1.1 * g), ry: r * (2.4 + 1.1 * g), segments: glowSegments,
                    center: p.halo2, roleHalo2, rim: clear, roleFixed)
                fan(&out, &roles, cx: cx, cy: cy, rx: r * (1.5 + 0.45 * g), ry: r * (1.5 + 0.45 * g), segments: glowSegments,
                    center: p.halo1, roleHalo1, rim: clear, roleFixed)
            case .led:
                fan(&out, &roles, cx: cx, cy: cy, rx: r * (3 + 1.4 * g), ry: r * (3 + 1.4 * g), segments: 10,
                    center: p.halo2, roleHalo2, rim: clear, roleFixed)
                fan(&out, &roles, cx: cx, cy: cy, rx: r * (1.6 + 0.4 * g), ry: r * (1.6 + 0.4 * g), segments: 8,
                    center: p.halo1, roleHalo1, rim: clear, roleFixed)
            }
        }
        if parts == .glow {
            record(&slots, start: start, roles: roles, index: index, color: c, alpha: alpha)
            return
        }
        if parts == .body { start = out.count }
        switch shape {
        case .round:
            ring(&out, &roles, cx: cx, cy: cy, r: r, segments: bulbSegments, p: p, hotAt: (cx - r * 0.12, cy + r * 0.12))
            fan(&out, &roles, cx: cx - r * 0.38, cy: cy + r * 0.38, rx: r * 0.26, ry: r * 0.26, segments: 6,
                center: (1, 1, 1, 0.8 * alpha), roleFixed, rim: (1, 1, 1, 0.25 * alpha), roleFixed)
        case .led:
            // a tiny clear drop: a white-hot core in a tinted bead whose edge melts into its own glow
            fan(&out, &roles, cx: cx, cy: cy + 0.12 * r, rx: 0.86 * r, ry: 1.28 * r, segments: 12, center: p.body, roleBody,
                rim: p.halo1, roleHalo1)
            fan(&out, &roles, cx: cx, cy: cy + 0.1 * r, rx: 0.6 * r, ry: 0.95 * r, segments: 10, center: p.hot, roleHot,
                rim: p.body, roleBody)
        case .glass:
            // socket: a plastic cap (dark green, or white on a white wire), lit from the left, with two rings
            let sock: RGBA, shine: RGBA, ridge: RGBA
            if whiteSocket {
                sock = (0.8, 0.81, 0.79, alpha); shine = (0.98, 0.98, 0.97, alpha); ridge = (0.66, 0.67, 0.65, alpha)
            } else {
                sock = (0.06, 0.16, 0.08, alpha); shine = (0.2, 0.36, 0.21, alpha); ridge = (0.02, 0.08, 0.03, alpha)
            }
            let hw = 0.56 * r
            func pt(_ along: Float, _ across: Float) -> (Float, Float) { (x + dx * along + nx * across, y + dy * along + ny * across) }
            quad(&out, &roles, pt(-0.3 * r, -hw * 0.8), pt(-0.3 * r, hw * 0.8), pt(cap, hw), pt(cap, -hw), sock)
            let lit: Float = nx > 0 ? -1 : 1                    // the side facing the light (screen left)
            quad(&out, &roles, pt(-0.2 * r, lit * hw * 0.62), pt(-0.2 * r, lit * hw * 0.22), pt(cap, lit * hw * 0.3),
                 pt(cap, lit * hw * 0.74), shine)
            quad(&out, &roles, pt(cap * 0.5, -hw * 0.93), pt(cap * 0.5, hw * 0.93), pt(cap * 0.6, hw * 0.94),
                 pt(cap * 0.6, -hw * 0.94), ridge)
            quad(&out, &roles, pt(cap * 0.84, -hw), pt(cap * 0.84, hw), pt(cap * 0.94, hw), pt(cap * 0.94, -hw), ridge)
            // glass: a rounded cone, white-hot near the filament, darker towards the rim
            glass(&out, &roles, at: pt, from: cap, length: glassLen, r: r, p: p)
            // specular streak on the side facing the light (screen left/top)
            let side = lit
            let a0 = pt(cap + glassLen * 0.14, side * r * 0.62), a1 = pt(cap + glassLen * 0.14, side * r * 0.36)
            let b0 = pt(cap + glassLen * 0.55, side * r * 0.5), b1 = pt(cap + glassLen * 0.55, side * r * 0.34)
            let hi: RGBA = (1, 1, 1, 0.75 * alpha), fade: RGBA = (1, 1, 1, 0)
            put(&out, &roles, a0.0, a0.1, hi, roleFixed); put(&out, &roles, a1.0, a1.1, hi, roleFixed)
            put(&out, &roles, b1.0, b1.1, fade, roleFixed)
            put(&out, &roles, a0.0, a0.1, hi, roleFixed); put(&out, &roles, b1.0, b1.1, fade, roleFixed)
            put(&out, &roles, b0.0, b0.1, fade, roleFixed)
        }
        record(&slots, start: start, roles: roles, index: index, color: c, alpha: alpha)
    }

    // MARK: Bulb pieces

    @inline(__always)
    private static func put(_ out: inout [Vertex], _ roles: inout [UInt8]?, _ x: Float, _ y: Float, _ c: RGBA, _ role: UInt8) {
        out.append(Vertex(x: x, y: y, r: c.0, g: c.1, b: c.2, a: c.3))
        roles?.append(role)
    }

    private static func record(_ slots: inout [LightCache.Slot]?, start: Int, roles: [UInt8]?, index: Int, color: RGBA, alpha: Float) {
        guard let roles, roles.contains(where: { $0 != roleFixed }) else { return }
        slots?.append(LightCache.Slot(start: Int32(start), index: Int32(index), color: color, alpha: alpha, roles: roles))
    }

    /// Ellipse fan from its centre.
    private static func fan(_ out: inout [Vertex], _ roles: inout [UInt8]?, cx: Float, cy: Float, rx: Float, ry: Float,
                            segments n: Int, center c: RGBA, _ cr: UInt8, rim e: RGBA, _ er: UInt8) {
        var prev = (cx + rx, cy)
        for s in 1...n {
            let a = Float(s) / Float(n) * 2 * .pi
            let q = (cx + cos(a) * rx, cy + sin(a) * ry)
            put(&out, &roles, cx, cy, c, cr); put(&out, &roles, prev.0, prev.1, e, er); put(&out, &roles, q.0, q.1, e, er)
            prev = q
        }
    }

    private static func quad(_ out: inout [Vertex], _ roles: inout [UInt8]?, _ a: (Float, Float), _ b: (Float, Float),
                             _ c: (Float, Float), _ d: (Float, Float), _ col: RGBA) {
        put(&out, &roles, a.0, a.1, col, roleFixed); put(&out, &roles, b.0, b.1, col, roleFixed)
        put(&out, &roles, c.0, c.1, col, roleFixed)
        put(&out, &roles, a.0, a.1, col, roleFixed); put(&out, &roles, c.0, c.1, col, roleFixed)
        put(&out, &roles, d.0, d.1, col, roleFixed)
    }

    /// Round bulb: a hot spot fading into the coloured body, then a darker rim.
    private static func ring(_ out: inout [Vertex], _ roles: inout [UInt8]?, cx: Float, cy: Float, r: Float, segments n: Int,
                             p: LightPaint, hotAt h: (Float, Float)) {
        var outline: [(Float, Float)] = []
        outline.reserveCapacity(n)
        for s in 0..<n {
            let a = Float(s) / Float(n) * 2 * .pi
            outline.append((cx + cos(a) * r, cy + sin(a) * r))
        }
        shade(&out, &roles, outline: outline, hot: h, p: p)
    }

    /// Glass of a hanging bulb: a rounded cone, widest near the socket, tapering to a soft point.
    private static let glassProfile: [(Float, Float)] = [(0, 0.5), (0.08, 0.77), (0.18, 0.94), (0.3, 1.0),
                                                          (0.42, 0.97), (0.55, 0.86), (0.68, 0.68), (0.8, 0.47),
                                                          (0.9, 0.27), (0.97, 0.1), (1, 0)]

    private static func glass(_ out: inout [Vertex], _ roles: inout [UInt8]?, at pt: (Float, Float) -> (Float, Float),
                              from cap: Float, length L: Float, r: Float, p: LightPaint) {
        var outline: [(Float, Float)] = []
        outline.reserveCapacity(2 * glassProfile.count)
        for q in glassProfile { outline.append(pt(cap + q.0 * L, -q.1 * r)) }
        for q in glassProfile.dropLast().reversed() { outline.append(pt(cap + q.0 * L, q.1 * r)) }
        shade(&out, &roles, outline: outline, hot: pt(cap + 0.34 * L, -0.12 * r), p: p)
    }

    /// Two rings: a hot centre → the body colour half way → the rim colour at the outline.
    private static func shade(_ out: inout [Vertex], _ roles: inout [UInt8]?, outline: [(Float, Float)],
                              hot h: (Float, Float), p: LightPaint) {
        let n = outline.count
        @inline(__always) func mid(_ q: (Float, Float)) -> (Float, Float) { (h.0 + (q.0 - h.0) * 0.55, h.1 + (q.1 - h.1) * 0.55) }
        for s in 0..<n {
            let a = outline[s], b = outline[(s + 1) % n], ma = mid(a), mb = mid(b)
            put(&out, &roles, h.0, h.1, p.hot, roleHot)
            put(&out, &roles, ma.0, ma.1, p.body, roleBody); put(&out, &roles, mb.0, mb.1, p.body, roleBody)
            put(&out, &roles, ma.0, ma.1, p.body, roleBody); put(&out, &roles, a.0, a.1, p.rim, roleRim)
            put(&out, &roles, b.0, b.1, p.rim, roleRim)
            put(&out, &roles, ma.0, ma.1, p.body, roleBody); put(&out, &roles, b.0, b.1, p.rim, roleRim)
            put(&out, &roles, mb.0, mb.1, p.body, roleBody)
        }
    }

    /// Garland and tree geometry, built once: the shapes never change between frames, only the brightness
    /// of the bulbs (and the star's pulse), which `relight` writes into the copied vertices.
    struct LightCache {
        /// A run of bulb vertices starting at `start`; `roles[k]` says how vertex `start + k` is painted.
        struct Slot { var start, index: Int32; var color: RGBA; var alpha: Float; var roles: [UInt8] }
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
        func relight(_ out: inout [Vertex], base: Int, t: Float, style: LightStyle, fade a: Float) {
            out.withUnsafeMutableBufferPointer { buf in
                @inline(__always) func paint(_ i: Int, _ c: RGBA) {
                    buf[i].r = c.0; buf[i].g = c.1; buf[i].b = c.2; buf[i].a = a < 1 ? c.3 * a : c.3
                }
                for s in slots {
                    let p = lightPaint(s.color, b: brightness(Int(s.index), t, style: style), alpha: s.alpha)
                    let o = base + Int(s.start)
                    s.roles.withUnsafeBufferPointer { roles in
                        for k in 0..<roles.count where roles[k] != roleFixed { paint(o + k, p[roles[k]]) }
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
    /// `left`…`width`: the span from left to right edge; `sag` scales how low the wire hangs;
    /// `gap`: no bulbs around this x (something else hangs there, e.g. a wreath).
    static func garland(_ out: inout [Vertex], width W: Float, y top: Float, t: Float, style: LightStyle,
                        left: Float = 0, sag: Float = 1, gap: Float? = nil, skip: (Float) -> Bool = { _ in false }) {
        var none: [LightCache.Slot]?
        garland(&out, width: W, y: top, t: t, style: style, left: left, sagScale: sag, gap: gap, slots: &none, skip: skip)
    }

    /// Same picture as `garland`, from `cache`. `occluders` are what `skip` depends on (open menus).
    static func garland(_ out: inout [Vertex], cache: inout LightCache, width W: Float, y top: Float, t: Float,
                        style: LightStyle, left: Float = 0, sag: Float = 1, gap: Float? = nil, occluders: [CGRect],
                        skip: (Float) -> Bool) {
        let key = SIMD8<Float>(W, top, Float(style.rawValue), bulbScale, glow, left, sag, gap ?? -1e9)
        if cache.key != key || cache.occluders != occluders {
            var slots = cache.reset(key: key, occluders: occluders)
            garland(&cache.verts, width: W, y: top, t: t, style: style, left: left, sagScale: sag, gap: gap,
                    slots: &slots, skip: skip)
            cache.slots = slots ?? []
        }
        let base = out.count
        out.append(contentsOf: cache.verts)
        cache.relight(&out, base: base, t: t, style: style, fade: 1)
    }

    private struct Hung { var x, y, angle: Float; var index: Int; var color: RGBA }

    /// One span of wire between two hooks: a catenary `sag` below the hooks in the middle.
    private struct Span {
        var x0, len, sag, top: Float
        static let c: Float = 2.2
        static let ch = cosh(c / 2) - 1
        func y(_ x: Float) -> Float {
            let u = min(1, max(0, (x - x0) / len))
            return top - 2 - sag * (1 - (cosh(Span.c * (u - 0.5)) - 1) / Span.ch)
        }
    }

    private static func garland(_ out: inout [Vertex], width W: Float, y top: Float, t: Float, style: LightStyle,
                                left: Float, sagScale: Float, gap: Float?, slots: inout [LightCache.Slot]?,
                                skip: (Float) -> Bool) {
        if style == .icicle {
            icicles(&out, width: W, y: top, t: t, left: left, sagScale: sagScale, gap: gap, slots: &slots, skip: skip)
            return
        }
        let k = bulbScale
        let spacing: Float = 19 * max(0.7, k)
        let gapHalf: Float = 11 + 3 * k
        var bulbs: [Hung] = []
        var spans: [Span] = []
        var x0: Float = left, span = 0, bulbIndex = 0
        while x0 < W - 1 {                                  // every span is at least 132 pt long
            // spans of slightly different lengths and sags, so the string hangs naturally
            let full: Float = 150 * (0.88 + 0.24 * hash01(span, 7))
            let x1 = min(W, x0 + full), len = x1 - x0
            let sp = Span(x0: x0, len: len, sag: 11 * (0.6 + 0.4 * k) * sagScale * (0.85 + 0.3 * hash01(span, 11)) * (len / full),
                          top: top)
            spans.append(sp)
            let n = max(1, Int((len / spacing).rounded()))
            for m in 0..<n {
                let x = x0 + len * (Float(m) + 0.5) / Float(n)
                defer { bulbIndex += 1 }
                if skip(x) { continue }
                if let g = gap, abs(x - g) < gapHalf { continue }
                let slope = sp.y(x + 0.5) - sp.y(x - 0.5)
                let tilt = ((m + span) % 2 == 0 ? 0.2 : -0.2) + (hash01(bulbIndex, 9) - 0.5) * 0.2
                bulbs.append(Hung(x: x, y: sp.y(x), angle: 0.7 * atan(slope) + tilt, index: bulbIndex,
                                  color: bulbColor(bulbIndex, style: style)))
            }
            x0 = x1
            span += 1
        }
        let r: Float = 2.6
        let white = style == .pastel                       // pastel bulbs hang on a white wire
        // 1. glows on the wall behind everything
        for h in bulbs {
            bulb(&out, x: h.x, y: h.y, r: r, color: h.color, b: brightness(h.index, t, style: style), alpha: 1,
                 index: h.index, slots: &slots, shape: .glass, angle: h.angle, parts: .glow)
        }
        // 2. the wire: two strands twisted round each other, hooked up under the edge
        let dark: RGBA = white ? (0.78, 0.79, 0.77, 0.95) : (0.04, 0.11, 0.05, 0.95)
        let light: RGBA = white ? (1, 1, 1, 0.95) : (0.22, 0.36, 0.21, 0.95)
        let ww: Float = 0.8 + 0.4 * k                        // wire thickness
        let pitch: Float = 1.6 + 1.1 * k                    // length of one twist
        for sp in spans {
            let steps = max(8, Int(sp.len / 5))
            var prev = (sp.x0, sp.y(sp.x0))
            for s in 1...steps {
                let x = sp.x0 + sp.len * Float(s) / Float(steps), q = (x, sp.y(x))
                if !skip(prev.0) && !skip(q.0) { Mesh.line(&out, prev, q, width: ww, color: dark) }
                prev = q
            }
            // the twist: a short bright slanted stroke on every turn of the upper strand
            let turns = Int(sp.len / pitch)
            if turns > 0 {
                for j in 0..<turns {
                    let x = sp.x0 + (Float(j) + 0.5) * pitch
                    if skip(x) { continue }
                    let y = sp.y(x)
                    Mesh.line(&out, (x - 0.3 * pitch, y - 0.22 * ww), (x + 0.1 * pitch, y + 0.24 * ww),
                              width: 0.36 * ww, color: light)
                }
            }
            // a little clip holding the wire up under the edge
            let hx = sp.x0
            if hx > left + 1 && hx < W - 1 && !skip(hx) {
                Mesh.rect(&out, x: hx - 0.9, y: top - 3, w: 1.8, h: 3, top: (0.78, 0.82, 0.84, 0.75),
                          bottom: (0.42, 0.47, 0.49, 0.85))
            }
        }
        // 3. sockets and glass on top
        for h in bulbs {
            bulb(&out, x: h.x, y: h.y, r: r, color: h.color, b: brightness(h.index, t, style: style), alpha: 1,
                 index: h.index, slots: &slots, shape: .glass, angle: h.angle, parts: .body, whiteSocket: white)
        }
    }

    /// Icicle lights: strands of tiny cool-white LEDs of uneven length hanging from a thin clear wire.
    private static func icicles(_ out: inout [Vertex], width W: Float, y top: Float, t: Float, left: Float,
                                sagScale: Float, gap: Float?, slots: inout [LightCache.Slot]?, skip: (Float) -> Bool) {
        let k = max(0.6, bulbScale)
        let spacing: Float = 14 * max(0.8, k), step: Float = 4.4 * k
        let gapHalf: Float = 11 + 2 * k
        let wireY = { (x: Float) -> Float in
            let u = ((x - left) / 150).truncatingRemainder(dividingBy: 1)
            return top - 1.6 - 2.2 * sagScale * 4 * u * (1 - u)
        }
        let pattern = [3, 5, 2, 4, 6, 3, 4, 2, 5, 3, 6, 4]
        var leds: [Hung] = []
        var radius: [Float] = []
        var strands: [(x0: Float, y0: Float, x1: Float, y1: Float)] = []
        let count = max(0, Int((W - 2 - left) / spacing + 0.5))
        for strand in 0..<count {
            let x = left + spacing * (Float(strand) + 0.5)
            if skip(x) { continue }
            if let g = gap, abs(x - g) < gapHalf { continue }
            let n = max(1, Int(Float(pattern[strand % pattern.count]) * min(1, 0.55 + 0.45 * sagScale)))
            let y0 = wireY(x)
            let sway = (hash01(strand, 13) - 0.5) * 0.6        // strands don't hang perfectly straight
            for j in 0..<n {
                let d = step * (Float(j) + 0.8)
                leds.append(Hung(x: x + sway * Float(j), y: y0 - d, angle: 0, index: strand * 8 + j, color: coolWhite))
                radius.append(j == n - 1 ? 1.4 : 1.15)          // the tip of each icicle is a little bigger
            }
            strands.append((x, y0, x + sway * Float(n - 1), y0 - step * (Float(n - 1) + 0.8)))
        }
        for (h, r) in zip(leds, radius) {
            bulb(&out, x: h.x, y: h.y, r: r, color: h.color, b: brightness(h.index, t, style: .icicle), alpha: 1,
                 index: h.index, slots: &slots, shape: .led, parts: .glow)
        }
        let clear: RGBA = (0.68, 0.75, 0.82, 0.75)        // clear plastic: light on the wall, greyish on a window
        let pieces = max(1, Int(((W - left) / 6).rounded(.up)))
        for s in 0..<pieces {
            let xa = left + (W - left) * Float(s) / Float(pieces), xb = left + (W - left) * Float(s + 1) / Float(pieces)
            if !skip(xa) && !skip(xb) { Mesh.line(&out, (xa, wireY(xa)), (xb, wireY(min(xb, W - 0.01))), width: 0.8, color: clear) }
        }
        for s in strands { Mesh.line(&out, (s.x0, s.y0), (s.x1, s.y1), width: 0.5, color: clear) }
        for (h, r) in zip(leds, radius) {
            bulb(&out, x: h.x, y: h.y, r: r, color: h.color, b: brightness(h.index, t, style: .icicle), alpha: 1,
                 index: h.index, slots: &slots, shape: .led, parts: .body)
        }
    }
}
