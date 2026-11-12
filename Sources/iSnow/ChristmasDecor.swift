import CoreGraphics
import Foundation

/// [1.3 decor] More Christmas at the bottom of the screen: a gingerbread house with lit windows and a smoking
/// chimney, candy canes and little fir saplings stuck in the snow, a wreath on the front window, small gifts in
/// the snowmen's hands and a few golden star flakes. Plain drawing functions; `Simulation` decides where.
enum ChristmasDecor {
    // MARK: Palette

    static let ginger: RGBA = (0.80, 0.50, 0.25, 1)
    static let gingerDark: RGBA = (0.62, 0.35, 0.16, 1)
    static let choc: RGBA = (0.40, 0.22, 0.11, 1)
    static let chocDark: RGBA = (0.29, 0.15, 0.07, 1)
    static let icing: RGBA = (1, 0.99, 0.97, 1)
    static let snow: RGBA = (1, 1, 1, 0.97)
    static let snowShade: RGBA = (0.86, 0.9, 0.98, 0.97)
    static let red: RGBA = (0.86, 0.12, 0.17, 1)
    static let green: RGBA = (0.16, 0.6, 0.3, 1)
    static let warmLight: RGBA = (1, 0.8, 0.42, 1)
    static let gold: RGBA = (1, 0.82, 0.32, 1)

    // MARK: Gingerbread house

    /// Bounding box of the house (with its chimney and smoke) standing at (x, baseY).
    static func houseRect(x: Float, baseY: Float, scale s: Float) -> CGRect {
        CGRect(x: CGFloat(x - 30 * s), y: CGFloat(baseY), width: CGFloat(60 * s), height: CGFloat(56 * s))
    }

