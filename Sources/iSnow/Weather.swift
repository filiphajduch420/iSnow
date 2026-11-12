import Foundation
import Observation

// [1.3 weather] Living weather: the snowfall, the wind and the temperature wander slowly around the user's
// settings. One shared state (owned by the app delegate) is applied to every screen's simulation; the
// stored settings and the sliders never move.

extension SimConfig.Ranges {
    static let weatherStrength: ClosedRange<Double> = 0.25...2
}

/// The kinds of weather the living weather moves between.
enum WeatherPhase: String, CaseIterable, Sendable {
    case flurry, steady, heavy, blizzard, clear, coldSnap, thaw

    var title: String {
        switch self {
        case .flurry: String(localized: "Light flurry")
        case .steady: String(localized: "Steady snow")
        case .heavy: String(localized: "Heavy snow")
        case .blizzard: String(localized: "Blizzard")
        case .clear: String(localized: "Clear spell")
        case .coldSnap: String(localized: "Cold snap")
        case .thaw: String(localized: "Thaw")
        }
    }

    /// What the phase does to the user's values at strength 1.
    var look: WeatherLook {
        switch self {
        //                         density wind  steady gusts fall  size  temp  thaw
        case .flurry:   WeatherLook(0.55, 0.7, 4, 0.10, 0.9, 0.85, 1, 0)
        case .steady:   WeatherLook(1.1, 1.0, 8, 0.20, 1.0, 1.0, 0, 0)
        case .heavy:    WeatherLook(2.2, 1.25, 18, 0.50, 1.1, 1.15, -1.5, 0)
        case .blizzard: WeatherLook(3.2, 1.7, 55, 1.00, 1.35, 0.95, -4, 0)
        case .clear:    WeatherLook(0.03, 0.5, 3, 0.05, 1.0, 0.9, -2, 0)
        case .coldSnap: WeatherLook(0.7, 0.8, 10, 0.25, 0.9, 0.8, -6, 0)
        case .thaw:     WeatherLook(0.6, 0.8, 6, 0.15, 1.1, 1.25, 0, 1)
        }
    }

    /// How long the phase lasts, in minutes.
    var minutes: ClosedRange<Double> {
        switch self {
        case .blizzard: 8...18
        case .thaw: 8...15
        case .heavy: 10...25
        case .clear: 10...25
        default: 12...40
        }
    }

    /// Which phase may follow, with weights.
    var successors: [(WeatherPhase, Double)] {
        switch self {
        case .flurry: [(.steady, 4), (.clear, 1.5), (.heavy, 1.5), (.coldSnap, 1), (.thaw, 0.7)]
        case .steady: [(.flurry, 3), (.heavy, 3), (.clear, 1.5), (.coldSnap, 1), (.thaw, 0.7)]
        case .heavy: [(.blizzard, 2.5), (.steady, 3), (.flurry, 1)]
        case .blizzard: [(.heavy, 2), (.steady, 2), (.coldSnap, 1), (.clear, 1)]
        case .clear: [(.flurry, 3), (.steady, 2.5), (.coldSnap, 1.5)]
        case .coldSnap: [(.flurry, 2), (.steady, 2), (.clear, 2), (.heavy, 1)]
        case .thaw: [(.flurry, 2), (.steady, 2), (.clear, 1)]
        }
    }

    /// A short thaw only comes when the user's temperature is within a couple of degrees of zero.
    static func thawPossible(at userTemp: Double) -> Bool { (-2...3).contains(userTemp) }
}

/// Multipliers and offsets a phase applies to the user's values (blended during transitions).
struct WeatherLook: Sendable {
    var density, wind, steady, gusts, fall, size, temp, thaw: Double

    init(_ density: Double, _ wind: Double, _ steady: Double, _ gusts: Double,
         _ fall: Double, _ size: Double, _ temp: Double, _ thaw: Double) {
        self.density = density; self.wind = wind; self.steady = steady; self.gusts = gusts
        self.fall = fall; self.size = size; self.temp = temp; self.thaw = thaw
    }

