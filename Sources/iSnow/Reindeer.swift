import CoreGraphics
import Foundation
import Metal

/// A reindeer that visits in Christmas mode. It trots in from one edge along the snow at the bottom,
/// stops to nibble and sniff the snow, looks around, paws a little hollow into the drift, hops up onto
/// the Dock and off again – and if a snowman stands nearby it rears up and nibbles off its carrot nose.
/// It wears a red collar with a bell; now and then it is Rudolph, with a glowing red nose. It bolts
/// from the cursor and from snowballs. Then it leaves at the other edge.
@MainActor
struct Reindeer {
    enum Act { case trot, graze, look, paw, turn, reach, chew, air }
    typealias Floor = Skier.Floor

    /// The carrot it is after: where its tip is, where to stand and how to stretch up to it.
    struct Target { let id: Int; let tip: SIMD2<Float>; let standX: Float; let neck: Float; let pitch: Float; let hop: Float }

    private static let gravity: Float = 900
    private static let trotSpeed: Float = 40       // points per second at size 1
    private static let reachNeck: Float = 1.45

    var x: Float, y: Float                          // between the hooves, on the snow
    var dir: Float                                  // +1 trots to the right, −1 to the left
    let size: Float
    let rudolph: Bool
    private(set) var act: Act = .trot
    private(set) var target: Target?
    /// Set at the moment it bites the carrot off snowman `bit` (the simulation takes the nose and clears it).
    var bit: Int?
    private var tried: [Int] = []                   // snowmen it already went for
    private var eaten = 0
    private let appetite = Float.random(in: 0..<1) < 0.35 ? 2 : 1   // carrots it wants this visit
    private var actT: Float = 0, actLen: Float = 0
    private var vx: Float = 0, vy: Float = 0
    private var ph: Float = 0                       // gait phase
    private var hurry: Float = 0                    // seconds left of bolting
    private var nextStop: Float
    private var stops = 0
    private var squash: Float = 0
    private var headK: Float = 1                    // 1 profile ahead, 0 facing you, −1 looking back
    private var neck: Float = 0.95
    private var pitch: Float = 0                    // rearing up on the hind legs
    private var hopY: Float = 0
    private var carrot: Float = 0                   // the carrot in its mouth (1 whole … 0 eaten)
    private var bitten = false
    private var flipped = false
    private var ear: Float = 0, tail: Float = 0
    private var bell: Float = 0, bellV: Float = 0
    private var dug = -1                            // paw stroke that already dug
    private var ghost = false
    private var alpha: Float = 1
    private var age: Float = 0
    private let seed = Float.random(in: 0...100)

    init(x: Float, y: Float, dir: Float, size: Float, rudolph: Bool) {
        self.x = x; self.y = y; self.dir = dir; self.size = size; self.rudolph = rudolph
        nextStop = Float.random(in: 3...6)
    }

    /// Something visible is animating (full frame rate). Grazing, chewing or just looking around is not.
    var isMoving: Bool {
        if act == .graze || act == .look || act == .chew {
            return abs(headK - lookTarget) > 0.05 || abs(neck - neckTarget) > 0.03 || squash > 0.02 || pitch > 0.01
        }
        return true
    }

    /// Where the middle of the body is (for the cursor and snowballs).
    var center: SIMD2<Float> { SIMD2(x + dir * 2 * size, y + 18 * size + hopY) }

    /// Can it go for a snowman's carrot now?
    var canAim: Bool { act == .trot && hurry <= 0 && target == nil && carrot <= 0 && eaten < appetite }

    func tried(_ id: Int) -> Bool { tried.contains(id) }

    private var lookTarget: Float {
        switch act {
        case .look:
            let u = actT / max(0.1, actLen)
            return u < 0.15 ? 1 : u < 0.4 ? 0 : u < 0.68 ? -1 : u < 0.86 ? 0 : 1
        case .turn: return 0
        case .chew: return actT > 0.35 && actT < actLen - 0.5 ? 0 : 1
        default: return 1
        }
    }

    private var neckTarget: Float {
        switch act {
        case .trot: return hurry > 0 ? 0.62 : 0.95
        case .graze: return -0.95
        case .paw: return 0.42
        case .look: return 1.22
        case .reach: return actT < 1.55 ? (target?.neck ?? Self.reachNeck) : 1.0
        case .chew: return 1.08
        case .turn: return 1.05
        case .air: return 0.8
        }
    }

    // MARK: Reactions

    /// The cursor or a snowball: a startled leap, then it gallops away from `fromX`.
    mutating func bolt(from fromX: Float) {
        guard hurry <= 0 else { return }
        hurry = 2.8
        dir = fromX < center.x ? 1 : -1
        target = nil
        squash = 0.5
        ear = 1; tail = 1
        if act != .air {
            set(.air)
            vy = 190; vx = dir * 110
            hopY = 0
        }
    }

    /// Go and nibble the carrot of snowman `id` whose tip is at `tip`. `floor` finds where it would stand.
    /// False if the carrot is out of reach (or it can't face it from where it is).
    mutating func aim(snowman id: Int, tip: SIMD2<Float>, ground: Float, floor: Floor) -> Bool {
        guard canAim, !tried.contains(id) else { return false }
        tried.append(id)
        let need = (tip.y - ground) / size                       // nose height wanted (local points)
        // Stretch the neck first, then rear up, then hop for the rest.
        var pick: (neck: Float, pitch: Float, nose: (Float, Float)) = (Self.reachNeck, 0, ReindeerArt.nose(neck: Self.reachNeck, pitch: 0))
        var found = false
        var n: Float = -0.2
        while n <= Self.reachNeck + 0.001 && !found {
            let p = ReindeerArt.nose(neck: n, pitch: 0)
            if p.1 >= need { pick = (n, 0, p); found = true }
            n += 0.05
        }
        var pt: Float = 0.04
        while pt <= 0.56 && !found {
            let p = ReindeerArt.nose(neck: Self.reachNeck, pitch: pt)
            pick = (Self.reachNeck, pt, p)
            if p.1 >= need { found = true }
            pt += 0.04
        }
        let hop = max(0, need - pick.nose.1) * size
        guard hop < 24 * size else { return false }
        // The carrot points to the right: it stands right of the snowman, facing left.
        let standX = tip.x + (pick.nose.0 - 0.6) * size
        guard abs(floor(standX, ground + 14 * size).top - ground) < 5 * size else { return false }
        if dir < 0 { guard x > standX + 6 else { return false } } else { guard x < standX + 4 else { return false } }
        target = Target(id: id, tip: tip, standX: standX, neck: pick.neck, pitch: pick.pitch, hop: hop)
        return true
    }

    /// The snowman moved, lost its nose or went away before the bite.
    mutating func dropTarget() {
        guard target != nil, !bitten else { return }
        target = nil
        if act == .reach { set(.trot) }
    }