    /// A small cosy gingerbread house: icing along the roof, snow on top, warm windows that flicker softly,
    /// a chimney with a few smoke puffs (`wind` bends them). `wreath`: a wreath on the door (Christmas Eve).
    static func house(_ out: inout [Vertex], x: Float, baseY y0: Float, scale s: Float, t: Float, wind: Float,
                      wreath: Bool, alpha: Float) {
        let start = out.count
        func p(_ dx: Float, _ dy: Float) -> (Float, Float) { (x + dx * s, y0 + dy * s) }
        func rect(_ x0: Float, _ y: Float, _ w: Float, _ h: Float, _ top: RGBA, _ bottom: RGBA) {
            Mesh.rect(&out, x: x + x0 * s, y: y0 + y * s, w: w * s, h: h * s, top: top, bottom: bottom)
        }

        // Smoke first, so the chimney stands in front of it: puffs rise, grow and fade.
        let chim = p(13.5, 52)
        for k in 0..<5 {
            let u = (t * 0.16 + Float(k) / 5).truncatingRemainder(dividingBy: 1)
            let sway = sin(t * 0.9 + Float(k) * 1.7) * 2.5 * u + max(-30, min(30, wind)) * 0.45 * u
            let cx = chim.0 + sway * s + u * 4 * s, cy = chim.1 + 3 * s + u * 30 * s
            let a = 0.55 * (1 - u) * min(1, u * 6)
            Mesh.circle(&out, cx: cx, cy: cy, r: (2 + 5 * u) * s, center: (0.95, 0.95, 0.97, a),
                        rim: (0.86, 0.88, 0.93, a * 0.15), segments: 12)
        }

        // Walls and gable
        rect(-21, 0, 42, 24, ginger, gingerDark)
        Mesh.tri(&out, p(-21, 23.5), p(21, 23.5), p(0, 40), ginger)

        // Warm windows: soft glow, lit pane, icing frame and cross
        let flick = 0.88 + 0.12 * sin(t * 2.3) * sin(t * 3.7 + 1.1)
        func window(_ cx: Float, _ cy: Float, _ hw: Float, _ hh: Float, _ ph: Float) {
            let b = flick * (0.94 + 0.06 * sin(t * 5.3 + ph))
            let c = p(cx, cy)
            HolidayScene.glow(&out, x: c.0, y: c.1, r: 11 * s, center: (1, 0.78, 0.4, 0.3 * b),
                              rim: (1, 0.7, 0.3, 0), segments: 12)
            rect(cx - hw - 0.9, cy - hh - 0.9, 2 * hw + 1.8, 2 * hh + 1.8, icing, icing)
            let lit: RGBA = (1, 0.72 + 0.16 * b, 0.32 + 0.2 * b, 1)
            rect(cx - hw, cy - hh, 2 * hw, 2 * hh, (1, 0.9, 0.62, 1), lit)
            Mesh.line(&out, p(cx, cy - hh), p(cx, cy + hh), width: 0.9 * s, color: icing)
            Mesh.line(&out, p(cx - hw, cy), p(cx + hw, cy), width: 0.9 * s, color: icing)
            rect(cx - hw - 1.6, cy - hh - 2.2, 2 * hw + 3.2, 1.6, snow, snowShade)       // snowy sill
        }
        window(-13, 13, 4, 4.2, 0)
        window(13, 13, 4, 4.2, 2.1)
        // round attic window in the gable
        let attic = p(0, 30.5)
        Mesh.disc(&out, cx: attic.0, cy: attic.1, r: 3.6 * s, color: icing)
        Mesh.circle(&out, cx: attic.0, cy: attic.1, r: 2.7 * s,
                    center: (1, 0.92, 0.66, 1), rim: (1, 0.72 * flick + 0.1, 0.34, 1), segments: 12)

        // Door with a rounded top and an icing outline
        let door = p(0, 11)
        Mesh.disc(&out, cx: door.0, cy: door.1, r: 5.2 * s, color: icing)
        rect(-5.2, 0, 10.4, 11, icing, icing)
        Mesh.disc(&out, cx: door.0, cy: door.1, r: 4.3 * s, color: choc)
        rect(-4.3, 0, 8.6, 11, choc, chocDark)
        Mesh.disc(&out, cx: door.0 + 2.4 * s, cy: y0 + 6.5 * s, r: 0.75 * s, color: gold)
        if wreath { Self.wreath(&out, cx: door.0, cy: door.1 - 1 * s, r: 2.9 * s, alpha: 1) }

        // Candy buttons on the corners and a gumdrop row under the eaves
        for (i, cx) in stride(from: Float(-17), through: 17, by: 5.6667).enumerated() {
            let c = p(cx, 21.2)
            Mesh.disc(&out, cx: c.0, cy: c.1, r: 1.15 * s, color: i % 2 == 0 ? red : green)
        }
        for cy: Float in [3, 9, 15] {
            for cx: Float in [-19.2, 19.2] {
                let c = p(cx, cy)
                Mesh.disc(&out, cx: c.0, cy: c.1, r: 0.95 * s, color: icing)
            }
        }

        // Roof: two chocolate slopes with icing drips along the eaves and snow on top
        let peak: (Float, Float) = (0, 44), eaveL: (Float, Float) = (-27, 20.5), eaveR: (Float, Float) = (27, 20.5)
        for (a, b) in [(eaveL, peak), (peak, eaveR)] {
            let dx = b.0 - a.0, dy = b.1 - a.1, len = (dx * dx + dy * dy).squareRoot()
            let nx = -dy / len, ny = dx / len                              // outward (up) for both slopes
            let up: Float = dx > 0 ? 1 : -1
            let n = (nx * up, ny * up)
            let th: Float = 5
            let a1 = p(a.0, a.1), b1 = p(b.0, b.1)
            let a2 = p(a.0 + n.0 * th, a.1 + n.1 * th), b2 = p(b.0 + n.0 * th, b.1 + n.1 * th)
            Mesh.v(&out, a1.0, a1.1, chocDark); Mesh.v(&out, b1.0, b1.1, chocDark); Mesh.v(&out, b2.0, b2.1, choc)
            Mesh.v(&out, a1.0, a1.1, chocDark); Mesh.v(&out, b2.0, b2.1, choc); Mesh.v(&out, a2.0, a2.1, choc)
            // shingles: a row of little icing dots
            for k in 1..<7 {
                let f = Float(k) / 7
                let c = p(a.0 + dx * f + n.0 * th * 0.5, a.1 + dy * f + n.1 * th * 0.5)
                Mesh.disc(&out, cx: c.0, cy: c.1, r: 0.7 * s, color: (1, 0.9, 0.8, 1))
            }
            // icing along the lower edge: a white band with drops
            Mesh.line(&out, p(a.0, a.1), p(b.0, b.1), width: 1.5 * s, color: icing)
            for k in 0...8 {
                let f = (Float(k) + 0.5) / 9
                let c = p(a.0 + dx * f - n.0 * 0.6, a.1 + dy * f - n.1 * 0.6)
                let drop = (k % 3 == 1 ? 2.4 : 1.5) * s
                Mesh.disc(&out, cx: c.0, cy: c.1 - drop * 0.4, r: drop * 0.55, color: icing)
            }
            // snow on top of the slope, a little lumpy
            let t1 = th + 2.4
            let a3 = p(a.0 + n.0 * t1, a.1 + n.1 * t1), b3 = p(b.0 + n.0 * t1, b.1 + n.1 * t1)
            Mesh.v(&out, a2.0, a2.1, snowShade); Mesh.v(&out, b2.0, b2.1, snowShade); Mesh.v(&out, b3.0, b3.1, snow)
            Mesh.v(&out, a2.0, a2.1, snowShade); Mesh.v(&out, b3.0, b3.1, snow); Mesh.v(&out, a3.0, a3.1, snow)
            for k in 0..<4 {
                let f = (Float(k) + 0.4) / 4.2
                let c = p(a.0 + dx * f + n.0 * (t1 - 0.6), a.1 + dy * f + n.1 * (t1 - 0.6))
                Mesh.circle(&out, cx: c.0, cy: c.1, r: (1.5 + Float(k % 2) * 0.6) * s, center: snow, rim: snowShade, segments: 10)
            }
        }
        // close the ridge where the two slopes meet, then a snow cap on it
        let len = (27 * 27 + 23.5 * 23.5 as Float).squareRoot()
        let nL = (-23.5 / len, 27 / len), nR = (23.5 / len, 27 / len)
        Mesh.tri(&out, p(peak.0, peak.1), p(nL.0 * 5, peak.1 + nL.1 * 5), p(nR.0 * 5, peak.1 + nR.1 * 5), choc)
        Mesh.tri(&out, p(nL.0 * 5, peak.1 + nL.1 * 5), p(nL.0 * 7.4, peak.1 + nL.1 * 7.4), p(nR.0 * 7.4, peak.1 + nR.1 * 7.4), snow)
        Mesh.tri(&out, p(nL.0 * 5, peak.1 + nL.1 * 5), p(nR.0 * 7.4, peak.1 + nR.1 * 7.4), p(nR.0 * 5, peak.1 + nR.1 * 5), snow)
        Mesh.circle(&out, cx: x, cy: y0 + 50.5 * s, r: 3.4 * s, center: snow, rim: snowShade, segments: 12)

        // Chimney sticking out of the right slope: its foot follows the snow on the roof, icing rim, snow cap.
        let roofTop = { (dx: Float) -> Float in 44 + 7.4 / (27 / len) - dx * 23.5 / 27 - 1.2 }
        let c0 = p(10, roofTop(10)), c1 = p(17, roofTop(17)), c2 = p(17, 50.5), c3 = p(10, 50.5)
        Mesh.v(&out, c0.0, c0.1, gingerDark); Mesh.v(&out, c1.0, c1.1, gingerDark); Mesh.v(&out, c2.0, c2.1, ginger)
        Mesh.v(&out, c0.0, c0.1, gingerDark); Mesh.v(&out, c2.0, c2.1, ginger); Mesh.v(&out, c3.0, c3.1, ginger)
        for k in 0..<2 {                                                     // two icing brick lines
            let yy = 47.5 - Float(k) * 3.4
            Mesh.line(&out, p(10, yy), p(17, yy), width: 0.7 * s, color: (1, 0.92, 0.84, 0.9))
        }
        rect(9, 50, 9, 2.4, icing, (0.93, 0.9, 0.86, 1))
        Mesh.circle(&out, cx: chim.0 - 1.6 * s, cy: chim.1 + 0.6 * s, r: 2.2 * s, center: snow, rim: snowShade, segments: 10)
        Mesh.circle(&out, cx: chim.0 + 2 * s, cy: chim.1 + 0.3 * s, r: 1.6 * s, center: snow, rim: snowShade, segments: 10)
        Mesh.circle(&out, cx: c0.0 - 0.6 * s, cy: c0.1 + 0.4 * s, r: 2 * s, center: snow, rim: snowShade, segments: 10)

        // Two candy canes stuck in the snow by the front corners, hooks turned outwards (feet in the snow banks).
        candyCane(&out, x: x - 25.5 * s, y: y0 - 1.5 * s, height: 15 * s, s: s * 0.6, flip: true)
        candyCane(&out, x: x + 25.5 * s, y: y0 - 1.5 * s, height: 15 * s, s: s * 0.6, flip: false)

        // Snow banked against the walls
        for (dx, r) in [(Float(-23), Float(5.5)), (-12, 3.5), (12, 4), (24, 6)] {
            let c = p(dx, -1)
            Mesh.sector(&out, cx: c.0, cy: c.1, r: r * s, from: 0, to: .pi, center: snow, rim: snowShade, segments: 8)
        }
        if alpha < 1 { for i in start..<out.count { out[i].a *= alpha } }
    }

