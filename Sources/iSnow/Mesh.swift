import Foundation

typealias RGBA = (Float, Float, Float, Float)

/// Helpers for building triangles (all in points, y up).
enum Mesh {
    nonisolated(unsafe) static var tint: (Float, Float, Float) = (1, 1, 1)
    static var snowTop: RGBA { (tint.0, tint.1, tint.2, 0.97) }
    static var snowBase: RGBA { (0.84 * tint.0, 0.89 * tint.1, 0.97 * tint.2, 0.95) }

    static func quad(_ out: inout [Vertex], x: Float, y: Float, w: Float, h: Float, bl: RGBA, br: RGBA, tr: RGBA, tl: RGBA) {
        v(&out, x, y, bl); v(&out, x + w, y, br); v(&out, x + w, y + h, tr)
        v(&out, x, y, bl); v(&out, x + w, y + h, tr); v(&out, x, y + h, tl)
    }

    @inline(__always)
    static func v(_ out: inout [Vertex], _ x: Float, _ y: Float, _ c: RGBA) {
        out.append(Vertex(x: x, y: y, r: c.0, g: c.1, b: c.2, a: c.3))
    }

    @inline(__always)
    static func tri(_ out: inout [Vertex], _ a: (Float, Float), _ b: (Float, Float), _ c: (Float, Float), _ col: RGBA) {
        v(&out, a.0, a.1, col); v(&out, b.0, b.1, col); v(&out, c.0, c.1, col)
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Float) -> RGBA {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t, a.3 + (b.3 - a.3) * t)
    }

    /// One drift column: two trapezoids with a vertical gradient (bluish shade at the bottom).
    /// Screen-anchored texture; drifts that move use the `anchor:` variant.
    static func snowColumn(_ out: inout [Vertex], l: Float, m: Float, r: Float, base: Float,
                           hl: Float, hm: Float, hr: Float) {
        snowColumn(&out, l: l, m: m, r: r, base: base, hl: hl, hm: hm, hr: hr, material: snowMaterial(kind: 1, anchor: (0, 0)))
    }

    /// Drift column drawn with the procedural snow material (crust, cool shadow, grain, glints – see the
    /// shader). `material` comes from `snowMaterial(kind: 1, anchor:)`, anchored to the pile so the texture
    /// travels with a dragged window. The colour gradient and tint are applied in the shader.
    static func snowColumn(_ out: inout [Vertex], l: Float, m: Float, r: Float, base: Float,
                           hl: Float, hm: Float, hr: Float, material mat: SnowMaterial) {
        let a0 = snowTop.3, a1 = snowBase.3
        @inline(__always) func s(_ x: Float, _ y: Float, depth: Float, grad: Float) {
            out.append(Vertex(x: x, y: y, r: mat.r + min(depth, 2000), g: mat.g + grad, b: mat.b,
                              a: a0 + (a1 - a0) * grad))
        }
        // left half
        s(l, base, depth: hl, grad: 1); s(m, base, depth: hm, grad: 1); s(m, base + hm, depth: 0, grad: 0)
        s(l, base, depth: hl, grad: 1); s(m, base + hm, depth: 0, grad: 0); s(l, base + hl, depth: 0, grad: 0)
        // right half
        s(m, base, depth: hm, grad: 1); s(r, base, depth: hr, grad: 1); s(r, base + hr, depth: 0, grad: 0)
        s(m, base, depth: hm, grad: 1); s(r, base + hr, depth: 0, grad: 0); s(m, base + hm, depth: 0, grad: 0)
    }

    /// Flat-topped block of snow (menu-bar powder) with the drift material.
    static func snowRect(_ out: inout [Vertex], x: Float, y: Float, w: Float, h: Float, material mat: SnowMaterial) {
        snowColumn(&out, l: x, m: x + w * 0.5, r: x + w, base: y, hl: h, hm: h, hr: h, material: mat)
    }

    /// Integer offsets that tag mesh vertices as procedural snow for `mesh_fs` (plain colours stay ≤ 1):
    /// red += 2048·kind (1 = drift, red/green = depth/gradient; 2 = snow ball, plain colour),
    /// green/blue += 4·anchor in quarter points mod 512 (the grain is anchored to the shape).
    struct SnowMaterial { let r, g, b: Float }

    static func snowMaterial(kind: Int, anchor: (Float, Float)) -> SnowMaterial {
        func q(_ v: Float) -> Float {
            guard v.isFinite else { return 0 }
            let i = Int((Double(v) * 4).rounded(.down).truncatingRemainder(dividingBy: 2048))
            return Float((i + 2048) % 2048) * 4
        }
        return SnowMaterial(r: Float(2048 * kind), g: q(anchor.0), b: q(anchor.1))
    }

    static func rect(_ out: inout [Vertex], x: Float, y: Float, w: Float, h: Float, top: RGBA, bottom: RGBA) {
        v(&out, x, y, bottom); v(&out, x + w, y, bottom); v(&out, x + w, y + h, top)
        v(&out, x, y, bottom); v(&out, x + w, y + h, top); v(&out, x, y + h, top)
    }

    /// Icicle hanging down from the `top` edge.
    static func icicle(_ out: inout [Vertex], x: Float, top: Float, len: Float, width: Float, alpha: Float) {
        let w = min(width, 2 + len * 0.3)
        let root: RGBA = (0.93, 0.97, 1, alpha)
        let tip: RGBA = (0.70, 0.84, 1, alpha * 0.55)
        let hi: RGBA = (1, 1, 1, alpha)
        v(&out, x - w / 2, top, root); v(&out, x + w / 2, top, root); v(&out, x, top - len, tip)
        // highlight
        v(&out, x - w * 0.25, top, hi); v(&out, x - w * 0.05, top, hi); v(&out, x - w * 0.08, top - len * 0.6, (1, 1, 1, 0))
    }

    /// Shaded ball – a fan from a lighter centre to a bluish rim.
    static func circle(_ out: inout [Vertex], cx: Float, cy: Float, r: Float, center: RGBA, rim: RGBA, segments: Int = 28) {
        let ox = cx - r * 0.25, oy = cy + r * 0.25        // light from the top left
        // Big white balls with a bluish rim (snowman bodies, rolled balls) get the snow grain, anchored to
        // the ball's centre. Everything else (eyes, lights, Santa, ornaments) stays a plain colour.
        var c = center, e = rim
        if segments >= 16 && r >= 4 && isSnowBall(center: center, rim: rim) {
            let m = snowMaterial(kind: 2, anchor: (cx, cy))
            c = (center.0 + m.r, center.1 + m.g, center.2 + m.b, center.3)
            e = (rim.0 + m.r, rim.1 + m.g, rim.2 + m.b, rim.3)
        }
        var prev = (cx + r, cy)
        for s in 1...segments {
            let a = Float(s) / Float(segments) * 2 * .pi
            let p = (cx + cos(a) * r, cy + sin(a) * r)
            v(&out, ox, oy, c); v(&out, prev.0, prev.1, e); v(&out, p.0, p.1, e)
            prev = p
        }
    }

    private static func isSnowBall(center c: RGBA, rim e: RGBA) -> Bool {
        c.0 >= 0.97 && c.1 >= 0.97 && c.2 >= 0.97 && c.3 > 0 && c.3 == e.3
            && e.2 >= 0.85 && e.2 <= 1 && e.0 >= 0.6 && e.0 < e.2
    }

    /// Circular sector (frost in window corners).
    static func sector(_ out: inout [Vertex], cx: Float, cy: Float, r: Float, from a0: Float, to a1: Float,
                       center: RGBA, rim: RGBA, segments: Int = 10) {
        var prev = (cx + cos(a0) * r, cy + sin(a0) * r)
        for s in 1...segments {
            let a = a0 + (a1 - a0) * Float(s) / Float(segments)
            let p = (cx + cos(a) * r, cy + sin(a) * r)
            v(&out, cx, cy, center); v(&out, prev.0, prev.1, rim); v(&out, p.0, p.1, rim)
            prev = p
        }
    }

    /// A snow shovel held at the cursor: blade at the tip, handle going up and to the right.
    /// (A background app can't replace the system cursor, so the shovel is drawn next to it.)
    static func shovel(_ out: inout [Vertex], at m: SIMD2<Float>, digging: Bool) {
        let tilt: Float = digging ? 0.15 : 0
        let ang: Float = 0.95 - tilt                       // handle direction
        let dx = cos(ang), dy = sin(ang)
        let base = (m.x + 6, m.y - 4)
        let top = (base.0 + dx * 34, base.1 + dy * 34)
        let wood: RGBA = (0.55, 0.36, 0.2, 1), woodDark: RGBA = (0.38, 0.24, 0.12, 1)
        line(&out, base, top, width: 2.6, color: wood)
        // T-grip
        let nx = -dy, ny = dx
        line(&out, (top.0 - nx * 5, top.1 - ny * 5), (top.0 + nx * 5, top.1 + ny * 5), width: 2.6, color: woodDark)
        // Blade: a slightly curved metal scoop below the handle
        let bx = base.0 - dx * 2, by = base.1 - dy * 2
        let w: Float = 9, l: Float = 13
        let a = (bx + nx * w, by + ny * w), b = (bx - nx * w, by - ny * w)
        let c = (b.0 - dx * l, b.1 - dy * l), d = (a.0 - dx * l, a.1 - dy * l)
        let metal: RGBA = (0.72, 0.76, 0.82, 1), metalDark: RGBA = (0.48, 0.52, 0.58, 1)
        v(&out, a.0, a.1, metal); v(&out, b.0, b.1, metal); v(&out, c.0, c.1, metalDark)
        v(&out, a.0, a.1, metal); v(&out, c.0, c.1, metalDark); v(&out, d.0, d.1, metalDark)
        line(&out, a, b, width: 1.2, color: (0.9, 0.92, 0.95, 1))
        // A little snow on the blade while digging
        if digging {
            circle(&out, cx: (c.0 + d.0) / 2 + dx * 4, cy: (c.1 + d.1) / 2 + dy * 4, r: 4, center: (1, 1, 1, 1),
                   rim: (0.85, 0.9, 0.97, 1), segments: 10)
        }
    }

    /// Thin ring.
    static func ring(_ out: inout [Vertex], cx: Float, cy: Float, r: Float, width: Float, color: RGBA, segments: Int = 28) {
        let r0 = r - width / 2, r1 = r + width / 2
        for s in 0..<segments {
            let a0 = Float(s) / Float(segments) * 2 * .pi, a1 = Float(s + 1) / Float(segments) * 2 * .pi
            let p0 = (cx + cos(a0) * r0, cy + sin(a0) * r0), p1 = (cx + cos(a0) * r1, cy + sin(a0) * r1)
            let p2 = (cx + cos(a1) * r1, cy + sin(a1) * r1), p3 = (cx + cos(a1) * r0, cy + sin(a1) * r0)
            v(&out, p0.0, p0.1, color); v(&out, p1.0, p1.1, color); v(&out, p2.0, p2.1, color)
            v(&out, p0.0, p0.1, color); v(&out, p2.0, p2.1, color); v(&out, p3.0, p3.1, color)
        }
    }

    static func disc(_ out: inout [Vertex], cx: Float, cy: Float, r: Float, color: RGBA) {
        circle(&out, cx: cx, cy: cy, r: r, center: color, rim: color, segments: 12)
    }

    /// Thick line segment (snowman arms).
    static func line(_ out: inout [Vertex], _ a: (Float, Float), _ b: (Float, Float), width: Float, color: RGBA) {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len = max(0.001, (dx * dx + dy * dy).squareRoot())
        let nx = -dy / len * width / 2, ny = dx / len * width / 2
        v(&out, a.0 + nx, a.1 + ny, color); v(&out, a.0 - nx, a.1 - ny, color); v(&out, b.0 - nx, b.1 - ny, color)
        v(&out, a.0 + nx, a.1 + ny, color); v(&out, b.0 - nx, b.1 - ny, color); v(&out, b.0 + nx, b.1 + ny, color)
    }
}
