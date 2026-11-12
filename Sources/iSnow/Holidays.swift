import CoreGraphics
import Foundation

/// The holiday calendar (Christmas season, Advent, Christmas Eve, New Year's Eve) and the clock it runs on.
enum Holidays {
    /// `SimConfig.christmasMode`.
    enum ChristmasMode: Int, CaseIterable, Identifiable, Sendable {
        case off, on, automatic
        var id: Int { rawValue }
    }

    /// Snapshot runs set the clock frame by frame (their simulated time runs faster than the wall clock).
    nonisolated(unsafe) static var fixedNow: Date?
    /// `ISNOW_DATE` (local time, e.g. `2026-12-31T23:58:00`) shifts the holiday clock of the running app.
    static let envOffset: TimeInterval = {
        guard let s = ProcessInfo.processInfo.environment["ISNOW_DATE"], let d = parse(s) else { return 0 }
        return d.timeIntervalSinceNow
    }()

    static func now() -> Date { fixedNow ?? Date(timeIntervalSinceNow: envOffset) }

    /// `2026-12-31T23:58:00`, `2026-12-31 23:58`, `2026-12-24` (local time) or a full ISO 8601 date.
    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    /// The local date and time, with the holiday questions answered.
    struct Info: Equatable, Sendable {
        var year = 2000, month = 6, day = 1, hour = 12, minute = 0, second = 0

        /// The automatic Christmas mode: 1 December – 6 January.
        var christmasSeason: Bool { month == 12 || (month == 1 && day <= 6) }
        /// Advent candles on the tree: one for every December day up to the 24th (all of them until 6 January).
        var advent: Int { month == 12 ? min(day, 24) : (month == 1 && day <= 6 ? 24 : 0) }
        var christmasEve: Bool { month == 12 && day == 24 }
        /// Santa brings presents on 24–26 December.
        var giftDays: Bool { month == 12 && (24...26).contains(day) }
        /// Days left until Christmas Eve, 1…23 during Advent.
        var daysToChristmas: Int? { month == 12 && day < 24 ? 24 - day : nil }
        /// New Year's Eve mode: 31 December 12:00 – 1 January 02:00.
        var newYearWindow: Bool { (month == 12 && day == 31 && hour >= 12) || (month == 1 && day == 1 && hour < 2) }
        /// Rockets, party hats and sparklers: from 18:00.
        var newYearEvening: Bool { (month == 12 && day == 31 && hour >= 18) || (month == 1 && day == 1 && hour < 2) }
        var secondsToMidnight: Int? { month == 12 && day == 31 ? 86_400 - (hour * 3600 + minute * 60 + second) : nil }
        var secondsSinceMidnight: Int? { month == 1 && day == 1 ? hour * 3600 + minute * 60 + second : nil }
    }

    static func info(at d: Date) -> Info {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return Info(year: c.year ?? 2000, month: c.month ?? 6, day: c.day ?? 1, hour: c.hour ?? 12,
                    minute: c.minute ?? 0, second: c.second ?? 0)
    }

    static func christmasActive(mode: Int, at d: Date = now()) -> Bool {
        switch ChristmasMode(rawValue: mode) ?? .automatic {
        case .off: false
        case .on: true
        case .automatic: info(at: d).christmasSeason
        }
    }

    /// The menu's switch: turns Christmas on or off; when that is what the calendar says anyway, back to automatic.
    static func setChristmas(_ on: Bool, in c: inout SimConfig) {
        let season = info(at: now()).christmasSeason
        c.christmasMode = (on == season ? ChristmasMode.automatic : on ? .on : .off).rawValue
        c.christmas = on
    }

    static func setMode(_ mode: Int, in c: inout SimConfig) {
        c.christmasMode = mode
        c.christmas = christmasActive(mode: mode)
    }

    /// Settings saved before 1.3 only had the on/off switch: on stays on, everything else becomes automatic.
    static func migrate(_ c: inout SimConfig, stored data: Data) {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["christmasMode"] == nil else { return }
        c.christmasMode = (dict["christmas"] as? Bool) == true ? ChristmasMode.on.rawValue : ChristmasMode.automatic.rawValue
    }

    @MainActor private static var checked: (minute: Int, mode: Int, on: Bool) = (-1, -1, false)