    // MARK: Wreath

    /// A round wreath of fir with red berries and a red bow on top. `hangFrom`: hangs from a ribbon tied up at that y.
    static func wreath(_ out: inout [Vertex], cx: Float, cy: Float, r: Float, alpha a: Float, hangFrom: Float? = nil) {
        let start = out.count
        let dark: RGBA = (0.05, 0.3, 0.14, 1), light: RGBA = (0.2, 0.58, 0.28, 1), mid: RGBA = (0.12, 0.47, 0.22, 1)
        let n = 14
        let leaf = r * 0.42
        if let top = hangFrom {                      // the ribbon it hangs from, behind the greenery
            Mesh.line(&out, (cx, cy), (cx, top), width: max(0.8, r * 0.14), color: (0.62, 0.05, 0.1, 1))
            Mesh.disc(&out, cx: cx, cy: top - 0.6, r: max(0.8, r * 0.13), color: (0.75, 0.75, 0.78, 1))   // the pin
        }
        // needles poking out (darker spikes), under the bushy ring
        for k in 0..<(2 * n) {
            let ang = (Float(k) + 0.5) / Float(2 * n) * 2 * .pi
            let o = (cx + cos(ang) * (r + leaf * 1.05), cy + sin(ang) * (r + leaf * 1.05))
            Mesh.line(&out, (cx + cos(ang) * r, cy + sin(ang) * r), o, width: max(0.5, r * 0.09), color: dark)
        }
        for k in 0..<n {
            let ang = Float(k) / Float(n) * 2 * .pi
            let px = cx + cos(ang) * r, py = cy + sin(ang) * r
            Mesh.circle(&out, cx: px, cy: py, r: leaf, center: k % 2 == 0 ? light : mid, rim: dark, segments: 8)
        }
        // a lighter inner layer, offset half a step, catches the light from above
        for k in 0..<n {
            let ang = (Float(k) + 0.5) / Float(n) * 2 * .pi
            let px = cx + cos(ang) * r * 0.97, py = cy + sin(ang) * r * 0.97 + r * 0.04
            Mesh.circle(&out, cx: px, cy: py, r: leaf * 0.62, center: (0.3, 0.66, 0.34, 1), rim: mid, segments: 8)
        }
        // a dusting of snow along the top
        for k in 0..<5 {
            let ang = Float.pi * (0.22 + Float(k) * 0.14)
            Mesh.disc(&out, cx: cx + cos(ang) * r * 1.05, cy: cy + sin(ang) * r * 1.05 + leaf * 0.35,
                      r: leaf * (k % 2 == 0 ? 0.42 : 0.3), color: (1, 1, 1, 0.92))
        }
        // berries
        for k in [1, 4, 6, 9, 11] {
            let ang = Float(k) / Float(n) * 2 * .pi + 0.2
            Mesh.disc(&out, cx: cx + cos(ang) * r * 1.05, cy: cy + sin(ang) * r * 1.05, r: max(0.7, r * 0.13),
                      color: (0.92, 0.1, 0.15, 1))
        }
        // bow on top: two loops, two tails, a knot
        let bx = cx, by = cy + r * 0.95, w = r * 0.62
        let bow: RGBA = (0.88, 0.1, 0.15, 1), bowDark: RGBA = (0.62, 0.05, 0.1, 1)
        Mesh.tri(&out, (bx - r * 0.12, by - r * 0.1), (bx - r * 0.42, by - r * 0.85), (bx - r * 0.12, by - r * 0.75), bowDark)
        Mesh.tri(&out, (bx + r * 0.12, by - r * 0.1), (bx + r * 0.42, by - r * 0.85), (bx + r * 0.12, by - r * 0.75), bowDark)
        Mesh.tri(&out, (bx, by), (bx - w, by + w * 0.55), (bx - w, by - w * 0.45), bow)
        Mesh.tri(&out, (bx, by), (bx + w, by + w * 0.55), (bx + w, by - w * 0.45), bow)
        Mesh.disc(&out, cx: bx, cy: by, r: max(0.6, r * 0.17), color: (1, 0.3, 0.32, 1))
        if a < 1 { for i in start..<out.count { out[i].a *= a } }
    }

