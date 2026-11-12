import CoreGraphics
import Foundation

/// Snowman on the Dock: rolls in its balls, stacks them, puts on a scarf, waves, throws snowballs,
/// and after a while falls apart and melts. Clicking it knocks it apart.
struct Snowman {
    enum Phase { case absent, rolling, dressing, standing, collapsing, melting }
    /// Headwear. `seasonalHat` on the simulation (e.g. party hats on New Year's Eve) overrides the wardrobe hat.
    enum Hat: Sendable, CaseIterable { case none, topHat, beanie, bucket, santa, party }

    struct LooseBall { var x, y, vx, vy, r, life: Float }
    struct Carrot { var x, y, vy, alpha: Float; var lying: Bool }

    var phase: Phase = .absent
    var t: Float = 0
    var nextBuild: Float = 12
    var anchorX: Float = 0
    var baseY: Float = 0
    static let radii: (Float, Float, Float) = (14, 10, 7)
    var levels = 3
    var scale: Float = 1
    var dress: Float = 0
    var hasCarrot = true
    var hits = 0
    var wobble: Float = 0
    var wave: Float = 0
    var nextWave: Float = 6
    var nextThrow: Float = 25
    var life: Float = 240
    var armThrow: Float = 0
    var loose: [LooseBall] = []
    var carrot: Carrot?
    var sizeScale: Float = 1
    var rebuildDelay: Float = 120
    var throwEvery: Float = 30
    var temperature: Float = -4

    // Where it stands. Keys match the simulation's surfaces (-2 = Dock, -1 = bottom edge).
    var hostKey = -2
    var hostRect: CGRect?
    var offsetX: Float = 0           // position relative to the host's left edge
    var userPlaced = false           // dragged somewhere by the user
    var carried = false              // being dragged right now
    var falling = false
    var vy: Float = 0
    var ghost = false                // faded because it covers a window
    var santaHat = false
    var hidden = false               // under a menu or popover: not drawn, not clickable
    var lookAt: SIMD2<Float>?        // the cursor – the eyes follow it

    // [1.3 snowmen] Wardrobe, snowmen the user rolled, snowball fights.
    var outfit = Snowman.randomOutfit()
    var outfits = true               // cfg.snowmanOutfits (off = the classic red scarf, no hat)
    var seasonalHat: Hat?            // from the simulation (holidays) – overrides the wardrobe and Santa hats
    var sparkler = false             // holds a burning sparkler in its left hand
    var keepsake = Int.random(in: 0..<5)   // [1.3 decor] 1 candy cane, 2-3 present (else nothing) – new for every snowman
    var holdsKeepsake = false        // [1.3 decor] set by the simulation (Christmas decorations on)
    var custom: (Float, Float, Float)?   // ball radii of a snowman the user rolled (in units of sizeScale)
    var userBuilt = false
    var retired = false              // a self-built snowman that is gone (the simulation removes it)
    var id = 0                       // stable identity (panels and snowballs refer to it, not to the array index)
    var duck: Float = 0              // 0…1 how far it has ducked
    var duckDelay: Float = -1        // ≥ 0: ducks when this runs out (it saw a snowball coming)
    var duckHold: Float = 0
    var flyingHat: FlyingHat?        // knocked off by a snowball
    var hatIn: Float = 1             // 0…1: putting a new hat on after one flew off
    var retort: Float = 0            // > 0: seconds until it throws back
    var retortTarget = -1            // -1 = the cursor, ≥ 0 = another snowman's id
    var retortReady = false

    struct Outfit: Sendable { var hat: Hat; var scarf: Int }
    struct FlyingHat { var x, y, vx, vy, angle, spin, alpha, r, s, rest: Float; var lying: Bool; var hat: Hat }

    @inline(__always) func R(_ k: Int) -> Float {
        if let c = custom { return (k == 0 ? c.0 : (k == 1 ? c.1 : c.2)) * scale * sizeScale }
        let r = k == 0 ? Self.radii.0 : (k == 1 ? Self.radii.1 : Self.radii.2)
        return r * scale * sizeScale
    }

    static let rollTime: Float = 1.8

    // MARK: Geometry