    private mutating func set(_ a: Act, _ len: Float = 0) {
        act = a; actT = 0; actLen = len
    }

    // MARK: Step

    /// Advances the reindeer. `floor(x, y)` is the top of the snow on the highest surface below a point.
    /// Returns false when it has left the screen.
    mutating func step(dt rawDt: Float, width W: Float, mouse: SIMD2<Float>?, paused: Bool,
                       debris: inout [Debris], floor: Floor) -> Bool {
        let dt = min(rawDt, 1.0 / 20)
        actT += dt
        age += dt
        squash = max(0, squash - dt * 3)
        hurry = max(0, hurry - dt)
        ear = max(0, ear - dt * 2.5)
        tail = max(0, tail - dt * 2)
        if !paused && Float.random(in: 0..<1) < dt * 0.35 { ear = 1 }
        if !paused && Float.random(in: 0..<1) < dt * 0.25 { tail = 1 }
        headK += (lookTarget - headK) * min(1, dt * 8)
        if carrot > 0 && act != .reach { carrot = max(0, carrot - dt * (act == .chew ? 0.42 : 0.3)) }

        // The cursor comes close: bolt.
        if let m = mouse, hurry <= 0, act != .air {
            let c = center
            if abs(m.x - c.x) < 36 * size + 12 && abs(m.y - c.y) < 30 * size + 12 { bolt(from: m.x) }
        }

        switch act {
        case .trot: trot(dt, width: W, paused: paused, debris: &debris, floor: floor)
        case .graze:
            settle(dt, floor: floor)
            if neck < -0.6 && !ghost && Float.random(in: 0..<1) < dt * 1.6 { sniff(&debris) }
            if actT > actLen || paused {
                if !paused && Float.random(in: 0..<1) < 0.45 { set(.look, Float.random(in: 2...2.8)) } else { set(.trot) }
            }
        case .look:
            settle(dt, floor: floor)
            if actT > actLen || paused { set(.trot) }
        case .paw:
            settle(dt, floor: floor)
            let stroke = Int(actT / 0.5), u = actT / 0.5 - Float(stroke)
            if u > 0.5 && stroke != dug && stroke < 3 { dug = stroke; dig(&debris, floor: floor) }
            if actT > 1.5 { set(.graze, Float.random(in: 2...3)) }
        case .turn:
            settle(dt, floor: floor)
            if !flipped && actT > actLen * 0.5 { dir = -dir; flipped = true }
            if actT > actLen { set(.trot) }
        case .reach: reach(dt, floor: floor)
        case .chew:
            settle(dt, floor: floor)
            if actT > actLen {
                // A happy little skip, then off it goes.
                set(.air); vy = 170; vx = dir * 45; squash = 0.4
            }
        case .air: fly(dt, debris: &debris, floor: floor)
        }

        // The pose eases towards the act.
        neck += (neckTarget - neck) * min(1, dt * 6)
        let pitchTarget: Float = act == .reach && actT < 1.55 ? (target?.pitch ?? 0) : 0
        pitch += (pitchTarget - pitch) * min(1, dt * 5)
        // The bell swings with the steps.
        bellV += (-bell * 80 - bellV * 3.5) * dt
        if act == .trot || act == .air { bellV += cos(ph * 2) * (hurry > 0 ? 60 : 30) * dt }
        bell += bellV * dt

        // Lost somewhere (stuck hopping back and forth): fade out.
        if age > 170 { alpha = max(0, alpha - dt / 0.6); if alpha <= 0 { return false } }
        return x > -50 && x < W + 50 && y > -40
    }

    /// An auto-hiding Dock came up right under it: it is bucked up onto the Dock.
    mutating func liftedByDock(to top: Float) {
        y = top
        set(.air)
        vx = dir * 40; vy = 170
        squash = 0.5
    }

    private mutating func settle(_ dt: Float, floor: Floor) {
        let g = floor(x, y + 10 * size)
        y += (g.top - y) * min(1, dt * 14)
    }

    private mutating func trot(_ dt: Float, width W: Float, paused: Bool, debris: inout [Debris], floor: Floor) {
        var spd = Self.trotSpeed * (0.8 + 0.2 * size)
        if hurry > 0 { spd *= 2.7 } else if paused { spd *= 1.6 }
        if let tg = target {
            // Slow down for the last steps to the snowman.
            let gap = abs(tg.standX - x)
            if dir < 0 && gap < 30 * size { spd *= max(0.35, gap / (30 * size)) }
        }
        let rate: Float = hurry > 0 ? 2.5 : 1.9
        ph += dt * 2 * .pi * rate / (0.8 + 0.2 * size)
        let nx = x + dir * spd * dt

        // Something higher ahead within jumping height (the Dock, a low window): leap up onto it.
        let ob = floor(nx + dir * 13 * size, y + 130)
        let rise = ob.top - y
        if rise > 8 * size && rise < 130 {
            set(.air)
            vy = (2 * Self.gravity * (rise + 12 * size)).squareRoot()
            vx = dir * max(80, spd * 1.3)
            squash = 0.5
            return
        }
        let g = floor(nx, y + 10 * size)
        if g.top < y - 8 * size {
            // An edge (the end of the Dock, a window's drift): jump down.
            set(.air)
            vx = dir * max(90, spd * 1.3)
            vy = 120
            return
        }
        x = nx
        y += (g.top - y) * min(1, dt * 18)
        updateGhost(g.pile)

        if let tg = target {
            let past = (x - tg.standX) * dir                    // > 0: at or beyond the spot
            if past >= 0 {
                if dir < 0 { x = tg.standX; set(.reach); bitten = false }
                else if past > 16 * size { flipped = false; set(.turn, 0.6) }
            }
            return
        }
        guard !paused, hurry <= 0 else { return }
        // Now and then: stop to nibble the snow, look around or paw at the drift.
        let inside = x > 70 && x < W - 70
        nextStop -= dt
        if nextStop <= 0 && inside && stops < 4 {
            stops += 1
            nextStop = Float.random(in: 5...10)
            let r = Float.random(in: 0..<1)
            if r < 0.42 { set(.graze, Float.random(in: 2.2...3.6)) }
            else if r < 0.72 { set(.look, Float.random(in: 2...2.8)) }
            else { dug = -1; set(.paw, 1.5) }
        }
    }

    /// Rears up to the snowman's nose, bites the carrot off and drops back down chewing.
    private mutating func reach(_ dt: Float, floor: Floor) {
        settle(dt, floor: floor)
        guard let tg = target else { set(.trot); return }
        if tg.hop > 0 {
            let u = (actT - 0.75) / 0.45
            hopY = u > 0 && u < 1 ? tg.hop * sin(u * .pi) : 0
        }
        if !bitten && actT > 0.97 {
            bitten = true
            bit = tg.id
            eaten += 1
            carrot = 1
            ear = 1
            squash = 0.25
        }
        if actT > 2.1 {
            target = nil
            hopY = 0
            set(.chew, 2.6)
        }
    }

