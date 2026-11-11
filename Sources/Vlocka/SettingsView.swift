import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate

    var body: some View {
        TabView {
            SnowTab(settings: settings).tabItem { Label("Snowfall", systemImage: "cloud.snow") }
            DriftTab(settings: settings, delegate: delegate).tabItem { Label("Drifts", systemImage: "mountain.2") }
            SnowmanTab(settings: settings, delegate: delegate).tabItem { Label("Snowman", systemImage: "figure.wave") }
            ExtrasTab(settings: settings).tabItem { Label("Other", systemImage: "sparkles") }
        }
        .frame(width: 500)
        .onAppear {
            NSApp.activate()
            DispatchQueue.main.async { NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil) }
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

private func times(_ v: Double) -> String { String(format: "%.1f×", v) }
private func points(_ v: Double) -> String { String(localized: "\(Int(v.rounded())) pt") }

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
                ValueSlider(title: "Snowfall density", value: $settings.config.density, range: 0.1...10, format: times)
                ValueSlider(title: "Max flakes", value: $settings.config.maxFlakes, range: 50...6000, step: 50) {
                    "\(Int($0))"
                }
                if settings.config.maxFlakes > 2500 {
                    Text("Thousands of flakes cost more CPU – 30 fps on the Other tab helps.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Temperature") {
                ValueSlider(title: "Temperature", value: $settings.config.temperature, range: -25...10, step: 1) {
                    String(format: "%+.0f °C", $0)
                }
                Text(temperatureHint)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Flakes") {
                ValueSlider(title: "Size", value: $settings.config.flakeSize, range: 0.4...3, format: times)
                ValueSlider(title: "Fall speed", value: $settings.config.fallSpeed, range: 0.2...3, format: times)
                ValueSlider(title: "Wind", value: $settings.config.wind, range: 0...4) {
                    $0 < 0.05 ? String(localized: "calm") : times($0)
                }
                Toggle("Sparkling flakes", isOn: $settings.config.sparkle)
                HStack {
                    ColorPicker("Snow color", selection: tintBinding, supportsOpacity: false)
                    Button("White") { settings.config.tint = [1, 1, 1] }
                        .disabled(settings.config.tint == [1, 1, 1])
                }
            }
        }
        .formStyle(.grouped)
    }

    private var temperatureHint: String {
        let t = settings.config.temperature
        if t > 4 { return String(localized: "Sleet: nothing settles, drifts, icicles and snowmen melt quickly.") }
        if t > 0 { return String(localized: "Thaw: wet snow, drifts and icicles slowly melt and snowmen shrink.") }
        if t > -8 { return String(localized: "Freezing: nothing melts, icicles grow and windows start to frost over.") }
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
                ValueSlider(title: "Height on windows", value: $settings.config.windowDepth, range: 4...90, format: points)
                ValueSlider(title: "Height at the bottom edge", value: $settings.config.groundDepth, range: 4...120, format: points)
                ValueSlider(title: "Pile-up speed", value: $settings.config.accumulation, range: 0.3...8, format: times)
                HStack {
                    Spacer()
                    Button("Shake Off All Snow") { delegate.shakeAll() }
                }
            }
            Section("Ice") {
                Toggle("Windows frost over when it is below zero", isOn: $settings.config.windowFrost)
                Toggle("Icicles under windows and the menu bar", isOn: $settings.config.icicles)
                ValueSlider(title: "Icicle length", value: $settings.config.icicleLength, range: 0.3...3, format: times)
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
                ValueSlider(title: "Number of snowmen", value: $settings.config.snowmanCount, range: 1...6, step: 1) {
                    "\(Int($0))"
                }
                ValueSlider(title: "Size", value: $settings.config.snowmanSize, range: 0.5...3.5, format: times)
                ValueSlider(title: "Break between snowmen", value: $settings.config.snowmanBreak, range: 0.2...20) {
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
                ValueSlider(title: "Throws roughly every", value: $settings.config.throwEvery, range: 3...180) {
                    String(localized: "\(Int($0)) s")
                }
                .disabled(!settings.config.snowballs)
                Text("Click the snowman – every third hit knocks off a level. Sometimes it fights back.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!settings.config.snowman)
        }
        .formStyle(.grouped)
    }
}

private struct ExtrasTab: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section("Extras") {
                Toggle("The cursor scatters flakes and a quick swipe brushes snow off", isOn: $settings.config.mouse)
                Toggle("Frosted screen edges", isOn: $settings.config.frost)
                Toggle("Don't snow over full-screen apps", isOn: $settings.config.pauseFullscreen)
            }
            Section("Performance") {
                Picker("Frame rate", selection: $settings.config.fps) {
                    Text("30 fps (power saving)").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps (ProMotion)").tag(120)
                }
                Text("Low Power Mode always caps the frame rate at 30 fps. When nothing is falling, rendering stops.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                       set: { settings.setLaunchAtLogin($0) }))
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