    static func mix(_ a: WeatherLook, _ b: WeatherLook, _ t: Double) -> WeatherLook {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        // Multipliers blend geometrically, so a clear spell fades in as smoothly as a blizzard.
        func g(_ x: Double, _ y: Double) -> Double { exp(m(log(max(x, 1e-4)), log(max(y, 1e-4)))) }
        return WeatherLook(g(a.density, b.density), g(a.wind, b.wind), m(a.steady, b.steady), m(a.gusts, b.gusts),
                           g(a.fall, b.fall), g(a.size, b.size), m(a.temp, b.temp), m(a.thaw, b.thaw))
    }
}

/// The weather right now, as shown in the menu.
struct WeatherSummary: Equatable, Sendable {
    enum Wind: Equatable, Sendable { case calm, west, east, gustsWest, gustsEast }
    var phase: WeatherPhase
    var temperature: Double          // °C, whole degrees
    var wind: Wind

    /// "Now: Heavy snow · −7 °C · wind from the west"
    func text(fahrenheit: Bool) -> String {
        let windText = switch wind {
        case .calm: String(localized: "calm")
        case .west: String(localized: "wind from the west")
        case .east: String(localized: "wind from the east")
        case .gustsWest: String(localized: "gusts from the west")
        case .gustsEast: String(localized: "gusts from the east")
        }
        let t = Temp.format(temperature, fahrenheit: fahrenheit)
        return String(localized: "Now: \(phase.title) · \(t) · \(windText)")
    }
}

/// The shared weather state: a slow state machine over the phases, smooth noise on top and gusts.
/// Costs a few floats per poll; it never wakes anything by itself.
@MainActor @Observable
final class LivingWeather {
    /// Shown in the menu; only reassigned when the visible text would change.
    private(set) var summary: WeatherSummary?

    @ObservationIgnored private var rng: SplitMix
    @ObservationIgnored private var seed: UInt64
    @ObservationIgnored private var clock = 0.0               // weather seconds (fast-forwarded by `speed`)
    @ObservationIgnored private var lastNow: Double?
    @ObservationIgnored private let speed: Double
    @ObservationIgnored private let forced: WeatherPhase?
    @ObservationIgnored private(set) var phase: WeatherPhase
    @ObservationIgnored private var from: WeatherLook         // the previous phase's look (direction applied)
    @ObservationIgnored private var fromPhase: WeatherPhase
    @ObservationIgnored private var target: WeatherLook       // this phase's look (direction applied)
    @ObservationIgnored private var phaseStart = 0.0
    @ObservationIgnored private var phaseLength = 0.0
    @ObservationIgnored private var transition = 1.0
    @ObservationIgnored private var userTemp = -4.0
    // Gusts
    @ObservationIgnored private var gust = 0.0                // 0…1 envelope
    @ObservationIgnored private var gustGoal = 0.0
    @ObservationIgnored private var gustTimer = 3.0

    /// - Parameters:
    ///   - forced: keeps this phase forever (debugging, `ISNOW_WEATHER`).
    ///   - speed: weather time per real second (`ISNOW_WEATHER_SPEED`).
    init(forced: WeatherPhase? = nil, speed: Double = 1, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.seed = seed
        rng = SplitMix(seed)
        self.speed = speed.isFinite ? max(0, speed) : 1
        self.forced = forced
        let start = forced ?? .steady
        phase = start
        fromPhase = start
        from = start.look
        target = start.look
        if forced == nil {
            phaseLength = Double.random(in: 10...25, using: &rng) * 60
        } else {
            phaseLength = .infinity
            transition = 0.001
            let dir: Double = start == .blizzard || start == .heavy ? 1 : (Bool.random(using: &rng) ? 1 : -1)
            target.steady *= dir
            from = target
        }
    }

    /// A weather set up from `ISNOW_WEATHER=<phase>` and `ISNOW_WEATHER_SPEED=<factor>`.
    static func fromEnvironment(seed: UInt64? = nil) -> LivingWeather {
        let env = ProcessInfo.processInfo.environment
        let forced = env["ISNOW_WEATHER"].flatMap(phase(named:))
        let speed = env["ISNOW_WEATHER_SPEED"].flatMap(Double.init) ?? 1
        if let seed { return LivingWeather(forced: forced, speed: speed, seed: seed) }
        return LivingWeather(forced: forced, speed: speed)
    }