    private mutating func fly(_ dt: Float, debris: inout [Debris], floor: Floor) {
        let oy = y
        vy -= Self.gravity * dt
        x += vx * dt
        y += vy * dt
        ph += dt * 2 * .pi * 1.6
        guard vy < 0 else { return }
        let f = floor(x, oy)
        guard y <= f.top else { return }
        y = f.top
        set(.trot)
        squash = 0.8
        puff(&debris, 7)
    }

    private mutating func updateGhost(_ p: Pile?) {
        ghost = false
        guard let p, p.kind == .ground else { return }
        let b = Int((x - Float(p.rect.minX)) / Simulation.binW)
        if b >= 0 && b < p.visible.count { ghost = !p.visible[b] }
    }

    /// One stroke of the front hoof: scrape a small hollow into the drift and throw the snow back.
    private mutating func dig(_ debris: inout [Debris], floor: Floor) {
        let hx = x + dir * 7.5 * size
        let g = floor(hx, y + 10 * size)
        if let p = g.pile {
            let b = Int((hx - Float(p.rect.minX)) / Simulation.binW)
            for k in (b - 1)...(b + 1) where k >= 0 && k < p.bins.count && p.visible[k] && p.bins[k] > 2.5 {
                p.bins[k] = max(2, p.bins[k] - (k == b ? 2.2 : 1.2) * size)
                p.dirty = true
            }
        }
        guard !ghost else { return }
        for _ in 0..<7 where debris.count < 9000 {
            debris.append(Debris(x: hx + Float.random(in: -2...2) * size, y: y + 1.5,
                                 vx: -dir * Float.random(in: 40...120), vy: Float.random(in: 50...140),
                                 size: Float.random(in: 1.2...2.4), alpha: 0.9, lands: false, fade: 1.4))
        }
    }

    /// A little puff of snow at the nose while nibbling.
    private func sniff(_ debris: inout [Debris]) {
        let nx = x + dir * 13.5 * size
        for _ in 0..<2 where debris.count < 9000 {
            debris.append(Debris(x: nx + Float.random(in: -2...2), y: y + 1.5,
                                 vx: Float.random(in: -25...25), vy: Float.random(in: 20...55),
                                 size: Float.random(in: 0.9...1.8), alpha: 0.8, lands: false, fade: 1.8))
        }
    }

    private func puff(_ debris: inout [Debris], _ n: Int) {
        guard !ghost else { return }
        for _ in 0..<n where debris.count < 9000 {
            debris.append(Debris(x: x + Float.random(in: -12...12) * size, y: y + 1,
                                 vx: Float.random(in: -50...50), vy: Float.random(in: 25...90),
                                 size: Float.random(in: 1.2...2.4), alpha: 0.85, lands: false, fade: 1.5))
        }
    }

    // MARK: Drawing

    func build(into out: inout [Vertex], t: Float) {
        guard alpha > 0.01 else { return }
        var pose = ReindeerArt.Pose()
        var bob: Float = 0
        switch act {
        case .trot:
            if hurry > 0 {
                pose.hooves = ReindeerArt.gallop(ph)
                bob = 1.2 + sin(ph) * 1.4
            } else {
                pose.hooves = ReindeerArt.trot(ph, amp: 3.4, lift: 3.0)
                bob = abs(sin(ph)) * 0.7
            }
        case .air:
            pose.hooves = ReindeerArt.gallop(ph)
        case .paw:
            let u = actT / 0.5 - Float(Int(actT / 0.5))
            let hip = ReindeerArt.frontHip
            // Lift forward, then drag back along the snow.
            let fx: Float = u < 0.35 ? hip.0 + 0.5 + u / 0.35 * 4 : u < 0.75 ? hip.0 + 4.5 - (u - 0.35) / 0.4 * 8 : hip.0 - 3.5 + (u - 0.75) / 0.25 * 4
            let fy: Float = u < 0.35 ? sin(u / 0.35 * .pi * 0.5) * 4 : u < 0.75 ? max(0, 4 - (u - 0.35) * 40) : sin((u - 0.75) / 0.25 * .pi) * 1.5
            pose.hooves[0] = (fx, fy)
        case .reach:
            // Rearing: the front legs fold up.
            let r = min(1, pitch / 0.3)
            for i in [0, 2] {
                let hip = ReindeerArt.hip(i), st = pose.hooves[i]
                let tuck = (hip.0 + 2.2, hip.1 - 8.5)
                pose.hooves[i] = (st.0 + (tuck.0 - st.0) * r, st.1 + (tuck.1 - st.1) * r)
            }
        default: break
        }
        pose.neck = neck + (act == .trot && hurry <= 0 ? sin(ph * 2) * 0.04 : 0)
        pose.headK = headK
        let chewing = act == .chew || act == .graze || (act == .reach && bitten)
        pose.chew = chewing ? 0.5 + 0.5 * sin(t * (act == .graze ? 9 : 12) + seed) : 0
        pose.ear = ear
        pose.tail = tail
        pose.carrot = carrot
        pose.bell = bell
        pose.rudolph = rudolph
        pose.glow = 0.85 + 0.15 * sin(t * 4 + seed)
        pose.blink = (t + seed).truncatingRemainder(dividingBy: 3.9) < 0.13
        var f = ReindeerArt.Frame(x: x, y: y + hopY, dir: dir, s: size)
        f.pitch = pitch
        f.bob = bob
        f.squash = squash
        if act == .turn { f.xScale = max(0.22, abs(cos(min(1, actT / max(0.1, actLen)) * .pi))) }
        f.alpha = alpha * (ghost ? 0.3 : 1)
        ReindeerArt.draw(&out, f, pose, t: t)
    }
}

/// How a reindeer is drawn – the visitor and Santa's team. Side view in local points (x forward, y up
/// from the hooves), mapped onto the screen by `Frame` (position, facing, scale, rearing).
enum ReindeerArt {
    struct Pose {
        /// Hooves in local points: near front, near hind, far front, far hind.
        var hooves: [(Float, Float)] = ReindeerArt.standing
        var neck: Float = 0.95          // neck angle above the horizontal (radians)
        var headK: Float = 1            // 1 profile ahead, 0 facing you, −1 looking back
        var chew: Float = 0             // 0…1 the jaw works
        var ear: Float = 0              // 0…1 ear flick
        var tail: Float = 0             // 0…1 tail flick
        var carrot: Float = 0           // a carrot in its mouth (0…1 of it left)
        var bell: Float = 0             // swing of the collar bell (radians)
        var rudolph = false             // the glowing red nose
        var glow: Float = 1
        var harness = false             // Santa's team: a harness strap with bells
        var blink = false
    }