    /// Keeps `config.christmas` (what everything draws from) in line with the mode and the date. Called from
    /// the window poll; looks at the calendar once a minute (so midnight and every hour are covered) and at once
    /// when the mode changed. Returns true when it changed the settings (which polls again by itself).
    @MainActor @discardableResult
    static func refresh(_ settings: Settings) -> Bool {
        let d = now()
        let minute = Int(d.timeIntervalSince1970 / 60)
        let mode = settings.config.christmasMode
        if checked == (minute, mode, settings.config.christmas) { return false }
        let on = christmasActive(mode: mode, at: d)
        checked = (minute, mode, on)
        guard settings.config.christmas != on else { return false }
        settings.config.christmas = on
        return true
    }
}

// MARK: - Pixel font

/// A tiny seven-segment font built from rectangles (digits, `:`, `.`, `-`, space) – for the wooden sign.
enum PixelFont {
    static func charWidth(_ ch: Character, height h: Float) -> Float {
        switch ch {
        case ":", ".": h * 0.17
        case " ": h * 0.35
        default: h * 0.56
        }
    }

    static func width(_ text: String, height h: Float) -> Float {
        var w: Float = 0
        for (i, ch) in text.enumerated() { w += charWidth(ch, height: h) + (i > 0 ? h * 0.2 : 0) }
        return w
    }

    // Segments a…g: top, top right, bottom right, bottom, bottom left, top left, middle.
    private static let segments: [Character: [Character]] = [
        "0": ["a", "b", "c", "d", "e", "f"], "1": ["b", "c"], "2": ["a", "b", "g", "e", "d"],
        "3": ["a", "b", "g", "c", "d"], "4": ["f", "g", "b", "c"], "5": ["a", "f", "g", "c", "d"],
        "6": ["a", "f", "g", "e", "d", "c"], "7": ["a", "b", "c"], "8": ["a", "b", "c", "d", "e", "f", "g"],
        "9": ["a", "b", "c", "d", "f", "g"], "-": ["g"],
    ]

    /// Draws `text` with its bottom left corner at (x, y); returns the width.
    @discardableResult
    static func draw(_ out: inout [Vertex], _ text: String, x x0: Float, y: Float, height h: Float, color c: RGBA) -> Float {
        let t = h * 0.17, w = h * 0.56
        var x = x0
        for (i, ch) in text.enumerated() {
            if i > 0 { x += h * 0.2 }
            func r(_ rx: Float, _ ry: Float, _ rw: Float, _ rh: Float) {
                Mesh.rect(&out, x: x + rx, y: y + ry, w: rw, h: rh, top: c, bottom: c)
            }
            switch ch {
            case ":":
                r(0, h * 0.22, t, t); r(0, h * 0.62, t, t)
            case ".":
                r(0, 0, t, t)
            default:
                for s in segments[ch] ?? [] {
                    switch s {
                    case "a": r(0, h - t, w, t)
                    case "d": r(0, 0, w, t)
                    case "g": r(0, (h - t) / 2, w, t)
                    case "f": r(0, h / 2, t, h / 2)
                    case "b": r(w - t, h / 2, t, h / 2)
                    case "e": r(0, 0, t, h / 2 + t / 2)
                    default: r(w - t, 0, t, h / 2 + t / 2)          // c
                    }
                }
            }
            x += charWidth(ch, height: h)
        }
        return x - x0
    }
}

// MARK: - The holiday scene

/// What the holidays add to the screen with the characters: presents Santa drops by the tree, the wooden
/// countdown sign, fireworks with confetti at midnight. Plain value state stepped and drawn by `Simulation`.
struct HolidayScene {
    enum Burst: CaseIterable { case peony, ring, willow, twoTone }
    enum SignItem: Equatable { case text(String), tree, heart, burst }

    struct Rocket { var x, y, vx, vy, power: Float; var burst: Burst; var color: Int; var ember: Float }
    struct Spark {
        var x, y, vx, vy, life, maxLife, r, drag, gravity: Float
        var color: RGBA
        var kind: UInt8                 // 0 star, 1 glitter (twinkles), 2 ember (rocket trail), 3 burst flash
    }
    struct Confetto { var x, y, vx, vy, phase, spin, life: Float; var color: RGBA }
    struct Present {
        var x, y, vx, vy: Float
        var slot: Int
        var landed = false
    }

    private(set) var info = Holidays.Info()
    private var infoSecond = Int.min
    private(set) var rockets: [Rocket] = []
    private(set) var sparks: [Spark] = []
    private(set) var confetti: [Confetto] = []
    private(set) var presents: [Present] = []
    private(set) var showLeft: Float = 0       // seconds of the big show left (midnight or the button)
    private var showLength: Float = 120
    private var nextRocket: Float = 12
    private(set) var flash: Float = 0          // seconds of flashing lights left
    private var partyLeft: Float = 0           // the button's show: party hats for a while
    private var celebrated = 0                 // the year whose midnight was celebrated
    private var dropDelay: Float = 0
    private var flashTime: Float = 0
    var drawnSign: [SignItem]?                 // what the sign showed in the last frame

