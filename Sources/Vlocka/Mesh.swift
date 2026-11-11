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
    static func snowColumn(_ out: inout [Vertex], l: Float, m: Float, r: Float, base: Float,
                           hl: Float, hm: Float, hr: Float) {
        let top = snowTop, bot = snowBase
        // left half
        v(&out, l, base, bot); v(&out, m, base, bot); v(&out, m, base + hm, top)
        v(&out, l, base, bot); v(&out, m, base + hm, top); v(&out, l, base + hl, top)
        // right half
        v(&out, m, base, bot); v(&out, r, base, bot); v(&out, r, base + hr, top)
        v(&out, m, base, bot); v(&out, r, base + hr, top); v(&out, m, base + hm, top)
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
        var prev = (cx + r, cy)
        for s in 1...segments {
            let a = Float(s) / Float(segments) * 2 * .pi
            let p = (cx + cos(a) * r, cy + sin(a) * r)
            v(&out, ox, oy, center); v(&out, prev.0, prev.1, rim); v(&out, p.0, p.1, rim)
            prev = p
        }
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