    struct Frame {
        var x, y, dir, s: Float
        var pitch: Float = 0            // rears up around the hind hooves
        var xScale: Float = 1           // squeezed while turning round
        var squash: Float = 0
        var bob: Float = 0
        var shade: Float = 0            // the far reindeer of a pair is a little darker
        var alpha: Float = 1
    }

    static let frontHip: (Float, Float) = (7, 13)
    static let hindHip: (Float, Float) = (-8.5, 13.5)
    static let farDX: Float = -1.4
    static let standing: [(Float, Float)] = [(7.5, 0), (-8.9, 0), (6.1, 0), (-10.3, 0)]
    private static let neckBase: (Float, Float) = (6.4, 17.8)
    private static let neckLen: Float = 9
    private static let pivot: (Float, Float) = (-8.5, 0)

    static func hip(_ i: Int) -> (Float, Float) {
        let h = i % 2 == 0 ? frontHip : hindHip
        return i >= 2 ? (h.0 + farDX, h.1) : h
    }

    /// A trot: diagonal legs move together.
    static func trot(_ ph: Float, amp: Float, lift: Float) -> [(Float, Float)] {
        let offs: [Float] = [0, .pi, .pi, 0]
        return (0..<4).map { i in
            let h = hip(i), q = ph + offs[i]
            return (h.0 + (i % 2 == 0 ? 0.5 : -0.4) + amp * sin(q), lift * max(0, cos(q)))
        }
    }

    /// A flying gallop: front legs reach forward and fold, hind legs stretch back and tuck under.
    static func gallop(_ ph: Float) -> [(Float, Float)] {
        (0..<4).map { i in
            let h = hip(i)
            let e = 0.5 + 0.5 * sin(ph - (i >= 2 ? 0.5 : 0))
            if i % 2 == 0 { return (h.0 - 1.4 + 8.4 * e, h.1 - 6.6 - 4.2 * e) }
            return (h.0 + 3 - 11.5 * e, h.1 - 10.4 + 0.6 * e)
        }
    }

    /// Where the head sits on the neck and which way it points.
    private static func head(neck n: Float) -> (Float, Float, Float) {
        (neckBase.0 + cos(n) * neckLen, neckBase.1 + sin(n) * neckLen, n * 0.55 - 0.78)
    }

    /// The tip of the nose in local points for a neck angle and rearing (for reaching a snowman's carrot).
    static func nose(neck n: Float, pitch p: Float) -> (Float, Float) {
        let (hx, hy, a) = head(neck: n)
        let lx = hx + cos(a) * 7.9 + sin(a) * 0.2, ly = hy + sin(a) * 7.9 - cos(a) * 0.2
        let dx = lx - pivot.0, dy = ly - pivot.1
        return (pivot.0 + dx * cos(p) - dy * sin(p), pivot.1 + dx * sin(p) + dy * cos(p))
    }

    /// Two-bone leg: the knee between hip and hoof (`bend` +1 forward, −1 back).
    private static func knee(_ h: (Float, Float), _ f: (Float, Float), _ l1: Float, _ l2: Float, bend: Float) -> (Float, Float) {
        let dx = f.0 - h.0, dy = f.1 - h.1
        let len = max(0.01, (dx * dx + dy * dy).squareRoot())
        let d = min(l1 + l2 - 0.01, len)
        let ux = dx / len, uy = dy / len
        let a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
        let k = max(0, l1 * l1 - a * a).squareRoot() * bend
        return (h.0 + ux * a - uy * k, h.1 + uy * a + ux * k)
    }