    static let maxSparks = 1800

    /// Re-reads the calendar once a second.
    mutating func refresh(_ d: Date) {
        let s = Int(d.timeIntervalSince1970.rounded(.down))
        guard s != infoSecond else { return }
        infoSecond = s
        info = Holidays.info(at: d)
    }

    /// Fireworks, falling presents, confetti or flashing lights in the air (the render loop must keep running).
    var isAlive: Bool {
        !rockets.isEmpty || !sparks.isEmpty || !confetti.isEmpty || showLeft > 0 || flash > 0
            || presents.contains { !$0.landed }
    }

    func partyTime(newYear: Bool) -> Bool { (newYear && info.newYearEvening) || partyLeft > 0 }

    /// Days to Christmas in Advent, a tree and a heart on 24–26 December, the countdown to midnight on
    /// New Year's Eve and the new year after it. Nil: no sign.
    func sign(christmas: Bool, newYear: Bool) -> [SignItem]? {
        if newYear, info.newYearWindow {
            if let s = info.secondsToMidnight {
                if s <= 60 { return [.burst, .text("\(s)")] }
                let m = (s + 59) / 60
                return [.burst, .text(String(format: "%d:%02d", m / 60, m % 60))]
            }
            return [.burst, .text("\(info.year)")]
        }
        guard christmas else { return nil }
        if let d = info.daysToChristmas { return [.tree, .text("\(d)")] }
        if info.giftDays { return [.tree, .heart] }
        return nil
    }

    // MARK: Fireworks

    /// The big show: rockets every second or so, salvos, a dense finale. `extras`: flashing lights and confetti.
    mutating func startShow(seconds: Float, extras: Bool, party: Bool, W: Float, H: Float) {
        showLength = max(showLeft, seconds)
        showLeft = showLength
        nextRocket = 0
        if party { partyLeft = max(partyLeft, seconds + 30) }
        if extras {
            flash = 4.5
            flashTime = 0
            throwConfetti(W: W, H: H)
        }
    }

    mutating func clearSky() {
        rockets.removeAll()
        sparks.removeAll()
        confetti.removeAll()
        showLeft = 0
        flash = 0
        for i in presents.indices { presents[i].landed = true }
    }

    /// How long until the next single rocket on New Year's Eve: rare in the evening, often just before midnight.
    private func eveningGap() -> Float {
        if let s = info.secondsToMidnight {
            if s <= 300 { return .random(in: 2.5...7) }
            if s <= 3600 { return .random(in: 14...40) }
            return .random(in: 45...130)
        }
        if let s = info.secondsSinceMidnight, s < 1800 { return .random(in: 15...50) }
        return .random(in: 60...180)
    }

    private func showGap() -> Float {
        let elapsed = showLength - showLeft
        if showLeft < 16 { return .random(in: 0.08...0.22) }              // finale
        if elapsed < 8 { return .random(in: 0.2...0.5) }
        return .random(in: 0.3...0.9)
    }

    mutating func launch(W: Float, H: Float, big: Bool) {
        guard rockets.count < 12, W > 100, H > 100 else { return }
        let g: Float = 260
        let top = H * Float.random(in: big ? 0.48...0.84 : 0.55...0.8)
        let vy = (2 * g * top).squareRoot()
        let x = W * Float.random(in: 0.1...0.9)
        rockets.append(Rocket(x: x, y: -4, vx: Float.random(in: -30...30) - (x - W / 2) * 0.03, vy: vy,
                              power: Float.random(in: big ? 0.9...1.35 : 0.8...1.1),
                              burst: Burst.allCases.randomElement() ?? .peony,
                              color: Int.random(in: 0..<Self.colors.count), ember: 0))
    }

    static let colors: [RGBA] = [(1, 0.28, 0.32, 1), (0.35, 1, 0.5, 1), (0.4, 0.62, 1, 1), (1, 0.8, 0.3, 1),
                                 (1, 0.42, 0.92, 1), (0.45, 0.95, 1, 1), (0.95, 0.95, 1, 1), (1, 0.56, 0.2, 1)]
    static let gold: RGBA = (1, 0.78, 0.38, 1)

