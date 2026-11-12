import AppKit
import ServiceManagement
import SwiftUI

private typealias R = SimConfig.Ranges

struct SettingsView: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate
    @State private var tab: Int
    private let activates: Bool

    init(settings: Settings, delegate: AppDelegate, tab: Int = 0, activates: Bool = true) {
        self.settings = settings
        self.delegate = delegate
        _tab = State(initialValue: tab)
        self.activates = activates
    }

    var body: some View {
        TabView(selection: $tab) {
            SnowTab(settings: settings).tabItem { Label("Snowfall", systemImage: "cloud.snow") }.tag(0)
            DriftTab(settings: settings, delegate: delegate).tabItem { Label("Drifts", systemImage: "mountain.2") }.tag(1)
            SnowmanTab(settings: settings, delegate: delegate).tabItem { Label("Snowman", systemImage: "figure.wave") }.tag(2)
            ChristmasTab(settings: settings, delegate: delegate).tabItem { Label("Christmas", systemImage: "gift") }.tag(3)
            ExtrasTab(settings: settings, delegate: delegate).tabItem { Label("Other", systemImage: "sparkles") }.tag(4)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag(5)
        }
        .frame(width: 500)
        .onAppear {
            settings.refreshLoginStatus()
            guard activates else { return }
            NSApp.activate()
            DispatchQueue.main.async { NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil) }
        }
        // The login item can be approved or removed in System Settings while the window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLoginStatus()
        }
    }
}

/// Slider with a label and a value readout.
private struct ValueSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}

/// "1.5×" / "1,5×" – the decimal separator follows the locale.
private func times(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) + "×" }
private func points(_ v: Double) -> String { String(localized: "\(Int(v.rounded())) pt") }
private func count(_ v: Double) -> String { Int(v.rounded()).formatted() }

private struct SnowTab: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: Binding<Intensity?>(
                    get: { settings.config.preset },
                    set: { if let p = $0 { settings.config.apply(p) } })) {
                    ForEach(Intensity.allCases) { Text($0.title).tag(Optional($0)) }
                    if settings.config.preset == nil { Text("Custom").tag(Intensity?.none) }
                }
                .pickerStyle(.segmented)
                ValueSlider(title: "Snowfall density", value: $settings.config.density, range: R.density, format: times)
                ValueSlider(title: "Max flakes", value: $settings.config.maxFlakes, range: R.maxFlakes, step: 50, format: count)
                if settings.config.maxFlakes > 2500 {
                    Text("Thousands of flakes cost more CPU – 30 fps on the Other tab helps.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Temperature") {
                ValueSlider(title: "Temperature", value: temperatureBinding, range: temperatureRange, step: 1) {
                    Temp.format(fahrenheit ? Temp.toCelsius($0) : $0, fahrenheit: fahrenheit)
                }
                Text(temperatureHint)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Flakes") {
                ValueSlider(title: "Size", value: $settings.config.flakeSize, range: R.flakeSize, format: times)
                ValueSlider(title: "Fall speed", value: $settings.config.fallSpeed, range: R.fallSpeed, format: times)
                ValueSlider(title: "Wind", value: $settings.config.wind, range: R.wind) {
                    $0 < 0.05 ? String(localized: "calm") : times($0)
                }
                Toggle("Sparkling flakes", isOn: $settings.config.sparkle)
                Toggle("Calm snow over the active window", isOn: $settings.config.calmActive)
                Text("Flakes fade to a light dusting over the window you're working in.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    ColorPicker("Snow color", selection: tintBinding, supportsOpacity: false)
                    Button("White") { settings.config.tint = [1, 1, 1] }
                        .disabled(settings.config.tint == [1, 1, 1])
                }
            }
        }
        .formStyle(.grouped)
    }

    private var fahrenheit: Bool { settings.config.fahrenheit }

    /// The slider works in °C or °F; the config always stores °C (same physical range).
    private var temperatureRange: ClosedRange<Double> {
        let r = R.temperature
        return fahrenheit ? Temp.toFahrenheit(r.lowerBound)...Temp.toFahrenheit(r.upperBound) : r
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: {
                let c = settings.config.temperature
                return fahrenheit ? Temp.toFahrenheit(c).rounded() : c
            },
            set: { v in
                let c = fahrenheit ? Temp.toCelsius(v) : v
                settings.config.temperature = min(max(c, R.temperature.lowerBound), R.temperature.upperBound)
            })
    }

    private var temperatureHint: String {
        let t = settings.config.temperature
        if t > 4 { return String(localized: "Sleet: nothing settles – drifts, icicles and snowmen melt fast.") }
        if t > 0 { return String(localized: "Thaw: wet snow – drifts and icicles melt fast and snowmen shrink.") }
        if t > -8 { return String(localized: "Freezing: nothing melts, icicles grow and windows start to frost over. The snowplow keeps the bottom clear.") }
        return String(localized: "Hard frost: icicles grow fast and windows freeze over from the corners.")
    }

    private var tintBinding: Binding<Color> {
        Binding(
            get: {
                let t = settings.config.tint
                return Color(red: t[safe: 0] ?? 1, green: t[safe: 1] ?? 1, blue: t[safe: 2] ?? 1)
            },
            set: { c in
                guard let n = NSColor(c).usingColorSpace(.sRGB) else { return }
                settings.config.tint = [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)]
            })
    }
}