    static func phase(named s: String) -> WeatherPhase? {
        let k = s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        return WeatherPhase.allCases.first { $0.rawValue.lowercased() == k }
            ?? ["light": .flurry, "snow": .steady, "storm": .blizzard, "cold": .coldSnap, "sun": .clear][k]
    }

    /// Replaces the user's density, wind, temperature, fall speed and flake size in `c` with the
    /// effective values for this moment and fills in the runtime wind. `c` must hold the user's settings.
    func apply(to c: inout SimConfig, now: Double) {
        guard c.livingWeather else {
            lastNow = nil
            if summary != nil { summary = nil }
            return
        }
        let real = lastNow.map { max(0, now - $0) } ?? 0
        lastNow = now
        advance(min(real, 6 * 3600) * speed, userTemp: c.temperature)

        let s = c.weatherStrength.isFinite ? min(max(c.weatherStrength, 0.25), 2) : 1
        let look = current
        // Slow wiggles on top of the phase, so even a long phase keeps breathing.
        let nd = Self.noise(clock / 240, seed: seed)              // ~4 min
        let nt = Self.noise(clock / 600, seed: seed &+ 77)        // ~10 min
        let userWind = c.wind
        c.density = min(14, c.density * pow(look.density, s) * (1 + 0.22 * s * nd))
        c.wind = min(5, userWind * pow(look.wind, s))
        c.fallSpeed = min(3.5, c.fallSpeed * pow(look.fall, s))
        c.flakeSize = c.flakeSize * pow(look.size, s)
        var dt = look.temp * s + nt * 1.2 * s
        if look.thaw > 0 { dt += look.thaw * min(6, max(1, 2.5 - c.temperature)) }
        let temp = min(max(c.temperature + min(6, max(-6, dt)), SimConfig.Ranges.temperature.lowerBound),
                       SimConfig.Ranges.temperature.upperBound)
        // The weather never melts what the user's own temperature keeps frozen: at or below zero it stays at
        // or below zero (a "thaw" then shows as wet, heavy flakes), above zero a thaw is a mild one.
        c.temperature = c.temperature <= 0 ? min(temp, 0) : (look.thaw > 0 ? min(temp, max(c.temperature, 1.5)) : temp)
        // Steady wind in the phase's direction plus gusts (pt/s, + blows to the right = from the west).
        let gustSpeed = gust * (30 + 90 * look.gusts) * min(s, 1.5)
        let dir: Double = look.steady >= 0 ? 1 : -1
        c.weatherWind = min(260, max(-260, userWind * (look.steady * s + dir * gustSpeed)))
        c.weatherPowder = userWind < 0.05 ? 0 : min(1, gust * look.gusts * 1.6 * min(s, 1.3))

        let dominant = clock - phaseStart < transition * 0.5 ? fromPhase : phase
        let windKind: WeatherSummary.Wind
        if userWind < 0.05 || (abs(look.steady * s) * userWind < 2 && look.gusts < 0.3) {
            windKind = .calm
        } else if look.gusts * s >= 0.45 {
            windKind = dir > 0 ? .gustsWest : .gustsEast
        } else {
            windKind = dir > 0 ? .west : .east
        }
        let next = WeatherSummary(phase: dominant, temperature: temp.rounded(), wind: windKind)
        if summary != next { summary = next }
    }

    // MARK: State machine

    /// The look right now (blending from the previous phase during the transition).
    private var current: WeatherLook {
        let u = min(1, max(0, (clock - phaseStart) / transition))
        return WeatherLook.mix(from, target, u * u * (3 - 2 * u))
    }

    private func advance(_ dt: Double, userTemp: Double) {
        self.userTemp = userTemp
        clock += dt
        if forced == nil {
            // Long gaps (sleep, hidden effects) can pass several phases at once.
            var guardCount = 0
            while clock - phaseStart >= phaseLength && guardCount < 64 {
                guardCount += 1
                nextPhase(at: phaseStart + phaseLength)
            }
        }
        stepGusts(min(dt, 2))
    }