    // MARK: Candy canes and saplings

    enum Kind { case cane, sapling }
    struct Item { var u: Float; var kind: Kind; var flip: Bool; var size: Float }

    /// Fixed for the session: a handful of spots spread along the bottom (fractions of the screen width).
    static func scatter() -> [Item] {
        let n = 11
        return (0..<n).map { i in
            let u = (Float(i) + Float.random(in: 0.2...0.8)) / Float(n)
            let kind: Kind = Float.random(in: 0...1) < 0.55 ? .cane : .sapling
            return Item(u: u, kind: kind, flip: Bool.random(), size: .random(in: 0.85...1.15))
        }
    }

    /// Height of an item in points (its base is pushed into the drift, so about half of it shows).
    static func height(_ it: Item, scale s: Float) -> Float {
        (it.kind == .cane ? 22 : 26) * it.size * s
    }

    static func halfWidth(_ it: Item, scale s: Float) -> Float {
        (it.kind == .cane ? 6 : 9) * it.size * s
    }

    static func item(_ out: inout [Vertex], _ it: Item, x: Float, baseY: Float, scale s0: Float, alpha: Float) {
        let start = out.count
        let s = s0 * it.size
        switch it.kind {
        case .cane: candyCane(&out, x: x, y: baseY, height: 22 * s, s: s, flip: it.flip)
        case .sapling: sapling(&out, x: x, y: baseY, s: s, flip: it.flip)
        }
        if alpha < 1 { for i in start..<out.count { out[i].a *= alpha } }
    }