    static func draw(_ out: inout [Vertex], _ f: Frame, _ pose: Pose, t: Float) {
        let start = out.count
        let s = f.s
        let cp = cos(f.pitch), sp = sin(f.pitch)
        let sq = 1 - 0.2 * f.squash, sw = 1 + 0.1 * f.squash
        let (nx, ny, ha) = head(neck: pose.neck)
        let hc = cos(ha), hs = sin(ha)
        let profile = abs(pose.headK) >= 0.45
        let m: Float = pose.headK < -0.45 ? -1 : 1
        // Antlers turn with the head only partly, so they stay upright when it nods.
        let ac = cos(ha * 0.4 + 0.06), asn = sin(ha * 0.4 + 0.06)
        var mode = 0                                            // 0 body, 1 head in profile, 2 face, 3 antlers
        func P(_ u: Float, _ v: Float) -> (Float, Float) {
            var lx = u, ly = v
            if mode == 1 { lx = nx + m * (hc * u - hs * v); ly = ny + hs * u + hc * v }
            else if mode == 2 { lx = nx + 0.6 + u; ly = ny + 1.6 + v }
            else if mode == 3 { lx = nx + m * (ac * u - asn * v); ly = ny + asn * u + ac * v }
            let dx = lx - pivot.0, dy = ly - pivot.1
            let rx = pivot.0 + dx * cp - dy * sp, ry = pivot.1 + dx * sp + dy * cp
            return (f.x + rx * sw * f.xScale * f.dir * s, f.y + (ry * sq + f.bob) * s)
        }
        func C(_ c: RGBA) -> RGBA {
            f.shade > 0 ? Mesh.mix(c, (0.08, 0.07, 0.12, c.3), f.shade * 0.5) : c
        }
        func line(_ a: (Float, Float), _ b: (Float, Float), _ w: Float, _ c: RGBA) {
            Mesh.line(&out, P(a.0, a.1), P(b.0, b.1), width: max(0.5, w * s), color: C(c))
        }
        func tri(_ a: (Float, Float), _ b: (Float, Float), _ c: (Float, Float), _ col: RGBA) {
            Mesh.tri(&out, P(a.0, a.1), P(b.0, b.1), P(c.0, c.1), C(col))
        }
        func blob(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, _ c: RGBA, _ rim: RGBA, n: Int = 16) {
            let o = P(cx - rx * 0.2, cy + ry * 0.25)
            let cc = C(c), rr = C(rim)
            var prev = P(cx + rx, cy)
            for i in 1...n {
                let a = Float(i) / Float(n) * 2 * .pi
                let q = P(cx + cos(a) * rx, cy + sin(a) * ry)
                Mesh.v(&out, o.0, o.1, cc); Mesh.v(&out, prev.0, prev.1, rr); Mesh.v(&out, q.0, q.1, rr)
                prev = q
            }
        }
        func dot(_ cx: Float, _ cy: Float, _ r: Float, _ c: RGBA) { blob(cx, cy, r, r, c, c, n: 10) }

        let coat: RGBA = (0.6, 0.42, 0.28, 1), coatRim: RGBA = (0.35, 0.23, 0.14, 1)
        let cream: RGBA = (0.93, 0.88, 0.78, 1), creamRim: RGBA = (0.78, 0.7, 0.58, 1)
        let legC: RGBA = (0.42, 0.29, 0.19, 1), legFar: RGBA = (0.3, 0.2, 0.13, 1)
        let hoofC: RGBA = (0.13, 0.1, 0.09, 1)
        let antlerC: RGBA = (0.87, 0.76, 0.58, 1), antlerFar: RGBA = (0.68, 0.57, 0.42, 1)
        let muzzle = Mesh.mix(coat, cream, 0.4)
        let dark: RGBA = (0.1, 0.07, 0.07, 1)

        func leg(_ i: Int) {
            let front = i % 2 == 0, far = i >= 2
            let h = hip(i), hoof = pose.hooves[i]
            let l1: Float = front ? 6.2 : 6.8, l2: Float = front ? 7.2 : 7.4
            let k = knee(h, hoof, l1, l2, bend: front ? 1 : -1)
            let c = far ? legFar : legC
            line(h, k, front ? 2.6 : 3.1, c)
            dot(k.0, k.1, front ? 1.15 : 1.3, c)
            let foot = (hoof.0, hoof.1 + 0.9)
            line(k, foot, 1.5, c)
            dot(hoof.0 + 0.2, hoof.1 + 0.75, 0.95, hoofC)
        }
        /// One antler in the head frame, `o` shifts it (the far one sits a little behind).
        func antler(_ o: (Float, Float), _ c: RGBA) {
            let back = mode
            mode = 3
            func L(_ a: (Float, Float), _ b: (Float, Float), _ w: Float) {
                line((a.0 + o.0, a.1 + o.1), (b.0 + o.0, b.1 + o.1), w, c)
                dot(b.0 + o.0, b.1 + o.1, w * 0.5, c)
            }
            // A long beam sweeping back and up, curling forward at the top, tines off its upper half
            // and a flattened brow tine reaching forward over the face.
            let b: [(Float, Float)] = [(0.5, 2.4), (-1.9, 5.4), (-3.2, 8.8), (-3.1, 12.0), (-1.7, 14.6), (0.4, 15.8)]
            let w: [Float] = [1.35, 1.25, 1.15, 1.0, 0.9]
            for k in 1..<b.count { L(b[k - 1], b[k], w[k - 1]) }
            L(b[2], (-0.9, 10.9), 0.85)
            L(b[3], (-5.3, 13.9), 0.8)
            L(b[4], (-2.5, 17.0), 0.75)
            L(b[5], (1.9, 16.9), 0.7)
            L((0.2, 3.3), (2.6, 5.4), 0.85)
            Mesh.tri(&out, P(1.8 + o.0, 4.4 + o.1), P(3.7 + o.0, 4.9 + o.1), P(3.0 + o.0, 6.5 + o.1), C(c))
            mode = back
        }

        // Far legs, far antler and ear first.
        leg(2); leg(3)
        if profile {
            mode = 1
            antler((-1.0, 0.5), antlerFar)
            tri((-0.6, 1.8), (0.4, 2.7), (-3.6, 3.9 + pose.ear * 1.4), coatRim)
            mode = 0
        }
        // Tail: a white tuft that flicks up.
        let tf = pose.tail
        blob(-12.6 - tf * 0.4, 18.6 + tf * 1.4, 1.7, 2.4, cream, creamRim, n: 10)
        // Body: rump, barrel and a deep chest; pale belly and rump patch.
        let seam = Mesh.mix(coat, coatRim, 0.45)                       // softer rims where parts overlap
        blob(-7.4, 16.6, 5.4, 5.4, coat, coatRim)
        blob(-0.8, 16.2, 10.6, 5.4, coat, coatRim, n: 20)
        blob(6.0, 16.9, 5.2, 5.9, coat, seam)
        blob(-0.6, 15.6, 7.6, 3.2, Mesh.mix(coat, cream, 0.12), coat, n: 16)   // sheen on the flank
        blob(-0.8, 12.4, 7.4, 1.6, Mesh.mix(cream, coat, 0.2), Mesh.mix(cream, coat, 0.75), n: 14)
        blob(-10.6, 16.9, 2.3, 3.5, cream, Mesh.mix(creamRim, coat, 0.35), n: 12)
        // Neck: darker on top, a pale shaggy ruff at the throat.
        let ncos = cos(pose.neck), nsin = sin(pose.neck)
        let px = -nsin, py = ncos                                       // across the neck, up/back side
        let wb: Float = 6.6, wt: Float = 4.3
        let b = neckBase, top = (nx, ny)
        let q0 = P(b.0 + px * wb / 2, b.1 + py * wb / 2), q1 = P(b.0 - px * wb / 2, b.1 - py * wb / 2)
        let q2 = P(top.0 - px * wt / 2, top.1 - py * wt / 2), q3 = P(top.0 + px * wt / 2, top.1 + py * wt / 2)
        let nTop = C(coat), nUnder = C(Mesh.mix(coat, cream, 0.55))
        Mesh.v(&out, q0.0, q0.1, nTop); Mesh.v(&out, q1.0, q1.1, nUnder); Mesh.v(&out, q2.0, q2.1, nUnder)
        Mesh.v(&out, q0.0, q0.1, nTop); Mesh.v(&out, q2.0, q2.1, nUnder); Mesh.v(&out, q3.0, q3.1, nTop)
        let throat0 = (b.0 - px * wb / 2, b.1 - py * wb / 2)
        let throat1 = (b.0 + ncos * 5.5 - px * 2.6, b.1 + nsin * 5.5 - py * 2.6)
        let ruffTip = ((throat0.0 + throat1.0) / 2 - px * 2.6 - 0.4, (throat0.1 + throat1.1) / 2 - py * 2.6 - 0.8)
        tri(throat0, throat1, ruffTip, cream)
        tri((throat0.0 + 0.6, throat0.1), ((throat0.0 + throat1.0) / 2, (throat0.1 + throat1.1) / 2),
            (throat0.0 - px * 1.6 + 1.2, throat0.1 - py * 1.6 - 1.4), creamRim)
        dot(nx, ny, 2.3, coat)
        // Collar with a bell (or Santa's harness).
        let cu: Float = 0.3
        let cc = (b.0 + ncos * neckLen * cu, b.1 + nsin * neckLen * cu)
        let cw = (wb + (wt - wb) * cu) / 2 + 0.25
        let red: RGBA = (0.8, 0.09, 0.12, 1), gold: RGBA = (0.98, 0.78, 0.25, 1)
        line((cc.0 + px * cw, cc.1 + py * cw), (cc.0 - px * cw, cc.1 - py * cw), 1.5, red)
        let bellTop = (cc.0 - px * cw, cc.1 - py * cw)
        let bc = (bellTop.0 + sin(pose.bell) * 1.5, bellTop.1 - cos(pose.bell) * 1.5)
        dot(bc.0, bc.1, 1.3, gold)
        dot(bc.0 - 0.35, bc.1 + 0.4, 0.45, (1, 0.96, 0.75, 1))
        line((bc.0 - 0.7, bc.1 - 0.5), (bc.0 + 0.7, bc.1 - 0.5), 0.35, (0.55, 0.38, 0.1, 1))
        if pose.harness {
            // A girth band behind the front legs with a gold buckle and a bell.
            line((-0.6, 10.9), (0.2, 21.5), 2.1, red)
            dot(-0.2, 15.6, 0.75, gold); dot(0.05, 18.6, 0.75, gold)
            dot(-0.5, 11.6, 0.9, gold)
        }
        // Near legs over the body.
        leg(1); leg(0)

        // Head.
        if profile {
            mode = 1
            blob(1.4, 0.5, 3.4, 3.0, coat, coatRim, n: 14)
            blob(5.2, -0.5, 3.0, 1.95, muzzle, coatRim, n: 14)
            blob(4.3, -1.7 - pose.chew * 0.7, 2.3, 0.9, coatRim, coatRim, n: 10)
            if pose.carrot > 0.01 {
                let c = pose.carrot
                let orange: RGBA = (0.98, 0.52, 0.12, 1)
                tri((4.6, -1.0), (4.8, -2.4), (5.2 + 6.8 * c, -2.6 - 2.6 * c), orange)
            }
            // Nose: dark, or Rudolph's glowing red one.
            if pose.rudolph {
                let np = P(7.9, -0.2)
                let g = pose.glow
                Mesh.circle(&out, cx: np.0, cy: np.1, r: 8.5 * s * g, center: (1, 0.15, 0.12, 0.24),
                            rim: (1, 0.15, 0.12, 0), segments: 14)
                Mesh.circle(&out, cx: np.0, cy: np.1, r: 3.6 * s * g, center: (1, 0.32, 0.26, 0.7),
                            rim: (1, 0.15, 0.15, 0), segments: 12)
                dot(7.9, -0.2, 1.25, (1, 0.2, 0.18, 1))
                dot(7.6, 0.25, 0.4, (1, 0.8, 0.75, 1))
            } else {
                dot(7.9, -0.2, 1.05, dark)
                dot(7.65, 0.15, 0.3, (0.6, 0.55, 0.55, 1))
            }
            // Eye.
            if pose.blink {
                line((1.8, 1.3), (3.2, 1.2), 0.45, dark)
            } else {
                dot(2.5, 1.3, 0.95, dark)
                dot(2.8, 1.65, 0.36, (1, 1, 1, 1))
            }
            // Ear and antler.
            tri((-0.3, 1.5), (0.9, 2.4), (-3.4, 3.4 + pose.ear * 1.4), coat)
            tri((-0.1, 1.9), (0.6, 2.35), (-2.5, 3.2 + pose.ear * 1.2), Mesh.mix(coat, cream, 0.5))
            antler((0, 0), antlerC)
        } else {
            // Facing you.
            mode = 2
            for sx: Float in [-1, 1] {
                func L(_ a: (Float, Float), _ b: (Float, Float), _ w: Float) {
                    line((a.0 * sx, a.1), (b.0 * sx, b.1), w, antlerC)
                }
                L((1.1, 2.6), (3.6, 5.3), 1.2); L((3.6, 5.3), (4.4, 8.8), 1.1); L((4.4, 8.8), (3.4, 11.8), 1.0)
                L((3.4, 11.8), (1.6, 13.0), 0.9); L((3.8, 6.2), (1.9, 8.2), 0.85); L((4.2, 9.6), (2.2, 11.0), 0.8)
                L((4.0, 11.0), (5.8, 12.6), 0.8)
                tri((1.9 * sx, 1.0), (2.4 * sx, 2.4), (5.4 * sx, 2.2 + pose.ear * 1.2), coat)
                tri((2.2 * sx, 1.4), (2.5 * sx, 2.1), (4.6 * sx, 2.1 + pose.ear), Mesh.mix(coat, cream, 0.5))
            }
            blob(0, 0, 2.9, 3.3, coat, coatRim, n: 14)
            blob(0, -2.3, 2.1, 1.7, muzzle, coatRim, n: 12)
            if pose.carrot > 0.01 {
                let c = pose.carrot
                tri((0.3, -3.4), (1.2, -3.1), (1.6 + 5.6 * c, -4.4 - 1.6 * c), (0.98, 0.52, 0.12, 1))
            }
            if pose.rudolph {
                let np = P(0, -2.6)
                let g = pose.glow
                Mesh.circle(&out, cx: np.0, cy: np.1, r: 8.5 * s * g, center: (1, 0.15, 0.12, 0.24),
                            rim: (1, 0.15, 0.12, 0), segments: 14)
                dot(0, -2.6, 1.25, (1, 0.2, 0.18, 1))
            } else {
                dot(0, -2.6, 1.05, dark)
            }
            line((-0.6, -3.8 - pose.chew * 0.4), (0.6, -3.8 - pose.chew * 0.4), 0.4, coatRim)
            for ex: Float in [-1.35, 1.35] {
                if pose.blink { line((ex - 0.6, 0.7), (ex + 0.6, 0.7), 0.4, dark) } else {
                    dot(ex, 0.7, 0.8, dark)
                    dot(ex + 0.25, 1.0, 0.3, (1, 1, 1, 1))
                }
            }
        }

        if f.alpha < 1 { for i in start..<out.count { out[i].a *= f.alpha } }
    }
}

