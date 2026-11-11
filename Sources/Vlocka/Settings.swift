import Foundation
import Observation
import ServiceManagement

/// Quick intensity presets (set density, flake count and wind).
enum Intensity: Int, CaseIterable, Identifiable, Sendable {
    case light, normal, blizzard, storm
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .light: String(localized: "Flurry")
        case .normal: String(localized: "Normal")
        case .blizzard: String(localized: "Blizzard")
        case .storm: String(localized: "Snowstorm")
        }
    }
    var density: Double { [0.35, 1.0, 3.2, 6.5][rawValue] }
    var maxFlakes: Double { [250, 700, 2000, 4000][rawValue] }
    var wind: Double { [0.6, 1.0, 1.6, 2.6][rawValue] }
}

/// All simulation settings. Stored as JSON; missing keys fall back to defaults.
struct SimConfig: Codable, Equatable, Sendable {
    // Snowfall
    var density: Double = 1.0          // multiple of 28 flakes/s per 1000 pt of width
    var maxFlakes: Double = 700
    var flakeSize: Double = 1.0
    var fallSpeed: Double = 1.0
    var wind: Double = 1.0
    var sparkle: Bool = false
    var tint: [Double] = [1, 1, 1]
    // Drifts
    var onWindows = true
    var onDock = true
    var onIcons = true
    var onMenuBar = true
    var windowDepth: Double = 36       // max drift height on a window, in points
    var groundDepth: Double = 34
    var accumulation: Double = 3.5     // how fast snow piles up
    var temperature: Double = -4       // °C: above zero snow melts, below zero windows frost over
    var windowFrost = true
    var icicles = true
    var icicleLength: Double = 1.0
    // Snowman
    var snowman = true
    var snowmanSize: Double = 1.3
    var snowmanCount: Double = 1
    var snowmanGhost = true            // fade a snowman that covers a window
    var snowmanBreak: Double = 2.0     // minutes between snowmen
    var snowballs = true
    var throwEvery: Double = 30        // seconds
    // Other
    var mouse = true
    var frost = false
    var pauseFullscreen = true
    var fps: Int = 60
    // Runtime only (not persisted)
    var paused = false

    private enum CodingKeys: String, CodingKey {
        case density, maxFlakes, flakeSize, fallSpeed, wind, sparkle, tint, onWindows, onDock, onIcons, onMenuBar,
             windowDepth, groundDepth, accumulation, temperature, windowFrost, icicles, icicleLength, snowman,
             snowmanSize, snowmanCount, snowmanGhost,
             snowmanBreak, snowballs, throwEvery, mouse, frost, pauseFullscreen, fps
    }

    var preset: Intensity? {
        Intensity.allCases.first { abs($0.density - density) < 0.01 && abs($0.maxFlakes - maxFlakes) < 1 }
    }

    /// Melting speed in points per minute derived from the temperature.
    var meltRate: Float { temperature > 0 ? Float(temperature) * 2.5 : 0 }

    mutating func apply(_ p: Intensity) {
        density = p.density
        maxFlakes = p.maxFlakes
        wind = p.wind
    }

    static func load(from d: UserDefaults) -> SimConfig {
        guard let data = d.data(forKey: "config"),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(SimConfig()),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return SimConfig() }
        merged.merge(stored) { _, new in new }
        guard let out = try? JSONSerialization.data(withJSONObject: merged),
              let cfg = try? JSONDecoder().decode(SimConfig.self, from: out) else { return SimConfig() }
        return cfg
    }
}

@MainActor @Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var config: SimConfig {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            onChange?()
        }
    }

    var paused: Bool {
        get { config.paused }
        set { config.paused = newValue }
    }

    /// Whether the app has Accessibility permission (Dock and desktop icons).
    var axTrusted = false
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private init() {
        config = SimConfig.load(from: .standard)
    }

    func resetToDefaults() {
        let p = config.paused
        config = SimConfig()
        config.paused = p
    }

    private func scheduleSave() {
        // Sliders change values continuously – save with a short delay.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(self.config) {
                UserDefaults.standard.set(data, forKey: "config")
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Vločka: login item – \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