    /// A red and white striped candy cane, hook at the top (to the right, or left when `flip`).
    static func candyCane(_ out: inout [Vertex], x: Float, y: Float, height h: Float, s: Float, flip: Bool) {
        let d: Float = flip ? -1 : 1
        let w = 2.6 * s, hr = 3.6 * s
        // the path: straight up, then a half circle over to the hook's end, then a little way down
        var pts: [(Float, Float)] = [(x, y), (x, y + h - hr)]
        let cx = x + d * hr, cy = y + h - hr
        for k in 1...8 {
            let a = Float(k) / 8 * .pi
            pts.append((cx - d * hr * cos(a), cy + hr * sin(a)))
        }
        pts.append((cx + d * hr, cy - 2.2 * s))
        stripedPath(&out, pts, width: w, stripe: 2.4 * s)
        // a soft highlight down the stick
        Mesh.line(&out, (x - d * w * 0.22, y), (x - d * w * 0.22, y + h - hr), width: w * 0.22, color: (1, 1, 1, 0.35))
    }

    /// Thick polyline in alternating white and red bands `stripe` long (slanted ends make the stripes diagonal).
    private static func stripedPath(_ out: inout [Vertex], _ pts: [(Float, Float)], width w: Float, stripe: Float) {
        let white: RGBA = (1, 0.98, 0.97, 1), redC: RGBA = (0.9, 0.12, 0.16, 1)
        guard pts.count > 1, stripe > 0.01, stripe.isFinite else { return }
        // The current band and how much of it is left are tracked explicitly: recomputing the band from the
        // travelled distance could round so that a step made no progress and the loop never ended.
        var band = 0
        var left = stripe
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let dx = b.0 - a.0, dy = b.1 - a.1
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            let ux = dx / len, uy = dy / len
            let nx = -uy * w / 2, ny = ux * w / 2
            var l: Float = 0
            // Hard cap on the bands in one segment (one per full stripe plus the carried-in rest): the loop
            // ends even if float rounding ever stalls `l`.
            var budget = Int(len / stripe) + 3
            while l < len && budget > 0 {
                budget -= 1
                let next = min(len, l + left)
                let col = band % 2 == 0 ? white : redC
                // stretch a hair at both ends so segments overlap on the curve; slant the ends for diagonal stripes
                let e0 = max(0, l - 0.3), e1 = min(len + 0.3, next + 0.3)
                let sl = w * 0.35
                let p0 = (a.0 + ux * e0, a.1 + uy * e0), p1 = (a.0 + ux * e1, a.1 + uy * e1)
                let q0 = (p0.0 + nx + ux * sl, p0.1 + ny + uy * sl), q1 = (p0.0 - nx - ux * sl, p0.1 - ny - uy * sl)
                let q2 = (p1.0 - nx - ux * sl, p1.1 - ny - uy * sl), q3 = (p1.0 + nx + ux * sl, p1.1 + ny + uy * sl)
                Mesh.tri(&out, q0, q1, q2, col)
                Mesh.tri(&out, q0, q2, q3, col)
                left -= next - l
                if next >= len && left > 0.0001 { break }   // segment done, the band carries on into the next one
                band += 1
                left = stripe
                l = next
            }
        }
    }

    /// A little fir sapling: three drooping tiers, lit from the left, with snow along their tops and tips,
    /// every other one with a red bow.
    static func sapling(_ out: inout [Vertex], x: Float, y: Float, s: Float, flip: Bool) {
        Mesh.rect(&out, x: x - 1.4 * s, y: y, w: 2.8 * s, h: 6 * s, top: (0.42, 0.26, 0.13, 1), bottom: (0.3, 0.18, 0.09, 1))
        let tiers: [(w: Float, y: Float, h: Float)] = [(19, 4, 11.5), (15, 10, 10.5), (10, 16, 10)]
        let snowC: RGBA = (1, 1, 1, 0.96), snowS: RGBA = (0.84, 0.89, 0.97, 0.96)
        for (k, tier) in tiers.enumerated() {
            let by = y + tier.y * s, hw = tier.w * s / 2, ty = by + tier.h * s, sag = 1.6 * s
            let g = Float(k) * 0.03
            let lightL: RGBA = (0.14, 0.52 + g, 0.27, 1), darkL: RGBA = (0.07, 0.36 + g, 0.18, 1)
            let lightR: RGBA = (0.08, 0.4 + g, 0.2, 1), darkR: RGBA = (0.03, 0.25 + g, 0.13, 1)
            // two halves meeting in a droop at the bottom middle: the left one catches the light
            Mesh.v(&out, x - hw, by, darkL); Mesh.v(&out, x, by + sag, darkL); Mesh.v(&out, x, ty, lightL)
            Mesh.v(&out, x, by + sag, darkR); Mesh.v(&out, x + hw, by, darkR); Mesh.v(&out, x, ty, lightR)
            // snow lying along the upper part of both slopes, thicker on the left
            let f: Float = 0.55
            let ml = (x - hw * f, by + tier.h * s * (1 - f)), mr = (x + hw * f, by + tier.h * s * (1 - f))
            Mesh.v(&out, ml.0, ml.1, snowS); Mesh.v(&out, x, ty + 0.5 * s, snowC); Mesh.v(&out, ml.0 + 0.6 * s, ml.1 + 1.8 * s, snowC)
            Mesh.v(&out, x, ty + 0.5 * s, snowC); Mesh.v(&out, mr.0, mr.1, snowS); Mesh.v(&out, mr.0 - 0.5 * s, mr.1 + 1.2 * s, snowC)
            Mesh.tri(&out, (x - 1.3 * s, ty - 1.4 * s), (x + 1.3 * s, ty - 1.4 * s), (x, ty + 0.6 * s), snowC)
            // little clumps on the drooping tips
            Mesh.circle(&out, cx: x - hw + 1.2 * s, cy: by + 0.9 * s, r: 1.3 * s, center: snowC, rim: snowS, segments: 8)
            Mesh.circle(&out, cx: x + hw - 1.2 * s, cy: by + 0.8 * s, r: 1.1 * s, center: snowC, rim: snowS, segments: 8)
        }
        if flip {                                    // a tiny red bow on every other one
            let c = (x + 1.8 * s, y + 17.5 * s)
            Mesh.tri(&out, c, (c.0 - 2.4 * s, c.1 + 1.4 * s), (c.0 - 2.4 * s, c.1 - 1.3 * s), red)
            Mesh.tri(&out, c, (c.0 + 2.4 * s, c.1 + 1.4 * s), (c.0 + 2.4 * s, c.1 - 1.3 * s), red)
            Mesh.tri(&out, c, (c.0 - 1.4 * s, c.1 - 2.6 * s), (c.0 - 0.4 * s, c.1 - 2.8 * s), (0.66, 0.06, 0.1, 1))
            Mesh.tri(&out, c, (c.0 + 1.4 * s, c.1 - 2.6 * s), (c.0 + 0.4 * s, c.1 - 2.8 * s), (0.66, 0.06, 0.1, 1))
            Mesh.disc(&out, cx: c.0, cy: c.1, r: 0.75 * s, color: (1, 0.3, 0.32, 1))
        }
    }

    // MARK: Gifts in the snowmen's hands

    /// `kind` 1: a candy cane, 2 or 3: a small present dangling from the twig by its ribbon (blue with gold,
    /// red with white), held in the hand at `hand` (other values: nothing).
    static func keepsake(_ out: inout [Vertex], kind: Int, hand: (Float, Float), s: Float, alpha a: Float) {
        guard a > 0.01, (1...3).contains(kind) else { return }
        let start = out.count
        if kind == 1 {
            candyCane(&out, x: hand.0, y: hand.1 - 6 * s, height: 17 * s, s: s * 0.75, flip: true)
        } else {
            let blue = kind == 2
            let color: RGBA = blue ? (0.2, 0.48, 0.9, 1) : (0.86, 0.14, 0.2, 1)
            let ribbonC: RGBA = blue ? (1, 0.84, 0.3, 1) : (1, 0.97, 0.94, 1)
            let w = 9 * s, h = 7.5 * s
            let x = hand.0 + 1 * s, top = hand.1 - 4.2 * s
            // the loop of ribbon over the twig, then the box hanging under it (a slight swing to the side)
            Mesh.line(&out, (x - 1.2 * s, top + 1.4 * s), (hand.0 + 0.4 * s, hand.1 + 0.6 * s), width: 0.8 * s, color: ribbonC)
            Mesh.line(&out, (x + 1.2 * s, top + 1.4 * s), (hand.0 + 1.6 * s, hand.1 + 0.6 * s), width: 0.8 * s, color: ribbonC)
            HolidayScene.present(&out, x: x, y: top - h, w: w, h: h, color: color, ribbon: ribbonC, s: s * 0.75)
        }
        if a < 1 { for i in start..<out.count { out[i].a *= a } }
    }

    // MARK: Golden star flakes

    static let maxGoldenFlakes = 40

    /// A flake that is drawn as a golden star (a stable pick: depends only on its random sway frequency).
    @inline(__always)
    static func isGolden(_ f: Flake) -> Bool {
        (f.freq * 1013.37).truncatingRemainder(dividingBy: 1) < 0.035
    }

    /// A tiny golden star with a soft glow: four long rays and four short ones between them, twinkling and
    /// turning slowly as it falls.
    static func goldenFlake(_ out: inout [Vertex], x: Float, y: Float, size: Float, alpha: Float, t: Float, phase: Float) {
        let tw = 0.7 + 0.3 * sin(t * 5 + phase * 4)
        let r = (1.7 + size * 0.7) * (0.85 + 0.25 * tw)
        let a = min(1, alpha * 1.2) * (0.72 + 0.28 * tw)
        HolidayScene.glow(&out, x: x, y: y, r: r * 1.7, center: (1, 0.84, 0.42, 0.3 * a), rim: (1, 0.75, 0.3, 0), segments: 8)
        let rot = phase * 0.5 + sin(t * 0.7 + phase) * 0.6
        let core: RGBA = (1, 0.95, 0.72, a), tip: RGBA = (1, 0.74, 0.2, a * 0.85)
        for k in 0..<8 {
            let long = k % 2 == 0
            let len = long ? r : r * 0.48, q = long ? r * 0.17 : r * 0.12
            let ang = rot + Float(k) * .pi / 4
            let ca = cos(ang), sa = sin(ang)
            Mesh.v(&out, x - sa * q, y + ca * q, core); Mesh.v(&out, x + sa * q, y - ca * q, core)
            Mesh.v(&out, x + ca * len, y + sa * len, tip)
        }
        Mesh.disc(&out, cx: x, cy: y, r: r * 0.2, color: (1, 0.98, 0.86, a))
    }
}