    func stackY(_ k: Int) -> Float {
        let r0 = R(0), r1 = R(1)
        let y0 = baseY + r0 * 0.92
        if k == 0 { return y0 }
        let y1 = y0 + r0 * 0.8 + r1 * 0.8
        if k == 1 { return y1 }
        return y1 + r1 * 0.8 + R(2) * 0.85
    }

    /// Position and radius of ball k (accounts for rolling while building).
    func ball(_ k: Int) -> (x: Float, y: Float, r: Float)? {
        guard k < levels else { return nil }
        let r = R(k)
        let wob = k > 0 ? sin(t * 32) * wobble * Float(k) * 1.2 : 0
        if phase == .rolling {
            let cur = Int(t / Self.rollTime)
            if k > cur { return nil }
            if k == cur {
                let u = (t - Float(k) * Self.rollTime) / Self.rollTime
                if u < 0.72 {
                    let p = u / 0.72
                    let ease = 1 - (1 - p) * (1 - p)
                    let rr = r * (0.35 + 0.65 * p)
                    let dist = 150 * sizeScale
                    return (anchorX - dist + dist * ease, baseY + rr * 0.92, rr)
                }
                let p = (u - 0.72) / 0.28
                let y0 = baseY + r * 0.92, y1 = stackY(k)
                let arc = sin(p * .pi) * 10 * sizeScale
                return (anchorX, y0 + (y1 - y0) * p + arc, r)
            }
        }
        return (anchorX + wob, stackY(k) - duckDrop(k), r)
    }

    /// How far ball k sinks while the snowman ducks (the head goes down into the body).
    private func duckDrop(_ k: Int) -> Float {
        guard duck > 0.001, k > 0 else { return 0 }
        let d = R(1) * 0.5
        return duck * (k == 1 ? d : d + R(2) * 0.8)
    }

    var handPosition: SIMD2<Float> {
        let y = stackY(1) + 8 * sizeScale
        return SIMD2(anchorX + R(1) + 13 * sizeScale, y)
    }

    var hitRect: CGRect? {
        guard !ghost || carried else { return nil }
        return bodyRect
    }

    /// Bounding box of the standing snowman (also used to check whether it covers a window).
    var bodyRect: CGRect? {
        guard phase == .standing || phase == .dressing, levels > 0 else { return nil }
        let r0 = R(0)
        let top = (ball(levels - 1).map { $0.y + $0.r } ?? baseY) + 4
        return CGRect(x: CGFloat(anchorX - r0 - 6), y: CGFloat(baseY), width: CGFloat(r0 * 2 + 12), height: CGFloat(top - baseY))
    }

    /// Something about it is animating (the renderer then runs at the full frame rate). A snowman that
    /// just stands, its eyes following the cursor, is not moving.
    var isMoving: Bool {
        if carried || falling { return true }
        switch phase {
        case .rolling, .dressing, .collapsing, .melting: return true
        // `wave` only counts down while standing – a wave cut short by a collapse stays frozen.
        case .standing: return wobble > 0.01 || wave > 0 || armThrow > 0.01 || !loose.isEmpty || carrot != nil || fighting
        case .absent: return wobble > 0.01 || armThrow > 0.01 || !loose.isEmpty || carrot != nil || fighting
        }
    }

    /// Ducking, a hat in the air or a new one being put on.
    private var fighting: Bool {
        duck > 0.001 || duckDelay >= 0 || duckHold > 0 || flyingHat != nil || hatIn < 1
    }

    // MARK: Step