    private mutating func burst(_ r: Rocket, size k: Float) {
        let room = Self.maxSparks - sparks.count
        guard room > 10 else { return }
        let c = Self.colors[r.color % Self.colors.count]
        let v0 = Float.random(in: 150...185) * r.power * k
        sparks.append(Spark(x: r.x, y: r.y, vx: 0, vy: 0, life: 0.35, maxLife: 0.35, r: 34 * r.power * k,
                            drag: 0, gravity: 0, color: c, kind: 3))
        func star(_ vx: Float, _ vy: Float, life: Float, color: RGBA, kind: UInt8 = 0, drag: Float = 1.25,
                  gravity: Float = 70, radius: Float = 2) {
            sparks.append(Spark(x: r.x, y: r.y, vx: vx, vy: vy, life: life, maxLife: life, r: radius * k,
                                drag: drag, gravity: gravity, color: color, kind: kind))
        }
        switch r.burst {
        case .peony, .twoTone:
            let n = min(room - 1, r.burst == .twoTone ? 84 : 72)
            let inner = Self.colors[(r.color + 3) % Self.colors.count]
            for i in 0..<n {
                // A sphere seen from the side: most stars near the rim.
                let z = Float.random(in: -1...1), a = Float.random(in: 0...(2 * .pi))
                let core = r.burst == .twoTone && i % 3 == 0
                let v = v0 * (1 - z * z).squareRoot() * Float.random(in: 0.92...1.05) * (core ? 0.5 : 1)
                star(cos(a) * v, sin(a) * v, life: .random(in: 1.6...2.3), color: core ? inner : c)
            }
        case .ring:
            let n = min(room - 1, 52)
            let tilt = Float.random(in: 0.35...1), rot = Float.random(in: 0...(.pi))
            for i in 0..<n {
                let a = Float(i) / Float(n) * 2 * .pi
                let ex = cos(a), ey = sin(a) * tilt
                let vx = (ex * cos(rot) - ey * sin(rot)) * v0, vy = (ex * sin(rot) + ey * cos(rot)) * v0
                star(vx, vy, life: .random(in: 1.5...1.9), color: c, radius: 2.1)
            }
            for _ in 0..<min(max(0, room - n - 1), 10) {
                let a = Float.random(in: 0...(2 * .pi)), v = v0 * Float.random(in: 0.05...0.25)
                star(cos(a) * v, sin(a) * v, life: .random(in: 0.9...1.3), color: (1, 1, 1, 1), kind: 1)
            }
        case .willow:
            let n = min(room - 1, 64)
            for _ in 0..<n {
                let z = Float.random(in: -1...1), a = Float.random(in: 0...(2 * .pi))
                let v = v0 * 0.95 * (1 - z * z).squareRoot() * Float.random(in: 0.9...1.05)
                star(cos(a) * v, sin(a) * v, life: .random(in: 3...4), color: Self.gold, kind: 1,
                     drag: 1.6, gravity: 46, radius: 1.7)
            }
        }
    }

    private mutating func throwConfetti(W: Float, H: Float) {
        let n = min(170, Int(W / 7))
        confetti.reserveCapacity(n)
        for _ in 0..<n {
            confetti.append(Confetto(x: .random(in: 0...W), y: H - .random(in: 30...150),
                                     vx: .random(in: -40...40), vy: .random(in: -10...90),
                                     phase: .random(in: 0...6.3), spin: .random(in: 4...11),
                                     life: .random(in: 6...9), color: Self.colors.randomElement() ?? Self.gold))
        }
    }

    // MARK: Step