private struct DriftTab: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate

    var body: some View {
        Form {
            Section("Where snow settles") {
                Toggle("On windows", isOn: $settings.config.onWindows)
                Toggle("On the Dock", isOn: $settings.config.onDock)
                Toggle("On desktop icons", isOn: $settings.config.onIcons)
                Toggle("On desktop widgets", isOn: $settings.config.onWidgets)
                if !settings.config.onWidgets {
                    Text("Snow falls straight through desktop widgets.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("On the menu bar", isOn: $settings.config.onMenuBar)
                if !settings.axTrusted {
                    HStack {
                        Text("The Dock and desktop icons need Accessibility permission.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow…") { Tracker.requestAccessibility() }
                    }
                }
            }
            Section("Drifts") {
                Toggle("Unlimited – snow keeps piling up into hills", isOn: $settings.config.unlimitedDrifts)
                ValueSlider(title: "Height on windows", value: $settings.config.windowDepth, range: R.windowDepth, format: points)
                    .disabled(settings.config.unlimitedDrifts)
                ValueSlider(title: "Height at the bottom edge", value: $settings.config.groundDepth, range: R.groundDepth, format: points)
                    .disabled(settings.config.unlimitedDrifts)
                ValueSlider(title: "Pile-up speed", value: $settings.config.accumulation, range: R.accumulation, format: times)
                HStack {
                    Spacer()
                    Button("Shake Off All Snow") { delegate.shakeAll() }
                }
            }
            Section("Ice") {
                Toggle("Windows frost over when it is below zero", isOn: $settings.config.windowFrost)
                Toggle("Icicles under windows and the menu bar", isOn: $settings.config.icicles)
                ValueSlider(title: "Icicle length", value: $settings.config.icicleLength, range: R.icicleLength, format: times)
                    .disabled(!settings.config.icicles)
                Text("Melting and frost follow the temperature on the Snowfall tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SnowmanTab: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate

    var body: some View {
        Form {
            Section {
                Toggle("Build snowmen on the Dock", isOn: $settings.config.snowman)
                ValueSlider(title: "Number of snowmen", value: $settings.config.snowmanCount, range: R.snowmanCount, step: 1,
                            format: count)
                ValueSlider(title: "Size", value: $settings.config.snowmanSize, range: R.snowmanSize, format: times)
                ValueSlider(title: "Break between snowmen", value: $settings.config.snowmanBreak, range: R.snowmanBreak) {
                    $0 < 1 ? String(localized: "\(Int($0 * 60)) s") : String(localized: "\(Int($0.rounded())) min")
                }
                Toggle("Fade a snowman that covers a window", isOn: $settings.config.snowmanGhost)
                HStack {
                    Spacer()
                    Button("Back to the Dock") { delegate.resetSnowmen() }
                    Button("Build Now") { delegate.buildSnowmanNow() }
                }
                Text("Drag a snowman with the mouse to put it on a window or anywhere else. If the window moves, it falls.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!settings.config.snowman)
            Section("Snowball fight") {
                Toggle("The snowman throws snowballs at windows and icons", isOn: $settings.config.snowballs)
                ValueSlider(title: "Throws roughly every", value: $settings.config.throwEvery, range: R.throwEvery) {
                    String(localized: "\(Int($0)) s")
                }
                .disabled(!settings.config.snowballs)
                Text("Click the snowman – every third hit knocks off a level. Sometimes it fights back.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!settings.config.snowman)
            Section("Skiers") {
                Toggle("Skiers ride along the snow at the bottom now and then", isOn: $settings.config.skier)
                ValueSlider(title: "Come roughly every", value: $settings.config.skierInterval, range: R.skierEvery, step: 0.5) {
                    $0 < 1 ? String(localized: "\(Int(($0 * 60).rounded())) s")
                           : ($0.truncatingRemainder(dividingBy: 1) == 0 ? String(localized: "\(Int($0)) min")
                                                                          : $0.formatted(.number.precision(.fractionLength(1))) + " min")
                }
                .disabled(!settings.config.skier)
                ValueSlider(title: "Skiers at once", value: $settings.config.skierCount, range: 1...5, step: 1) {
                    "\(Int($0))"
                }
                .disabled(!settings.config.skier)
                HStack {
                    Spacer()
                    Button("Send Skiers Now") { delegate.sendSkier() }
                }
                Text("They ski along the bottom of the screen, jump up onto the Dock, ride across it and jump off the other end.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ChristmasTab: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate

    var body: some View {
        Form {
            Section {
                Toggle("Christmas mode", isOn: $settings.config.christmas)
            }
            Section("Decorations") {
                Toggle("Christmas tree next to the Dock", isOn: $settings.config.christmasTree)
                ValueSlider(title: "Tree size", value: $settings.config.treeSize, range: R.treeSize, format: times)
                    .disabled(!settings.config.christmasTree)
                Toggle("String of lights under the menu bar", isOn: $settings.config.christmasGarland)
                Toggle("Santa hats on snowmen", isOn: $settings.config.christmasHats)
                Picker("Lights", selection: $settings.config.lightStyle) {
                    Text("Colorful, twinkling").tag(Christmas.LightStyle.colorful.rawValue)
                    Text("Warm white").tag(Christmas.LightStyle.warmWhite.rawValue)
                    Text("Chasing").tag(Christmas.LightStyle.chase.rawValue)
                }
                ValueSlider(title: "Light size", value: $settings.config.lightSize, range: 0.5...2.5, format: times)
                ValueSlider(title: "Brightness", value: $settings.config.lightGlow, range: 0...2.5) {
                    $0 < 0.02 ? String(localized: "no glow") : times($0)
                }
                Toggle("Keep the lights twinkling while the snow is paused", isOn: $settings.config.lightsWhilePaused)
                Text("Costs a little power.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!settings.config.christmas)
            Section("Santa") {
                Toggle("Santa flies by now and then", isOn: $settings.config.santa)
                HStack {
                    Spacer()
                    Button("Send Santa Now") { delegate.launchSanta() }
                }
            }
            .disabled(!settings.config.christmas)
        }
        .formStyle(.grouped)
    }
}

struct AboutTab: View {
    /// Version shown when there is no app bundle (screenshots rendered from `swift build`).
    @MainActor static var fallbackVersion = "–"
    private static let website = URL(string: "https://filiphajduch.dev/apps/isnow/")!
    private static let repo = URL(string: "https://github.com/filiphajduch420/iSnow")!
    private static let releases = URL(string: "https://github.com/filiphajduch420/iSnow/releases")!
    private static let authorSite = URL(string: "https://filiphajduch.dev/en/")!
    private static let authorGitHub = URL(string: "https://github.com/filiphajduch420")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? Self.fallbackVersion
        let build = info?["CFBundleVersion"] as? String
        return build == nil || build == short ? short : "\(short) (\(build!))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "iSnow").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary).textSelection(.enabled)
                        Text("It snows on your Mac.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("App") {
                LabeledContent("Website") { Link("filiphajduch.dev/apps/isnow", destination: Self.website) }
                LabeledContent("Source code") { Link("github.com/filiphajduch420/iSnow", destination: Self.repo) }
                LabeledContent("Updates") { Link("Releases on GitHub", destination: Self.releases) }
            }
            Section("Author") {
                LabeledContent("Made by") { Text(verbatim: "Filip Hajduch") }
                LabeledContent("Website") { Link("filiphajduch.dev", destination: Self.authorSite) }
                LabeledContent("GitHub") { Link("@filiphajduch420", destination: Self.authorGitHub) }
            }
            Section {
                Text("Free and open source under the MIT License.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtrasTab: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate

    var body: some View {
        Form {
            Section("Extras") {
                Toggle("The cursor scatters flakes and a quick swipe brushes snow off", isOn: $settings.config.mouse)
                Text("Hold ⌥ Option to get a shovel at the cursor and clear away the snow it touches – even at the bottom of the screen and on the Dock. Snowmen can be dragged with the mouse.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("A snowplow clears the snow at the bottom by itself", isOn: $settings.config.snowplow)
                Text("It drives across the whole screen – over the Dock too – whenever the snow at the bottom gets deep.")
                    .font(.callout).foregroundStyle(.secondary)
                ValueSlider(title: "Comes when the snow at the bottom reaches", value: $settings.config.autoPlowHeight, range: 10...150, step: 5) {
                    String(localized: "\(Int($0)) pt")
                }
                .disabled(!settings.config.snowplow)
                HStack {
                    Spacer()
                    Button("Send the Snowplow Now") { delegate.sendPlow() }
                        .disabled(!settings.config.snowplow)
                }
                Toggle("Frosted screen edges", isOn: $settings.config.frost)
                ValueSlider(title: "Snow over full-screen apps", value: $settings.config.fullscreenSnow, range: 0...1, step: 0.05) {
                    $0 < 0.02 ? String(localized: "none") : ($0.formatted(.percent.precision(.fractionLength(0))))
                }
                Text("In full screen only the falling snow (faded) and the icicles at the top stay – drifts, snowmen and the tree hide, and everything is back when you leave full screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Performance") {
                Picker("Frame rate", selection: $settings.config.fps) {
                    Text("30 fps (power saving)").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps (ProMotion)").tag(120)
                }
                Toggle("Draw calm snowfall at 30 fps (saves power)", isOn: $settings.config.calmLowerRate)
                Text("Low Power Mode always caps the frame rate at 30 fps. When nothing is falling, rendering stops.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Sharp Retina rendering (uses more power)", isOn: $settings.config.retina)
            }
            Section("Battery") {
                Toggle("Save power on battery", isOn: $settings.config.batterySaver)
                Text("On battery: 30 fps, standard resolution, fewer flakes, no sparkle.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                       set: { settings.setLaunchAtLogin($0) }))
                if settings.loginStatus == .requiresApproval || settings.loginError != nil {
                    HStack {
                        Group {
                            if let error = settings.loginError {
                                Text(error)
                            } else {
                                Text("Allow iSnow in System Settings → General → Login Items to finish.")
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Use Fahrenheit", isOn: $settings.config.fahrenheit)
                Toggle("Hide the snow from screenshots and screen sharing", isOn: $settings.config.hideFromCapture)
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