    /// Returns true when the snowman wants to throw a snowball.
    mutating func step(dt: Float, debris: inout [Debris], shards: inout [Shard]) -> Bool {
        t += dt
        wobble = max(0, wobble - dt * 1.8)
        armThrow = max(0, armThrow - dt * 1.5)
        var wantsThrow = false
        stepFight(dt: dt)

        switch phase {
        case .absent:
            // Too warm to build a snowman.
            if temperature <= 1 && !retired { nextBuild -= dt }
            if nextBuild <= 0 && !retired { start() }
        case .rolling:
            if t >= Self.rollTime * 3 { phase = .dressing; t = 0 }
        case .dressing:
            dress = min(1, t / 1.6)
            if t >= 1.6 { phase = .standing; t = 0 }
        case .standing:
            life -= dt
            if wave > 0 { wave = max(0, wave - dt) } else {
                nextWave -= dt
                if nextWave <= 0 { wave = 1.6; nextWave = .random(in: 7...14) }
            }
            nextThrow -= dt
            if nextThrow <= 0 { nextThrow = throwEvery * .random(in: 0.6...1.4); wantsThrow = true }
            if temperature > 0.5 && !carried {
                // Thaw: the snowman slowly shrinks.
                scale -= dt * temperature * 0.0035
                if scale < 0.35 { phase = .melting; t = (1 - scale) * 6 }
            }
            if life <= 0 && !carried { phase = .collapsing; t = 0; dropCarrot() }
        case .collapsing:
            if levels == 3 && t > 0.8 { popTop(debris: &debris, vx: 70) }
            if t > 2.4 { phase = .melting; t = 0 }
        case .melting:
            scale = min(scale, max(0.05, 1 - t / 6))
            if t >= 6 { reset(next: rebuildDelay * .random(in: 0.7...1.3)) }
        }

        // Loose balls and the carrot
        var i = 0
        while i < loose.count {
            var b = loose[i]
            b.life += dt
            b.vy -= 900 * dt
            b.x += b.vx * dt
            b.y += b.vy * dt
            let floor = baseY + b.r * 0.92
            if b.life < 1.1 && b.y < floor && b.vy < 0 {
                if b.vy < -120 { burst(&debris, x: b.x, y: floor - b.r * 0.5, n: 6, speed: 90) }
                b.y = floor
                b.vy = -b.vy * 0.3
                b.vx *= 0.9
            }
            if b.y < -30 { loose.swapAt(i, loose.count - 1); loose.removeLast(); continue }
            loose[i] = b
            i += 1
        }
        if var c = carrot {
            if !c.lying {
                c.vy -= 900 * dt
                c.y += c.vy * dt
                if c.y <= baseY + 1.5 * sizeScale { c.y = baseY + 1.5 * sizeScale; c.lying = true }
            } else {
                c.alpha -= dt * 0.25
            }
            carrot = c.alpha > 0 ? c : nil
        }
        return wantsThrow
    }

    // MARK: [1.3 snowmen] Wardrobe and snowball fights

    /// Scarf colours (top, bottom shade): classic red, pine green, mustard, teal, cornflower, plum.
    static let scarves: [(RGBA, RGBA)] = [
        ((0.85, 0.17, 0.22, 1), (0.70, 0.10, 0.16, 1)), ((0.18, 0.56, 0.33, 1), (0.11, 0.42, 0.24, 1)),
        ((0.95, 0.70, 0.18, 1), (0.82, 0.55, 0.10, 1)), ((0.10, 0.62, 0.64, 1), (0.06, 0.47, 0.50, 1)),
        ((0.30, 0.48, 0.88, 1), (0.20, 0.35, 0.72, 1)), ((0.58, 0.27, 0.62, 1), (0.44, 0.17, 0.48, 1)),
    ]

    static func randomOutfit() -> Outfit {
        let hats: [Hat] = [.none, .topHat, .topHat, .beanie, .beanie, .beanie, .bucket, .bucket]
        return Outfit(hat: hats.randomElement() ?? .none, scarf: Int.random(in: 0..<scarves.count))
    }

    /// The hat it wears now: a seasonal hat wins, then Santa hats (Christmas), then the wardrobe.
    var shownHat: Hat {
        if let h = seasonalHat { return h }
        if santaHat { return .santa }
        return outfits ? outfit.hat : .none
    }

    var scarfIndex: Int { outfits ? outfit.scarf : 0 }

    /// A snowman the user rolled and stacked (radii bottom → top). It puts on its clothes and then lives
    /// like the others, but is not rebuilt when it melts.
    static func built(radii r: (Float, Float, Float), x: Float, baseY: Float) -> Snowman {
        var s = Snowman()
        let unit = max(0.3, r.2 / radii.2)
        s.sizeScale = unit
        s.custom = (r.0 / unit, r.1 / unit, radii.2)
        s.userBuilt = true
        s.phase = .dressing
        s.t = 0
        s.levels = 3
        s.dress = 0
        s.anchorX = x
        s.baseY = baseY
        s.life = .random(in: 900...1500)   // the ones you built yourself stay 15–25 min
        s.nextThrow = 8
        s.nextWave = 2.5
        return s
    }