    /// `auto`: the calendar may start things (not paused, not full screen). `ground(x)`: where things land.
    mutating func step(dt: Float, W: Float, H: Float, auto: Bool, newYear: Bool,
                       ground: (Float) -> Float, debris: inout [Debris]) {
        // Midnight: the big show, flashing lights, confetti (also when the Mac wakes up within the two minutes).
        if newYear, auto, let s = info.secondsSinceMidnight, s < 120, celebrated != info.year {
            celebrated = info.year
            startShow(seconds: Float(120 - s), extras: s < 20, party: false, W: W, H: H)
        }
        let k = min(1.5, max(0.9, H / 900))
        if showLeft > 0 {
            showLeft -= dt
            nextRocket -= dt
            if nextRocket <= 0 {
                launch(W: W, H: H, big: true)
                if Float.random(in: 0...1) < 0.16 { launch(W: W, H: H, big: true); launch(W: W, H: H, big: true) }
                nextRocket = showLeft > 0 ? showGap() : eveningGap()
            }
        } else if newYear, auto, info.newYearEvening {
            nextRocket -= dt
            if nextRocket <= 0 {
                launch(W: W, H: H, big: false)
                nextRocket = eveningGap()
            }
        }
        partyLeft = max(0, partyLeft - dt)
        if flash > 0 { flash = max(0, flash - dt); flashTime += dt }

        // Rockets climb, leave a trail of embers and burst near the top of their arc.
        var i = 0
        while i < rockets.count {
            var r = rockets[i]
            r.vy -= 260 * dt
            r.x += r.vx * dt
            r.y += r.vy * dt
            r.ember += dt * 26
            while r.ember >= 1, sparks.count < Self.maxSparks {
                r.ember -= 1
                let life = Float.random(in: 0.35...0.7)
                sparks.append(Spark(x: r.x + .random(in: -1...1), y: r.y - .random(in: 0...6),
                                    vx: .random(in: -14...14), vy: r.vy * 0.15 + .random(in: -20...5), life: life,
                                    maxLife: life, r: 0.9, drag: 2.5, gravity: 60, color: Self.gold, kind: 2))
            }
            if r.vy <= 35 {
                burst(r, size: k)
                rockets.remove(at: i)
            } else {
                rockets[i] = r
                i += 1
            }
        }

        // Stars slow down in the air, fall and fade (compacted in place).
        if !sparks.isEmpty {
            var kept = 0
            sparks.withUnsafeMutableBufferPointer { buf in
                for j in 0..<buf.count {
                    var s = buf[j]
                    s.life -= dt
                    if s.life <= 0 { continue }
                    let d = max(0, 1 - s.drag * dt)
                    s.vx *= d
                    s.vy = s.vy * d - s.gravity * dt
                    s.x += s.vx * dt
                    s.y += s.vy * dt
                    buf[kept] = s
                    kept += 1
                }
            }
            sparks.removeLast(sparks.count - kept)
        }

        if !confetti.isEmpty {
            var kept = 0
            for j in confetti.indices {
                var c = confetti[j]
                c.life -= dt
                guard c.life > 0, c.y > -10 else { continue }
                c.phase += dt * c.spin
                c.vy = max(-38, c.vy - 160 * dt)                     // paper: falls slowly
                c.vx = c.vx * max(0, 1 - 1.2 * dt) + sin(c.phase * 0.5) * 30 * dt
                c.x += (c.vx + sin(c.phase * 0.31) * 12) * dt
                c.y += c.vy * dt
                confetti[kept] = c
                kept += 1
            }
            confetti.removeLast(confetti.count - kept)
        }

        // Presents fall from Santa's sack and land in the snow by the tree.
        for j in presents.indices where !presents[j].landed {
            var p = presents[j]
            p.vy -= 520 * dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            let floor = presentFloor(j, ground: ground)
            if p.y <= floor {
                p.y = floor
                p.landed = true
                for _ in 0..<10 where debris.count < 9000 {
                    debris.append(Debris(x: p.x + .random(in: -8...8), y: floor + .random(in: 0...3),
                                         vx: .random(in: -70...70), vy: .random(in: 30...110),
                                         size: .random(in: 1.2...2.6), alpha: 0.9, lands: false, fade: 1.4))
                }
            }
            presents[j] = p
        }
    }

    // MARK: Presents

    /// Where the presents land, beside the tree on the side away from the Dock: offset (tree units), size,
    /// colours, and the present it sits on (stacked).
    static let presentSlots: [(dx: Float, w: Float, h: Float, color: RGBA, ribbon: RGBA, on: Int?)] = [
        (55, 14, 11, (0.86, 0.14, 0.2, 1), (1, 0.84, 0.3, 1), nil),
        (70, 12, 15, (0.18, 0.55, 0.3, 1), (0.95, 0.2, 0.25, 1), nil),
        (85, 15, 9, (0.22, 0.45, 0.92, 1), (1, 1, 1, 1), nil),
        (56, 9, 8, (0.98, 0.78, 0.22, 1), (0.85, 0.15, 0.2, 1), 0),
        (85, 9, 7, (0.62, 0.3, 0.85, 1), (1, 0.84, 0.3, 1), 2),
    ]

    private func presentFloor(_ j: Int, ground: (Float) -> Float) -> Float {
        let slot = Self.presentSlots[presents[j].slot]
        guard let below = slot.on, presents.indices.contains(below) else { return ground(presents[j].x) }
        return ground(presents[below].x) + Self.presentSlots[presents[below].slot].h * treeScale
    }

    private(set) var treeScale: Float = 1