/// Santa's sleigh and his team: two pairs of reindeer in harness and Rudolph out in front, all at a
/// flying gallop. Santa holds the reins, waves now and then, and his sack of presents rides behind him.
enum SantaSleigh {
    /// Spacing of the team (points at scale 1) and how big the reindeer are drawn.
    private static let gap: Float = 33
    private static let deer: Float = 0.95

    /// `x, y` is the middle of the sleigh's floor, `dir` the flight direction (+1 to the right),
    /// `t` the animation clock.
    static func draw(_ out: inout [Vertex], x: Float, y: Float, dir d: Float, t: Float, scale k: Float = 1) {
        func P(_ u: Float, _ v: Float) -> (Float, Float) { (x + u * d * k, y + v * k) }
        func line(_ a: (Float, Float), _ b: (Float, Float), _ w: Float, _ c: RGBA) {
            Mesh.line(&out, P(a.0, a.1), P(b.0, b.1), width: max(0.5, w * k), color: c)
        }
        func blob(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, _ c: RGBA, _ rim: RGBA, n: Int = 14) {
            let o = P(cx - rx * 0.2 * d, cy + ry * 0.25)
            var prev = P(cx + rx, cy)
            for i in 1...n {
                let a = Float(i) / Float(n) * 2 * .pi
                let q = P(cx + cos(a) * rx, cy + sin(a) * ry)
                Mesh.v(&out, o.0, o.1, c); Mesh.v(&out, prev.0, prev.1, rim); Mesh.v(&out, q.0, q.1, rim)
                prev = q
            }
        }
        func dot(_ cx: Float, _ cy: Float, _ r: Float, _ c: RGBA) { blob(cx, cy, r, r, c, c, n: 10) }

        let red: RGBA = (0.84, 0.1, 0.13, 1), redDark: RGBA = (0.52, 0.04, 0.08, 1)
        let gold: RGBA = (0.98, 0.79, 0.3, 1), goldDark: RGBA = (0.78, 0.55, 0.16, 1)
        let white: RGBA = (1, 1, 1, 1), fur: RGBA = (0.9, 0.92, 0.96, 1)
        let leather: RGBA = (0.42, 0.22, 0.12, 1)

        // The team, from the back: (offset ahead of the sleigh, far one of a pair, Rudolph).
        let team: [(u: Float, far: Bool, lead: Bool)] = [
            (28, true, false), (28 + gap, true, false),
            (28, false, false), (28 + gap, false, false), (28 + 2 * gap, false, true),
        ]
        func frame(_ i: Int, _ m: (u: Float, far: Bool, lead: Bool)) -> (ReindeerArt.Frame, Float) {
            let k0 = Float(i % 3)
            let ph = t * 13 + k0 * 1.9 + (m.far ? 0.7 : 0)
            let bob = sin(ph) * 1.1
            var f = ReindeerArt.Frame(x: 0, y: 0, dir: d, s: deer * k)
            let o = P(m.u + (m.far ? 3.5 : 0), -6 + (m.far ? 3.2 : 0))
            f.x = o.0; f.y = o.1
            f.bob = bob
            f.pitch = 0.07 + sin(t * 1.7 + k0) * 0.025
            f.shade = m.far ? 1 : 0
            return (f, ph)
        }
        /// Where a reindeer's chest strap is, in sleigh coordinates.
        func chest(_ m: (u: Float, far: Bool, lead: Bool)) -> (Float, Float) {
            (m.u + (m.far ? 3.5 : 0) + 8.5 * deer, -6 + (m.far ? 3.2 : 0) + 15.5 * deer)
        }
        func reindeer(_ i: Int) {
            let m = team[i]
            let (f, ph) = frame(i, m)
            var pose = ReindeerArt.Pose()
            pose.hooves = ReindeerArt.gallop(ph)
            pose.neck = 0.62 + sin(ph) * 0.06
            pose.harness = true
            pose.rudolph = m.lead
            pose.glow = 0.85 + 0.15 * sin(t * 5)
            pose.ear = max(0, sin(t * 2.3 + Float(i)))
            pose.tail = 0.5 + 0.5 * sin(ph)
            pose.bell = sin(ph * 2) * 0.6
            pose.blink = (t + Float(i) * 0.7).truncatingRemainder(dividingBy: 3.4) < 0.12
            ReindeerArt.draw(&out, f, pose, t: t)
        }

        // Far reindeer of each pair, then the traces, then the near ones.
        reindeer(0); reindeer(1)
        let back = chest(team[0]), mid = chest(team[1])
        line(chest(team[0]), (back.0 - 3.5, back.1 - 3.2), 1, leather)
        line(chest(team[1]), (mid.0 - 3.5, mid.1 - 3.2), 1, leather)
        // The gangline: from the front of the sleigh through each pair to Rudolph, with little bells.
        let pts: [(Float, Float)] = [(10, 7), chest(team[2]), chest(team[3]), chest(team[4])]
        for j in 1..<pts.count {
            let a = pts[j - 1], b = pts[j]
            let sag: (Float, Float) = ((a.0 + b.0) / 2, min(a.1, b.1) - 2.2)
            line(a, sag, 1.1, leather); line(sag, b, 1.1, leather)
            dot(sag.0, sag.1 - 0.4, 0.9, gold)
        }
        reindeer(2); reindeer(3); reindeer(4)

        // The runner with a curl at the front, and its struts.
        let runner: [(Float, Float)] = [(-38, -9), (4, -9), (9, -8.3), (12.5, -5.5), (13.5, -1.8), (11.8, 1), (9, 0.6), (8.6, -1.6)]
        for j in 1..<runner.count { line(runner[j - 1], runner[j], 1.7, gold) }
        dot(-38, -9, 0.85, gold)
        for u: Float in [-29, -17, -5] { line((u, -9), (u + 0.8, -3), 1.2, goldDark) }

        // The sack of presents behind Santa.
        let sack: RGBA = (0.64, 0.43, 0.22, 1), sackRim: RGBA = (0.42, 0.26, 0.12, 1)
        Mesh.tri(&out, P(-31.5, 20), P(-26.5, 22.8), P(-30.5, 25.5), (0.86, 0.14, 0.18, 1))
        Mesh.tri(&out, P(-26.5, 22.8), P(-30.5, 25.5), P(-25.7, 27.2), (0.7, 0.08, 0.12, 1))
        line((-28.9, 21.4), (-28.3, 26.4), 0.7, gold)
        Mesh.tri(&out, P(-25.5, 21), P(-21.2, 21.4), P(-23.1, 25.6), (0.15, 0.55, 0.3, 1))
        blob(-27, 16.5, 6.6, 6.4, sack, sackRim)
        line((-31, 20.6), (-23, 21.4), 1, sackRim)

        // Santa: the waving arm behind, red coat, white fur, a rosy face in a big beard, a floppy hat.
        let wave = max(0, sin(t * 0.8))
        if wave > 0.05 {
            let hand = (-20.5 + sin(t * 9) * 1.6 * wave, 15 + 11 * wave)
            line((-18.5, 14.5), hand, 2.8, Mesh.mix(red, redDark, 0.35))
            dot(hand.0, hand.1 + 0.6, 1.5, white)
            dot(hand.0, hand.1 + 1.7, 1.45, (0.12, 0.38, 0.22, 1))
        }
        blob(-17, 10.5, 6.6, 8, red, redDark)
        line((-11.4, 6), (-11.2, 16.4), 2.2, fur)
        blob(-15.2, 20.3, 3.7, 3.6, (1, 0.84, 0.73, 1), (0.93, 0.7, 0.6, 1), n: 12)
        blob(-13.1, 16.9, 4.1, 4.4, white, fur, n: 14)
        blob(-11.6, 19, 2.3, 1.15, white, fur, n: 10)
        dot(-10.4, 20.3, 0.95, (0.95, 0.55, 0.52, 1))
        dot(-13.2, 21.5, 0.55, (0.12, 0.08, 0.08, 1))
        dot(-15.4, 19.6, 1.0, (1, 0.62, 0.6, 0.55))
        let sway = sin(t * 3.1) * 1.2
        Mesh.tri(&out, P(-19.2, 23.3), P(-11.6, 23.6), P(-21.8 + sway, 30.4), red)
        Mesh.tri(&out, P(-19.2, 23.3), P(-21.8 + sway, 30.4), P(-20.6, 26), redDark)
        dot(-22.2 + sway, 30.4, 1.7, white)
        line((-19.8, 23.3), (-11.2, 23.7), 2.4, white)
        // The arm holding the reins.
        line((-15.5, 14.2), (-7.2, 11.6), 3, red)
        line((-8.4, 11.9), (-7.6, 11.7), 3.4, fur)
        dot(-6.1, 11.6, 1.6, (0.12, 0.38, 0.22, 1))
        // Reins from the mitten to the first pair, sagging a little.
        let r0: (Float, Float) = (-6.1, 11.6), r1 = chest(team[2])
        let rs: (Float, Float) = ((r0.0 + r1.0) / 2, (r0.1 + r1.1) / 2 - 3)
        line(r0, rs, 0.7, leather); line(rs, (r1.0 + 1.5, r1.1 + 3), 0.7, leather)

        // The sleigh body: a strip between the bottom and the curving top edge, deep red with gold trim.
        let edge: [(Float, Float, Float)] = [(-34.5, -0.5, 13.5), (-31.5, -4, 17.4), (-27.5, -4, 16), (-24, -4, 10),
                                              (-19, -4, 6.8), (-9, -4, 6.2), (0, -4, 6.6), (5, -3.3, 8.2),
                                              (8.4, -0.8, 10.4), (10.6, 3.2, 11.2)]
        for j in 1..<edge.count {
            let a = edge[j - 1], b = edge[j]
            let a0 = P(a.0, a.1), a1 = P(a.0, a.2), b0 = P(b.0, b.1), b1 = P(b.0, b.2)
            Mesh.v(&out, a0.0, a0.1, redDark); Mesh.v(&out, b0.0, b0.1, redDark); Mesh.v(&out, b1.0, b1.1, red)
            Mesh.v(&out, a0.0, a0.1, redDark); Mesh.v(&out, b1.0, b1.1, red); Mesh.v(&out, a1.0, a1.1, red)
        }
        for j in 1..<edge.count { line((edge[j - 1].0, edge[j - 1].2), (edge[j].0, edge[j].2), 1.3, gold) }
        line((-31, -1.8), (6.5, -1.6), 0.8, goldDark)
        // Scrolls at the back and the front, a gold swirl on the side.
        dot(-34.2, 14, 2.1, gold); dot(-34.2, 14, 1.0, redDark)
        dot(10.4, 11, 2.0, gold); dot(10.4, 11, 0.95, redDark)
        line((-21, 1.5), (-16, 3.6), 0.8, gold); line((-16, 3.6), (-11, 1.4), 0.8, gold)
        line((-11, 1.4), (-6, 3.4), 0.8, gold)
        dot(-16, 3.6, 0.7, gold); dot(-6, 3.4, 0.7, gold)
        // A few bells along the top edge.
        for u: Float in [-26, -2] { dot(u, u < -10 ? 13.4 : 6.6, 1.0, gold) }
    }
}