    private mutating func stepFight(dt: Float) {
        if duckDelay >= 0 {
            duckDelay -= dt
            if duckDelay < 0 { duckHold = 0.75 }
        }
        if duckHold > 0 { duckHold = max(0, duckHold - dt) }
        let goal: Float = duckHold > 0 && (phase == .standing || phase == .dressing) ? 1 : 0
        duck += (goal - duck) * min(1, dt * (goal > duck ? 22 : 7))
        if duck < 0.002 && goal == 0 { duck = 0 }
        if retort > 0 {
            retort -= dt
            if retort <= 0 { retort = 0; retortReady = true }
        }
        if var h = flyingHat {
            if !h.lying {
                h.vy -= 900 * dt
                h.x += h.vx * dt
                h.y += h.vy * dt
                h.angle += h.spin * dt
                if h.y <= h.rest && h.vy < 0 {
                    h.y = h.rest
                    if h.vy < -160 { h.vy = -h.vy * 0.3; h.vx *= 0.6; h.spin *= 0.5 } else { h.lying = true }
                }
            } else {
                // Settle at a slight tilt, lie a while, then fade.
                h.angle += (Float(0.35) * (h.angle >= 0 ? 1 : -1) - h.angle) * min(1, dt * 6)
                h.alpha -= dt * 0.28
            }
            flyingHat = h.alpha > 0 ? h : nil
        } else if hatIn < 1 {
            hatIn = min(1, hatIn + dt / 0.9)
        }
    }

    /// A snowball is on its way and arrives in `eta` seconds: sometimes it ducks just in time.
    mutating func incoming(eta: Float, chance: Float) {
        guard phase == .standing, !carried, duckDelay < 0, duckHold == 0, Float.random(in: 0...1) < chance else { return }
        duckDelay = max(0, eta - 0.2)
    }

    /// The thrower that should get a snowball back, once the reply timer runs out.
    mutating func takeRetort() -> Int? {
        guard retortReady else { return nil }
        retortReady = false
        return phase == .standing && !carried ? retortTarget : nil
    }

    mutating func scheduleRetort(at target: Int, chance: Float) {
        guard retort == 0, !retortReady, Float.random(in: 0...1) < chance else { return }
        retort = .random(in: 0.6...1.3)
        retortTarget = target
    }

    /// Hit by a snowball at `p`, coming from the left (`dirX` > 0) or the right: it wobbles, and the hat may fly.
    mutating func hitBySnowball(at p: SIMD2<Float>, dirX: Float, debris: inout [Debris], hatChance: Float = 0.45) {
        guard phase == .standing || phase == .dressing else { return }
        wobble = 1
        burst(&debris, x: p.x, y: p.y, n: 12, speed: 150)
        let hat = shownHat
        guard hat != .none, flyingHat == nil, hatIn >= 1, levels == 3, Float.random(in: 0...1) < hatChance,
              let h = ball(2) else { return }
        let s = sizeScale * scale
        flyingHat = FlyingHat(x: h.x, y: h.y + h.r * 0.55, vx: dirX * .random(in: 60...120), vy: .random(in: 230...320),
                              angle: 0, spin: dirX * -.random(in: 5...9), alpha: 1, r: h.r, s: s,
                              rest: baseY + 1, lying: false, hat: hat)
        hatIn = 0
    }

    private mutating func start() {
        phase = .rolling
        t = 0
        levels = 3
        scale = 1
        dress = 0
        hasCarrot = true
        hits = 0
        life = .random(in: 150...320)
        nextThrow = throwEvery * .random(in: 0.4...0.8)
        nextWave = .random(in: 3...6)
        outfit = Self.randomOutfit()          // [1.3 snowmen] new clothes for every new snowman
        keepsake = .random(in: 0..<5)         // [1.3 decor]
        hatIn = 1
    }

    private mutating func reset(next: Float) {
        if userBuilt { retired = true }       // [1.3 snowmen] a rolled snowman is not rebuilt
        phase = .absent
        duck = 0; duckDelay = -1; duckHold = 0; retort = 0; retortReady = false
        carried = false
        falling = false
        ghost = false
        t = 0
        nextBuild = next
        levels = 3
        scale = 1
        dress = 0
    }