    /// Santa flies over: on 24–26 December he drops his presents so they land next to the tree at `treeX`.
    mutating func santaOverhead(x: Float, y: Float, dir: Float, dt: Float, treeX: Float, side: Float, scale s: Float,
                                ground: (Float) -> Float) {
        guard info.giftDays, presents.count < Self.presentSlots.count else { return }
        treeScale = s
        dropDelay -= dt
        let sx = x - dir * 24, sy = y + 6
        guard dropDelay <= 0, abs(sx - treeX) < 240 else { return }
        dropDelay = 0.22
        let slot = presents.count
        let tx = treeX + side * Self.presentSlots[slot].dx * s
        let fall = max(30, sy - ground(tx))
        let t = (2 * fall / 520).squareRoot()
        presents.append(Present(x: sx, y: sy, vx: (tx - sx) / t, vy: 0, slot: slot))
    }

    /// The presents stay for the gift days only.
    mutating func tidyPresents() {
        if !info.giftDays && !presents.isEmpty { presents.removeAll() }
    }

    // MARK: Drawing

    /// Fireworks: rockets with their trails, stars as small glowing discs with a short streak.
    func buildSky(into out: inout [Vertex], t: Float) {
        guard !rockets.isEmpty || !sparks.isEmpty else { return }
        for (j, s) in sparks.enumerated() {
            let u = s.life / s.maxLife                         // 1 → 0
            if s.kind == 3 {                                   // the flash of a burst
                Self.glow(&out, x: s.x, y: s.y, r: s.r * (1.1 - 0.4 * u), center: (1, 0.97, 0.9, 0.42 * u * u),
                          rim: (s.color.0, s.color.1, s.color.2, 0), segments: 12)
                continue
            }
            var a = min(1, u * 2.4)
            if s.kind == 1 {                                   // glitter twinkles as it falls
                let tw = sin(t * 31 + Float(j) * 2.39)
                a *= tw > 0.2 ? 1 : 0.25
            }
            let hot = max(0, (u - 0.82) / 0.18)                // white-hot right after the burst
            let c = Mesh.mix(s.color, (1, 1, 1, 1), 0.12 + 0.7 * hot)
            let r = s.r * (s.kind == 2 ? 1 : 0.8 + 0.4 * u)
            // streak behind the star
            let len: Float = s.kind == 2 ? 0.05 : (s.kind == 1 ? 0.14 : 0.1)
            let tx = s.x - s.vx * len, ty = s.y - s.vy * len
            let dx = s.x - tx, dy = s.y - ty
            let dl = max(0.001, (dx * dx + dy * dy).squareRoot())
            if dl > 1.5 {
                let nx = -dy / dl * r * 0.55, ny = dx / dl * r * 0.55
                let head: RGBA = (c.0, c.1, c.2, a * 0.85)
                Mesh.v(&out, s.x + nx, s.y + ny, head); Mesh.v(&out, s.x - nx, s.y - ny, head)
                Mesh.v(&out, tx, ty, (s.color.0, s.color.1, s.color.2, 0))
            }
            Self.glow(&out, x: s.x, y: s.y, r: r * 3, center: (s.color.0, s.color.1, s.color.2, a * 0.6),
                      rim: (s.color.0, s.color.1, s.color.2, 0), segments: 6)
            if s.kind != 2 {                                   // a crisp bright core
                let q = r * 0.75, col: RGBA = (c.0, c.1, c.2, a)
                Mesh.tri(&out, (s.x - q, s.y), (s.x, s.y - q), (s.x + q, s.y), col)
                Mesh.tri(&out, (s.x - q, s.y), (s.x + q, s.y), (s.x, s.y + q), col)
            }
        }
        for r in rockets {
            let tx = r.x - r.vx * 0.11, ty = r.y - r.vy * 0.11
            let w: Float = 1.3
            Mesh.v(&out, r.x - w, r.y, (1, 0.85, 0.55, 0.9)); Mesh.v(&out, r.x + w, r.y, (1, 0.85, 0.55, 0.9))
            Mesh.v(&out, tx, ty, (1, 0.6, 0.25, 0))
            Self.glow(&out, x: r.x, y: r.y, r: 4.5, center: (1, 0.95, 0.8, 1), rim: (1, 0.7, 0.3, 0), segments: 8)
        }
    }