/// Debug render (`ISNOW_REINDEER=sheet iSnow --snapshot out.png`): every reindeer pose large, the visitor
/// at its real size and Santa's sleigh at 1× and 2×, on a plain background.
@MainActor
enum ReindeerSheet {
    static func render(path: String, renderer r: Renderer) {
        let size = CGSize(width: 1200, height: 760)
        var mesh: [Vertex] = []
        Mesh.quad(&mesh, x: 0, y: 0, w: 1200, h: 760, bl: (0.17, 0.27, 0.42, 1), br: (0.17, 0.27, 0.42, 1),
                  tr: (0.24, 0.36, 0.52, 1), tl: (0.24, 0.36, 0.52, 1))
        let big: Float = 3.2
        var poses: [(ReindeerArt.Pose, Float)] = []         // pose and rearing
        func add(_ f: (inout ReindeerArt.Pose) -> Void, pitch: Float = 0) {
            var p = ReindeerArt.Pose(); f(&p); poses.append((p, pitch))
        }
        add { _ in }
        for k in 0..<3 { add { $0.hooves = ReindeerArt.trot(Float(k) * .pi / 2, amp: 3.4, lift: 3.0) } }
        for k in 0..<3 { add { $0.hooves = ReindeerArt.gallop(Float(k) * .pi * 0.66); $0.neck = 0.62 } }
        add { $0.neck = -0.95; $0.chew = 0.6 }
        add { $0.neck = 1.22; $0.headK = 0 }
        add { $0.neck = 1.22; $0.headK = -1; $0.ear = 1; $0.tail = 1 }
        add { $0.neck = 0.42; $0.hooves[0] = (ReindeerArt.frontHip.0 + 4, 3.5) }
        add({
            $0.neck = 1.45; $0.carrot = 0.8; $0.rudolph = true
            for i in [0, 2] { let h = ReindeerArt.hip(i); $0.hooves[i] = (h.0 + 2.2, h.1 - 8.5) }
        }, pitch: 0.3)
        for (i, pp) in poses.enumerated() {
            let cx = Float(150 + (i % 4) * 300), base = Float(560 - (i / 4) * 175)
            Mesh.rect(&mesh, x: cx - 120, y: base - 8, w: 240, h: 8, top: (0.95, 0.97, 1, 1), bottom: (0.8, 0.86, 0.95, 1))
            var f = ReindeerArt.Frame(x: cx, y: base, dir: i == 9 ? -1 : 1, s: big)
            f.pitch = pp.1
            ReindeerArt.draw(&mesh, f, pp.0, t: 1)
        }
        // Real size, the sleigh at 1× and 2×.
        Mesh.rect(&mesh, x: 0, y: 0, w: 1200, h: 34, top: (0.95, 0.97, 1, 1), bottom: (0.8, 0.86, 0.95, 1))
        ReindeerArt.draw(&mesh, ReindeerArt.Frame(x: 60, y: 34, dir: 1, s: 1.25), ReindeerArt.Pose(), t: 1)
        var rp = ReindeerArt.Pose(); rp.rudolph = true; rp.hooves = ReindeerArt.trot(1, amp: 3.4, lift: 3)
        ReindeerArt.draw(&mesh, ReindeerArt.Frame(x: 120, y: 34, dir: -1, s: 1.25), rp, t: 1)
        SantaSleigh.draw(&mesh, x: 240, y: 70, dir: 1, t: 2.3)
        SantaSleigh.draw(&mesh, x: 700, y: 80, dir: 1, t: 4.1, scale: 2.2)
        let w = Int(size.width) * 2, h = Int(size.height) * 2
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        guard let tex = r.device.makeTexture(descriptor: d) else { return }
        r.render(to: tex, size: size, particles: [], mesh: mesh)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let img = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)?.makeImage()
        print(Snapshot.savePNG(img, path) ? "ok sheet \(mesh.count) vertices" : "sheet failed")
    }
}