    private mutating func dropCarrot() {
        guard hasCarrot, levels == 3 else { return }
        hasCarrot = false
        carrot = Carrot(x: anchorX + R(2) * 0.6, y: stackY(2), vy: 40, alpha: 1, lying: false)
    }

    private mutating func popTop(debris: inout [Debris], vx: Float) {
        guard levels > 0, let b = ball(levels - 1) else { return }
        if levels == 3 { dropCarrot() }
        loose.append(LooseBall(x: b.x, y: b.y, vx: vx, vy: 60, r: b.r, life: 0))
        burst(&debris, x: b.x, y: b.y, n: 8, speed: 110)
        levels -= 1
    }

    private func burst(_ debris: inout [Debris], x: Float, y: Float, n: Int, speed: Float) {
        for _ in 0..<n {
            let a = Float.random(in: 0.15...(.pi - 0.15))
            let v = Float.random(in: speed * 0.4...speed)
            debris.append(Debris(x: x, y: y, vx: cos(a) * v, vy: sin(a) * v, size: .random(in: 2...4.5), alpha: 1, lands: false))
        }
    }

    /// A click on the snowman. Returns true when it fights back (throws a snowball).
    mutating func hit(at p: SIMD2<Float>, debris: inout [Debris]) -> Bool {
        guard phase == .standing || phase == .dressing else { return false }
        hits += 1
        wobble = 1
        burst(&debris, x: p.x, y: p.y, n: 10, speed: 140)
        if hits % 3 == 0 {
            popTop(debris: &debris, vx: Bool.random() ? 80 : -80)
            if levels == 0 { reset(next: rebuildDelay * .random(in: 0.4...0.8)); return false }
        }
        return Bool.random()
    }

    /// Start over: build a fresh snowman right away (used for screenshots).
    mutating func restart() {
        reset(next: 0)
        loose = []
        carrot = nil
    }

    mutating func buildNow() {
        if phase == .absent { nextBuild = 0 }
    }

    mutating func dismantle(into debris: inout [Debris]) {
        for k in 0..<levels { if let b = ball(k) { burst(&debris, x: b.x, y: b.y, n: 8, speed: 100) } }
        reset(next: 12)
        loose = []
        carrot = nil
    }

    // MARK: Drawing

    func build(into out: inout [Vertex]) {
        let start = out.count
        buildBody(into: &out)
        if ghost && !carried {
            for i in start..<out.count { out[i].a *= 0.22 }
        }
    }

