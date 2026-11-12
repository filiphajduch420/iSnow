import CoreGraphics
import Foundation

/// Christmas decorations: a decorated tree with presents, a garland of lights under the menu bar.
/// Everything is drawn as triangles; "glow" is a disc that fades to transparent.
enum Christmas {
    // The lights (styles, bulbs, twinkling, the garland and `LightCache`) live in Lights.swift.

    // [1.3 holidays] set by the simulation before drawing
    nonisolated(unsafe) static var advent = 0          // Advent candles lit on the tree (0…24)
    nonisolated(unsafe) static var starBoost: Float = 1 // the star shines brighter on Christmas Eve
    nonisolated(unsafe) static var flash: Float = 0     // > 0: the lights flash (midnight on New Year's Eve)
    static let candleIndex = 100_000                    // bulb indices of the Advent candles start here

    // MARK: Santa's sleigh

    struct Sleigh {
        var x, y, dir, t: Float          // dir: +1 flies to the right, −1 to the left
    }

    /// Santa in his sleigh pulled by reindeer (Rudolph in front), drawn facing the flight direction.
    /// [1.3 reindeer] drawn in Reindeer.swift
    static func sleigh(_ out: inout [Vertex], _ sl: Sleigh, t: Float) {
        SantaSleigh.draw(&out, x: sl.x, y: sl.y, dir: sl.dir, t: t)
    }

    // MARK: Tree

    /// Bounding box of the tree standing at (x, baseY).
    static func treeRect(x: Float, baseY: Float, scale s: Float) -> CGRect {
        CGRect(x: CGFloat(x - 48 * s), y: CGFloat(baseY), width: CGFloat(96 * s), height: CGFloat(112 * s))
    }

    /// `snow` 0…1: how much snow lies on the branches ([1.3 tree], see `treeBody`).
    static func tree(_ out: inout [Vertex], x: Float, baseY: Float, scale s: Float, t: Float,
                     style: LightStyle, alpha a: Float, snow: Float = 0) {
        var none: [LightCache.Slot]?
        var pulse = -1
        tree(&out, x: x, baseY: baseY, scale: s, t: t, style: style, alpha: a, snow: snow, slots: &none, pulse: &pulse)
    }

    /// Same picture as `tree`, from `cache` (rebuilt when the tree moves or the settings change).
    static func tree(_ out: inout [Vertex], cache: inout LightCache, x: Float, baseY: Float, scale s: Float, t: Float,
                     style: LightStyle, alpha a: Float, snow: Float = 0) {
        let key = SIMD8<Float>(x, baseY, s, Float(style.rawValue), bulbScale, glow, a,
                               Float(advent) * 10 + starBoost + snow * 1000)
        if cache.key != key {
            var slots = cache.reset(key: key, occluders: [])
            tree(&cache.verts, x: x, baseY: baseY, scale: s, t: t, style: style, alpha: a, snow: snow, slots: &slots,
                 pulse: &cache.pulse)
            cache.slots = slots ?? []
        }
        let base = out.count
        out.append(contentsOf: cache.verts)
        cache.relight(&out, base: base, t: t, style: style, fade: a)
    }

    static let starGlowSegments = 16 + 2 * starRays     // [1.3 tree] glow disc + tapering rays (Tree.swift)
    static func starGlow(_ t: Float) -> RGBA {
        let pulse = 0.75 + 0.25 * sin(t * 2.3)
        return (1, 0.88, 0.4, min(0.9, 0.45 * pulse * starBoost))
    }
    // [1.3 tree] candleSpots, the tree's shapes and the presents' drawing live in Tree.swift

    private static func tree(_ out: inout [Vertex], x: Float, baseY: Float, scale s: Float, t: Float,
                             style: LightStyle, alpha a: Float, snow: Float, slots: inout [LightCache.Slot]?,
                             pulse: inout Int) {
        let start = out.count
        // [1.3 tree] trunk, snowy base, tiers of branches with snow, bead garland and baubles (Tree.swift)
        treeBody(&out, x: x, baseY: baseY, scale: s, style: style, snow: snow)
        // twinkling lights among the branches
        for (i, p) in treeLightSpots.enumerated() {
            bulb(&out, x: x + p.0 * s, y: baseY + p.1 * s, r: 1.35 * s, color: bulbColor(i + 3, style: style),
                 b: brightness(i + 7, t, style: style), alpha: 1, index: i + 7, slots: &slots)
        }
        // Advent candles: a white candle with a flickering flame for every December day so far
        for i in 0..<min(advent, candleSpots.count) {
            let p = candleSpots[i]
            let cx = x + p.0 * s, cy = baseY + p.1 * s
            treeCandle(&out, x: cx, y: cy, s: s)
            bulb(&out, x: cx, y: cy + 6.3 * s, r: 1.1 * s, color: (1, 0.72, 0.28, 1), b: brightness(candleIndex + i, t, style: style),
                 alpha: 1, index: candleIndex + i, slots: &slots)
        }
        // star with a pulsing glow and rays (longer and brighter on Christmas Eve)
        let sy = baseY + 96 * s
        pulse = out.count - start
        treeStarGlow(&out, x: x, y: sy, s: s, t: t)
        bevelStar(&out, cx: x, cy: sy, r: 8.2 * s * (starBoost > 1 ? 1.12 : 1), s: s)
        // presents in front of the trunk
        for g in treeGifts {
            giftBox(&out, x: x + g.0 * s, y: baseY, w: g.1 * s, h: g.2 * s, color: g.3, ribbon: g.4, s: s)
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