    func buildConfetti(into out: inout [Vertex]) {
        for c in confetti {
            let a = min(1, c.life / 1.5)
            let flip = abs(cos(c.phase)) * 4.4 + 0.6, h: Float = 2.6
            let ang = c.phase * 0.37
            let ca = cos(ang), sa = sin(ang)
            func p(_ u: Float, _ v: Float) -> (Float, Float) { (c.x + u * ca - v * sa, c.y + u * sa + v * ca) }
            let shade: Float = 0.75 + 0.25 * abs(sin(c.phase))
            let col: RGBA = (c.color.0 * shade, c.color.1 * shade, c.color.2 * shade, a)
            let p0 = p(-flip / 2, -h / 2), p1 = p(flip / 2, -h / 2), p2 = p(flip / 2, h / 2), p3 = p(-flip / 2, h / 2)
            Mesh.tri(&out, p0, p1, p2, col)
            Mesh.tri(&out, p0, p2, p3, col)
        }
    }

    /// The presents Santa dropped (falling or lying by the tree).
    func buildPresents(into out: inout [Vertex], ground: (Float) -> Float, alpha: Float) {
        for (j, p) in presents.enumerated() {
            let slot = Self.presentSlots[p.slot]
            let s = treeScale
            let y = p.landed ? presentFloor(j, ground: ground) : p.y
            let start = out.count
            // [1.3 tree] the same wrapped present as under the tree (no shadow while it falls)
            Christmas.giftBox(&out, x: p.x, y: y, w: slot.w * s, h: slot.h * s, color: slot.color, ribbon: slot.ribbon,
                              s: s, shadow: p.landed)
            if alpha < 1 { for v in start..<out.count { out[v].a *= alpha } }
        }
    }

    static func present(_ out: inout [Vertex], x: Float, y: Float, w: Float, h: Float, color c: RGBA, ribbon r: RGBA,
                        s: Float) {
        Mesh.rect(&out, x: x - w / 2, y: y, w: w, h: h, top: c, bottom: (c.0 * 0.72, c.1 * 0.72, c.2 * 0.72, 1))
        Mesh.rect(&out, x: x - w / 2, y: y + h - 1.2 * s, w: w, h: 1.2 * s,
                  top: (min(1, c.0 + 0.15), min(1, c.1 + 0.15), min(1, c.2 + 0.15), 1), bottom: c)   // lid
        Mesh.rect(&out, x: x - 1.1 * s, y: y, w: 2.2 * s, h: h, top: r, bottom: r)
        Mesh.rect(&out, x: x - w / 2, y: y + h * 0.5, w: w, h: 2 * s, top: r, bottom: r)
        Mesh.circle(&out, cx: x - 2 * s, cy: y + h + 1.4 * s, r: 1.9 * s, center: r, rim: r, segments: 8)
        Mesh.circle(&out, cx: x + 2 * s, cy: y + h + 1.4 * s, r: 1.9 * s, center: r, rim: r, segments: 8)
    }