    private func buildBody(into out: inout [Vertex]) {
        let center: RGBA = (1, 1, 1, 1)
        let rim: RGBA = (0.78, 0.84, 0.94, 1)
        let dark: RGBA = (0.13, 0.13, 0.17, 1)
        let brown: RGBA = (0.38, 0.25, 0.14, 1)
        // Details shrink with the body while it melts, and the accessories drop away.
        let s = sizeScale * scale
        let fade: Float = phase == .melting ? max(0, 1 - t / 2.5) : 1
        let dress = self.dress * fade

        if phase != .absent {
            // Arms behind the body
            if dress > 0, levels >= 2, let m = ball(1) {
                let a = brown.3 * dress
                let col: RGBA = (brown.0, brown.1, brown.2, a)
                let left = (m.x - m.r * 0.85, m.y + 1 * s)
                let lTip = (left.0 - 14 * s, left.1 + 7 * s)
                Mesh.line(&out, left, lTip, width: 1.7 * s, color: col)
                Mesh.line(&out, (lTip.0 + 4 * s, lTip.1 - 2 * s), (lTip.0 + 1 * s, lTip.1 + 4 * s), width: 1.2 * s, color: col)
                let base: Float = 0.45
                let waveA = wave > 0 ? sin(wave * 11) * 0.55 + 0.5 : 0
                let ang = base + waveA + armThrow * 0.9
                let right = (m.x + m.r * 0.85, m.y + 1 * s)
                let rTip = (right.0 + cos(ang) * 15 * s, right.1 + sin(ang) * 15 * s)
                Mesh.line(&out, right, rTip, width: 1.7 * s, color: col)
                if sparkler && levels >= 3 { Self.sparkler(&out, hand: lTip, s: s, t: t, alpha: dress) }
                else if holdsKeepsake && levels >= 3 {               // [1.3 decor]
                    ChristmasDecor.keepsake(&out, kind: keepsake, hand: lTip, s: s, alpha: dress)
                }
            }
            for k in 0..<3 {
                guard let b = ball(k) else { continue }
                Mesh.circle(&out, cx: b.x, cy: b.y, r: b.r, center: center, rim: rim)
            }
            if dress > 0 {
                let a = dress
                if levels >= 2, let m = ball(1) {
                    // buttons
                    Mesh.disc(&out, cx: m.x, cy: m.y + 2.5 * s, r: 1.2 * s, color: (dark.0, dark.1, dark.2, a))
                    Mesh.disc(&out, cx: m.x, cy: m.y - 2.5 * s, r: 1.2 * s, color: (dark.0, dark.1, dark.2, a))
                }
                if levels >= 3, let h = ball(2), let m = ball(1) {
                    // scarf
                    let (sTop, sBot) = Self.scarves[scarfIndex]
                    let red: RGBA = (sTop.0, sTop.1, sTop.2, a)
                    let neckY = (h.y - h.r * 0.75 + m.y + m.r * 0.75) / 2
                    Mesh.rect(&out, x: m.x - m.r * 0.78, y: neckY - 1.8 * s, w: m.r * 1.56, h: 3.6 * s, top: red, bottom: (sBot.0, sBot.1, sBot.2, a))
                    let sway = sin(t * 2.2) * 1.2 * s
                    Mesh.line(&out, (m.x + m.r * 0.45, neckY), (m.x + m.r * 0.62 + sway, neckY - 9 * s), width: 3 * s, color: red)
                    // eyes and mouth
                    // Eyes: white with coal pupils that look at the cursor.
                    for ex in [h.x - 2.4 * s, h.x + 2.2 * s] {
                        let ey = h.y + 1.8 * s
                        Mesh.circle(&out, cx: ex, cy: ey, r: 1.45 * s, center: (1, 1, 1, a), rim: (0.85, 0.88, 0.95, a), segments: 10)
                        var px: Float = 0, py: Float = 0
                        if let m = lookAt {
                            let dx = m.x - ex, dy = m.y - ey
                            let d = max(1, (dx * dx + dy * dy).squareRoot())
                            px = dx / d * 0.55 * s
                            py = dy / d * 0.55 * s
                        }
                        Mesh.disc(&out, cx: ex + px, cy: ey + py, r: 0.85 * s, color: (dark.0, dark.1, dark.2, a))
                    }
                    for k in 0..<3 {
                        let sx = h.x - 2 * s + Float(k) * 2 * s
                        Mesh.disc(&out, cx: sx, cy: h.y - 3 * s + (k == 1 ? -0.6 * s : 0), r: 0.6 * s, color: (dark.0, dark.1, dark.2, a))
                    }
                    if hasCarrot {
                        let orange: RGBA = (0.98, 0.52, 0.12, a)
                        Mesh.tri(&out, (h.x + 0.5 * s, h.y + 0.8 * s), (h.x + 0.5 * s, h.y - 1.4 * s), (h.x + h.r + 6 * s, h.y - 0.6 * s), orange)
                    }
                    let hat = shownHat
                    if hat != .none && flyingHat == nil && hatIn > 0 {
                        // A new hat drops onto the head after one flew off (and while dressing).
                        let put = hatIn * min(1, dress * 1.6)
                        let drop = (1 - put) * (1 - put) * 22 * s
                        let tilt = sin(t * 32) * wobble * 0.12 + (hat == .party ? -0.16 : (hat == .bucket ? 0.1 : 0))
                        Self.drawHat(hat, &out, cx: h.x, top: h.y, r: h.r, s: s, scarf: scarfIndex, alpha: a * put,
                                     angle: tilt, lift: drop)
                    }
                }
            }
        }
        if let fh = flyingHat {
            Self.drawHat(fh.hat, &out, cx: fh.x, top: fh.y - fh.r * 0.55, r: fh.r, s: fh.s, scarf: scarfIndex,
                         alpha: min(1, fh.alpha), angle: fh.angle, lift: 0)
        }
        for b in loose { Mesh.circle(&out, cx: b.x, cy: b.y, r: b.r, center: center, rim: rim, segments: 20) }
        if let c = carrot {
            let orange: RGBA = (0.98, 0.52, 0.12, max(0, c.alpha))
            let s = sizeScale
            if c.lying {
                Mesh.tri(&out, (c.x - 1 * s, c.y + 1.2 * s), (c.x - 1 * s, c.y - 1.2 * s), (c.x + 8 * s, c.y), orange)
            } else {
                Mesh.tri(&out, (c.x - 1.2 * s, c.y + 1 * s), (c.x + 1.2 * s, c.y + 1 * s), (c.x, c.y - 8 * s), orange)
            }
        }
    }