    private func nextPhase(at t: Double) {
        let was = WeatherLook.mix(from, target, 1)
        var options = phase.successors
        if !WeatherPhase.thawPossible(at: userTemp) { options.removeAll { $0.0 == .thaw } }
        let total = options.reduce(0) { $0 + $1.1 }
        var pick = Double.random(in: 0..<total, using: &rng)
        var next = options.first?.0 ?? .steady
        for (p, w) in options {
            if pick < w { next = p; break }
            pick -= w
        }
        fromPhase = phase
        from = was
        phase = next
        target = next.look
        // Prevailing westerlies: mostly from the west, a strong wind keeps its side.
        let keep = abs(was.steady) > 20 && Double.random(in: 0...1, using: &rng) < 0.7
        let dir: Double = keep ? (was.steady >= 0 ? 1 : -1) : (Double.random(in: 0...1, using: &rng) < 0.65 ? 1 : -1)
        target.steady *= dir
        phaseStart = t
        phaseLength = Double.random(in: next.minutes, using: &rng) * 60
        transition = Double.random(in: 120...300, using: &rng)
    }

    /// Gusts: come and go within seconds, more often and stronger the gustier the phase.
    private func stepGusts(_ dt: Double) {
        guard dt > 0 else { return }
        let gustiness = current.gusts
        gustTimer -= dt
        if gustTimer <= 0 {
            if gustGoal > 0 {
                gustGoal = 0
                gustTimer = Double.random(in: 3...9, using: &rng) / max(0.25, gustiness)
            } else if Double.random(in: 0...1, using: &rng) < gustiness {
                gustGoal = Double.random(in: 0.55...1, using: &rng)
                gustTimer = Double.random(in: 2...6, using: &rng)
            } else {
                gustTimer = Double.random(in: 4...12, using: &rng)
            }
        }
        let tau = gustGoal > gust ? 1.2 : 2.5
        gust += (gustGoal - gust) * min(1, dt / tau)
    }

    /// Debug: a full gust right now (snapshots, `ISNOW_GUST`).
    func holdGust() {
        gust = 1
        gustGoal = 1
        gustTimer = 5
    }

    // MARK: Noise

    /// Smooth value noise in −1…1.
    static func noise(_ t: Double, seed: UInt64) -> Double {
        let i = floor(t), f = t - i
        let u = f * f * (3 - 2 * f)
        func h(_ k: Double) -> Double {
            var x = UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15 ^ seed
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            x ^= x >> 31
            return Double(x >> 11) / Double(1 << 53) * 2 - 1
        }
        let a = h(i), b = h(i + 1)
        return a + (b - a) * u
    }

    // MARK: Self-check

    /// Debug: prints two simulated hours of weather (every 2 minutes) for the default settings, plus the
    /// share of time per phase and the average density over ten simulated days.
    static func printTrace(seed: UInt64 = 7) {
        let w = LivingWeather(seed: seed)
        var base = SimConfig()
        base.temperature = -2              // near zero, so a thaw may come
        print("  min  phase       density  wind  steady+gust  powder  temp  status")
        var t = 0.0
        let step = 2.0
        var next = 0.0
        while t <= 2 * 3600 {
            var c = base
            w.apply(to: &c, now: t)
            if t >= next {
                next += 120
                let s = w.summary?.text(fahrenheit: false) ?? "-"
                let name = w.phase.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
                print(String(format: "%5.0f  ", t / 60) + name + String(format: "  %6.2f  %5.2f  %10.1f  %6.2f  %5.1f  ",
                      c.density, c.wind, c.weatherWind, c.weatherPowder, c.temperature) + s)
            }
            t += step
        }
        var share: [WeatherPhase: Double] = [:]
        var dens = 0.0, n = 0.0, tMin = 99.0, tMax = -99.0, windMax = 0.0
        while t <= 242 * 3600 {
            var c = base
            w.apply(to: &c, now: t)
            share[w.phase, default: 0] += 10
            dens += c.density; n += 1
            tMin = min(tMin, c.temperature); tMax = max(tMax, c.temperature); windMax = max(windMax, abs(c.weatherWind))
            t += 10
        }
        print("240 h: average density \(String(format: "%.2f", dens / n)) (user \(base.density)),",
              "temperature " + String(format: "%.1f…%.1f", tMin, tMax) + " (user \(base.temperature)), max wind \(Int(windMax)) pt/s")
        for p in WeatherPhase.allCases {
            print("  " + p.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
                  + String(format: " %4.1f %%", (share[p] ?? 0) / (240 * 36)))
        }
    }
}

/// Small deterministic generator (the weather is reproducible for a given seed).
struct SplitMix: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
