import Foundation
import Observation
import ServiceManagement

/// Rychlé předvolby intenzity (nastaví hustotu, počet vloček a vítr).
enum Intensity: Int, CaseIterable, Identifiable, Sendable {
    case light, normal, blizzard, storm
    var id: Int { rawValue }
    var title: String { ["Poprašek", "Normální", "Vánice", "Kalamita"][rawValue] }
    var density: Double { [0.35, 1.0, 3.2, 6.5][rawValue] }
    var maxFlakes: Double { [250, 700, 2000, 4000][rawValue] }
    var wind: Double { [0.6, 1.0, 1.6, 2.6][rawValue] }
}

/// Všechna nastavení simulace. Ukládá se jako JSON; chybějící klíče se doplní výchozími hodnotami.
struct SimConfig: Codable, Equatable, Sendable {
    // Sněžení
    var density: Double = 1.0          // násobek 28 vloček/s na 1000 bodů šířky
    var maxFlakes: Double = 700
    var flakeSize: Double = 1.0
    var fallSpeed: Double = 1.0
    var wind: Double = 1.0
    var sparkle: Bool = false
    var tint: [Double] = [1, 1, 1]
    // Závěje
    var onWindows = true
    var onDock = true
    var onIcons = true
    var onMenuBar = true
    var windowDepth: Double = 36       // max. výška závěje na okně v bodech
    var groundDepth: Double = 34
    var accumulation: Double = 3.5     // rychlost přibývání
    var melt: Double = 0               // bodů za minutu
    var icicles = true
    var icicleLength: Double = 1.0
    // Sněhulák
    var snowman = true
    var snowmanSize: Double = 1.3
    var snowmanBreak: Double = 2.0     // minut mezi sněhuláky
    var snowballs = true
    var throwEvery: Double = 30        // sekund
    // Ostatní
    var mouse = true
    var frost = false
    var pauseFullscreen = true
    var fps: Int = 60
    // Za běhu (neukládá se)
    var paused = false

    private enum CodingKeys: String, CodingKey {
        case density, maxFlakes, flakeSize, fallSpeed, wind, sparkle, tint, onWindows, onDock, onIcons, onMenuBar,
             windowDepth, groundDepth, accumulation, melt, icicles, icicleLength, snowman, snowmanSize,
             snowmanBreak, snowballs, throwEvery, mouse, frost, pauseFullscreen, fps
    }

    var preset: Intensity? {
        Intensity.allCases.first { abs($0.density - density) < 0.01 && abs($0.maxFlakes - maxFlakes) < 1 }
    }

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

    /// Má aplikace oprávnění Zpřístupnění (Dock a ikony plochy).
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
        // Posuvníky mění hodnotu plynule – ukládáme se zpožděním.
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
            NSLog("Vločka: přihlášení – \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