    // MARK: [1.3 snowmen] Hats and the sparkler

    /// Draws `hat` on a head of radius `r` centred at (cx, top) – `top` is the head's centre, the hat sits on
    /// its crown – rotated by `angle` around the hat's base and raised by `lift`.
    static func drawHat(_ hat: Hat, _ out: inout [Vertex], cx: Float, top: Float, r: Float, s: Float, scarf: Int,
                        alpha a: Float, angle: Float, lift: Float) {
        guard hat != .none, a > 0.01 else { return }
        let start = out.count
        let (sc, sd) = scarves[scarf % scarves.count]
        let col: RGBA = (sc.0, sc.1, sc.2, a), colDark: RGBA = (sd.0, sd.1, sd.2, a)
        var base = top + lift
        switch hat {
        case .none:
            break
        case .topHat:
            base += r * 0.62
            let black: RGBA = (0.11, 0.11, 0.14, a), sheen: RGBA = (0.24, 0.24, 0.29, a)
            Mesh.rect(&out, x: cx - r * 0.66, y: base, w: r * 1.32, h: r * 1.12, top: sheen, bottom: black)
            Mesh.rect(&out, x: cx - r * 0.66, y: base + r * 0.1, w: r * 1.32, h: r * 0.24, top: col, bottom: colDark)
            Mesh.rect(&out, x: cx - r * 1.05, y: base - r * 0.08, w: r * 2.1, h: r * 0.2, top: sheen, bottom: black)
        case .beanie:
            base += r * 0.6
            Mesh.sector(&out, cx: cx, cy: base, r: r * 0.9, from: 0, to: .pi, center: col, rim: colDark, segments: 14)
            let cuffH = r * 0.34
            Mesh.rect(&out, x: cx - r * 0.98, y: base - cuffH * 0.35, w: r * 1.96, h: cuffH, top: colDark, bottom: colDark)
            let rib: RGBA = (sd.0 * 0.82, sd.1 * 0.82, sd.2 * 0.82, a)
            for k in 0..<7 {
                let x = cx - r * 0.87 + Float(k) * r * 0.29
                Mesh.line(&out, (x, base - cuffH * 0.32), (x, base + cuffH * 0.52), width: max(0.5, 0.45 * s), color: rib)
            }
            Mesh.circle(&out, cx: cx, cy: base + r * 1.0, r: r * 0.28, center: (0.98, 0.96, 0.9, a),
                        rim: (0.84, 0.82, 0.76, a), segments: 12)
        case .bucket:
            base += r * 0.56
            let hi: RGBA = (0.80, 0.83, 0.88, a), lo: RGBA = (0.52, 0.56, 0.62, a)
            let w0 = r * 0.84, w1 = r * 0.6, hgt = r * 1.0
            Mesh.v(&out, cx - w0, base, hi); Mesh.v(&out, cx + w0, base, lo); Mesh.v(&out, cx + w1, base + hgt, lo)
            Mesh.v(&out, cx - w0, base, hi); Mesh.v(&out, cx + w1, base + hgt, lo); Mesh.v(&out, cx - w1, base + hgt, hi)
            Mesh.rect(&out, x: cx - w0 - r * 0.06, y: base - r * 0.06, w: (w0 + r * 0.06) * 2, h: r * 0.16, top: lo, bottom: lo)
            let ribY = base + hgt * 0.55, ribW = w0 + (w1 - w0) * 0.55
            Mesh.line(&out, (cx - ribW, ribY), (cx + ribW, ribY), width: max(0.5, 0.5 * s), color: lo)
            Mesh.line(&out, (cx - w1 * 0.9, base + hgt), (cx + w1 * 0.9, base + hgt), width: max(0.6, 0.7 * s),
                      color: (0.62, 0.66, 0.72, a))
        case .santa:
            base += r * 0.5
            let red: RGBA = (0.86, 0.1, 0.15, a), white: RGBA = (1, 1, 1, a)
            let tip = (cx + r * 1.05, base + r * 1.25)
            Mesh.tri(&out, (cx - r * 0.85, base), (cx + r * 0.85, base), tip, red)
            Mesh.rect(&out, x: cx - r * 0.95, y: base - 1.3 * s, w: r * 1.9, h: 2.8 * s, top: white, bottom: white)
            Mesh.circle(&out, cx: tip.0, cy: tip.1, r: 1.9 * s, center: white, rim: (0.85, 0.88, 0.95, a), segments: 10)
        case .party:
            // Striped cone with a pompom on top.
            base += r * 0.5
            let half = r * 0.68, height = r * 1.9
            let gold: RGBA = (1, 0.84, 0.3, a)
            let bands = 5
            for k in 0..<bands {
                let u0 = Float(k) / Float(bands), u1 = Float(k + 1) / Float(bands)
                let c = k % 2 == 0 ? col : gold
                let y0 = base + height * u0, y1 = base + height * u1
                let l0 = cx - half * (1 - u0), r0 = cx + half * (1 - u0)
                let l1 = cx - half * (1 - u1), r1 = cx + half * (1 - u1)
                Mesh.v(&out, l0, y0, c); Mesh.v(&out, r0, y0, c); Mesh.v(&out, r1, y1, c)
                Mesh.v(&out, l0, y0, c); Mesh.v(&out, r1, y1, c); Mesh.v(&out, l1, y1, c)
            }
            Mesh.circle(&out, cx: cx, cy: base + height + r * 0.12, r: r * 0.26, center: (1, 0.95, 0.75, a), rim: gold,
                        segments: 12)
        }
        // Rotate the hat around the middle of its base.
        if angle != 0 {
            let c = cos(angle), sn = sin(angle)
            for i in start..<out.count {
                let dx = out[i].x - cx, dy = out[i].y - base
                out[i].x = cx + dx * c - dy * sn
                out[i].y = base + dx * sn + dy * c
            }
        }
    }