    /// The wooden sign stuck in the snow, with `items` painted on it.
    static func buildSign(into out: inout [Vertex], items: [SignItem], x: Float, ground: Float, scale s: Float,
                          t: Float, alpha: Float) {
        let start = out.count
        let th = 9.5 * s, gap = 2.6 * s
        func itemWidth(_ it: SignItem) -> Float {
            switch it {
            case .text(let str): PixelFont.width(str, height: th)
            case .tree, .heart, .burst: th * 0.95
            }
        }
        let content = items.map(itemWidth).reduce(0, +) + gap * Float(max(0, items.count - 1))
        let bw = content + 9 * s, bh = th + 8 * s
        let x0 = x - bw / 2, yb = ground + 12 * s
        let wood: RGBA = (0.56, 0.35, 0.18, 1), woodDark: RGBA = (0.33, 0.2, 0.1, 1), woodLight: RGBA = (0.64, 0.42, 0.22, 1)
        // post, stuck in the snow
        Mesh.rect(&out, x: x - 1.7 * s, y: ground, w: 3.4 * s, h: yb - ground + 2 * s, top: wood, bottom: woodDark)
        // board: dark edge, two planks
        Mesh.rect(&out, x: x0, y: yb, w: bw, h: bh, top: woodDark, bottom: woodDark)
        let inset = 0.9 * s, ph = (bh - 2 * inset) / 2
        Mesh.rect(&out, x: x0 + inset, y: yb + inset, w: bw - 2 * inset, h: ph - 0.3 * s, top: wood, bottom: (0.5, 0.31, 0.16, 1))
        Mesh.rect(&out, x: x0 + inset, y: yb + inset + ph + 0.3 * s, w: bw - 2 * inset, h: ph - 0.3 * s,
                  top: woodLight, bottom: wood)
        for nx in [x0 + 2.2 * s, x0 + bw - 2.2 * s] {                // nails
            Mesh.disc(&out, cx: nx, cy: yb + bh / 2, r: 0.7 * s, color: (0.25, 0.2, 0.18, 1))
        }
        // painted content
        var cx = x0 + 4.5 * s
        let cy = yb + 4 * s
        let paint: RGBA = (1, 0.96, 0.84, 1)
        for it in items {
            switch it {
            case .text(let str):
                PixelFont.draw(&out, str, x: cx, y: cy, height: th, color: paint)
            case .tree:
                let w = th * 0.95, mx = cx + w / 2
                Mesh.rect(&out, x: mx - th * 0.08, y: cy, w: th * 0.16, h: th * 0.2, top: (0.4, 0.24, 0.12, 1), bottom: (0.4, 0.24, 0.12, 1))
                let green: RGBA = (0.2, 0.75, 0.35, 1)
                Mesh.tri(&out, (cx, cy + th * 0.18), (cx + w, cy + th * 0.18), (mx, cy + th * 0.66), green)
                Mesh.tri(&out, (cx + w * 0.14, cy + th * 0.48), (cx + w * 0.86, cy + th * 0.48), (mx, cy + th * 0.9), green)
                Mesh.disc(&out, cx: mx, cy: cy + th * 0.93, r: th * 0.11, color: (1, 0.85, 0.25, 1))
            case .heart:
                let w = th * 0.95, mx = cx + w / 2, red: RGBA = (0.92, 0.16, 0.22, 1)
                Mesh.disc(&out, cx: mx - w * 0.22, cy: cy + th * 0.62, r: w * 0.25, color: red)
                Mesh.disc(&out, cx: mx + w * 0.22, cy: cy + th * 0.62, r: w * 0.25, color: red)
                Mesh.tri(&out, (mx - w * 0.47, cy + th * 0.58), (mx + w * 0.47, cy + th * 0.58), (mx, cy + th * 0.08), red)
            case .burst:
                let w = th * 0.95, mx = cx + w / 2, my = cy + th / 2
                for k in 0..<8 {
                    let a = Float(k) * .pi / 4 + 0.2
                    let c: RGBA = k % 2 == 0 ? (1, 0.82, 0.3, 1) : (1, 0.4, 0.45, 1)
                    Mesh.line(&out, (mx + cos(a) * w * 0.14, my + sin(a) * w * 0.14),
                              (mx + cos(a) * w * 0.48, my + sin(a) * w * 0.48), width: 0.95 * s, color: c)
                }
                Mesh.disc(&out, cx: mx, cy: my, r: 0.9 * s, color: (1, 0.95, 0.75, 1))
            }
            cx += itemWidth(it) + gap
        }
        // snow on top of the board and around the post
        let snow: RGBA = (1, 1, 1, 0.97), shade: RGBA = (0.86, 0.9, 0.98, 0.97)
        Mesh.rect(&out, x: x0 - 1 * s, y: yb + bh - 0.6 * s, w: bw + 2 * s, h: 2.2 * s, top: snow, bottom: shade)
        Mesh.circle(&out, cx: x0 + bw * 0.3, cy: yb + bh + 1.4 * s, r: 1.9 * s, center: snow, rim: shade, segments: 10)
        Mesh.circle(&out, cx: x0 + bw * 0.72, cy: yb + bh + 1.2 * s, r: 1.6 * s, center: snow, rim: shade, segments: 10)
        Mesh.sector(&out, cx: x, cy: ground - 1, r: 6 * s, from: 0, to: .pi, center: snow, rim: shade, segments: 10)
        if alpha < 1 { for v in start..<out.count { out[v].a *= alpha } }
    }

    private static let unit6: [(Float, Float)] = (0...6).map { (cos(Float($0) * .pi / 3), sin(Float($0) * .pi / 3)) }
    private static let unit8: [(Float, Float)] = (0...8).map { (cos(Float($0) * .pi / 4), sin(Float($0) * .pi / 4)) }
    private static let unit12: [(Float, Float)] = (0...12).map { (cos(Float($0) * .pi / 6), sin(Float($0) * .pi / 6)) }

    /// A soft disc: bright centre fading to the rim (the centre is exact, unlike `Mesh.circle`).
    @inline(__always)
    static func glow(_ out: inout [Vertex], x: Float, y: Float, r: Float, center: RGBA, rim: RGBA, segments n: Int) {
        let u = n == 6 ? unit6 : (n == 8 ? unit8 : unit12)
        for k in 0..<(u.count - 1) {
            Mesh.v(&out, x, y, center)
            Mesh.v(&out, x + u[k].0 * r, y + u[k].1 * r, rim)
            Mesh.v(&out, x + u[k + 1].0 * r, y + u[k + 1].1 * r, rim)
        }
    }
}