    /// A burning sparkler held in the hand: a thin stick with a flickering star of sparks at the top.
    static func sparkler(_ out: inout [Vertex], hand: (Float, Float), s: Float, t: Float, alpha a: Float) {
        guard a > 0.01 else { return }
        let bottom = (hand.0 + 1.5 * s, hand.1 - 4 * s)
        let tip = (hand.0 - 3.5 * s, hand.1 + 17 * s)
        Mesh.line(&out, bottom, tip, width: max(0.6, 0.8 * s), color: (0.42, 0.42, 0.46, a))
        Mesh.disc(&out, cx: tip.0, cy: tip.1, r: 2.4 * s, color: (1, 0.78, 0.35, a * 0.35))
        let rays = 9
        for k in 0..<rays {
            let ph = Float(k) * 2.39996
            let flick = 0.5 + 0.5 * sin(t * 37 + ph * 5.3) * sin(t * 23 + ph * 2.1)
            let ang = ph + sin(t * 13 + ph) * 0.3
            let len = (2.5 + 4.5 * flick) * s
            let end = (tip.0 + cos(ang) * len, tip.1 + sin(ang) * len)
            Mesh.line(&out, tip, end, width: max(0.45, 0.55 * s), color: (1, 0.9 + 0.1 * flick, 0.55 + 0.4 * flick, a))
            if flick > 0.72 {
                Mesh.disc(&out, cx: end.0 + cos(ang) * 1.6 * s, cy: end.1 + sin(ang) * 1.6 * s, r: 0.5 * s,
                          color: (1, 0.97, 0.8, a))
            }
        }
        Mesh.disc(&out, cx: tip.0, cy: tip.1, r: 1.1 * s, color: (1, 1, 0.92, a))
    }
}
