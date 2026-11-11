import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    let delegate: AppDelegate

    var body: some View {
        TabView {
            SnowTab(settings: settings).tabItem { Label("Sněžení", systemImage: "cloud.snow") }
            DriftTab(settings: settings, delegate: delegate).tabItem { Label("Závěje", systemImage: "mountain.2") }
            SnowmanTab(settings: settings, delegate: delegate).tabItem { Label("Sněhulák", systemImage: "figure.wave") }
            ExtrasTab(settings: settings).tabItem { Label("Ostatní", systemImage: "sparkles") }
        }
        .frame(width: 500)
        .onAppear {
            NSApp.activate()
            DispatchQueue.main.async { NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil) }
        }
    }
}

/// Posuvník s popiskem a hodnotou.
private struct ValueSlider: View {
    let title: String
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
                    .frame(width: 70, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}

private func times(_ v: Double) -> String { String(format: "%.1f×", v) }
private func pt(_ v: Double) -> String { "\(Int(v.rounded())) b" }

private struct SnowTab: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("Předvolba", selection: Binding<Intensity?>(
                    get: { settings.config.preset },
                    set: { if let p = $0 { settings.config.apply(p) } })) {
                    ForEach(Intensity.allCases) { Text($0.title).tag(Optional($0)) }
                    if settings.config.preset == nil { Text("Vlastní").tag(Intensity?.none) }
                }
                .pickerStyle(.segmented)
                ValueSlider(title: "Hustota sněžení", value: $settings.config.density, range: 0.1...10, format: times)
                ValueSlider(title: "Max. počet vloček", value: $settings.config.maxFlakes, range: 50...6000, step: 50) {
                    "\(Int($0))"
                }
            }
            Section("Vločky") {
                ValueSlider(title: "Velikost", value: $settings.config.flakeSize, range: 0.4...3, format: times)
                ValueSlider(title: "Rychlost padání", value: $settings.config.fallSpeed, range: 0.2...3, format: times)
                ValueSlider(title: "Vítr", value: $settings.config.wind, range: 0...4) { $0 < 0.05 ? "bezvětří" : times($0) }
                Toggle("Třpytivé vločky", isOn: $settings.config.sparkle)
                HStack {
                    ColorPicker("Barva sněhu", selection: tintBinding, supportsOpacity: false)
                    Button("Bílá") { settings.config.tint = [1, 1, 1] }
                        .disabled(settings.config.tint == [1, 1, 1])
                }
            }
        }
        .formStyle(.grouped)
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
            Section("Kde se sníh drží") {
                Toggle("Na oknech", isOn: $settings.config.onWindows)
                Toggle("Na Docku", isOn: $settings.config.onDock)
                Toggle("Na ikonách plochy", isOn: $settings.config.onIcons)
                Toggle("Na liště menu", isOn: $settings.config.onMenuBar)
                if !settings.axTrusted {
                    HStack {
                        Text("Dock a ikony potřebují oprávnění Zpřístupnění.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Povolit…") { Tracker.requestAccessibility() }
                    }
                }
            }
            Section("Závěje") {
                ValueSlider(title: "Výška na oknech", value: $settings.config.windowDepth, range: 4...90, format: pt)
                ValueSlider(title: "Výška u spodního okraje", value: $settings.config.groundDepth, range: 4...120, format: pt)
                ValueSlider(title: "Rychlost přibývání", value: $settings.config.accumulation, range: 0.3...8, format: times)
                ValueSlider(title: "Tání", value: $settings.config.melt, range: 0...30) {
                    $0 < 0.1 ? "netaje" : String(format: "%.0f b/min", $0)
                }
                HStack {
                    Spacer()
                    Button("Setřást všechen sníh") { delegate.shakeAll() }
                }
            }
            Section("Rampouchy") {
                Toggle("Rampouchy pod okny a lištou menu", isOn: $settings.config.icicles)
                ValueSlider(title: "Délka", value: $settings.config.icicleLength, range: 0.3...3, format: times)
                    .disabled(!settings.config.icicles)
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
                Toggle("Stavět sněhuláka na Docku", isOn: $settings.config.snowman)
                ValueSlider(title: "Velikost", value: $settings.config.snowmanSize, range: 0.5...3.5, format: times)
                ValueSlider(title: "Pauza mezi sněhuláky", value: $settings.config.snowmanBreak, range: 0.2...20) {
                    $0 < 1 ? "\(Int($0 * 60)) s" : String(format: "%.0f min", $0)
                }
                HStack {
                    Spacer()
                    Button("Postavit hned") { delegate.buildSnowmanNow() }
                }
            }
            .disabled(!settings.config.snowman)
            Section("Koulovačka") {
                Toggle("Sněhulák hází koule na okna a ikony", isOn: $settings.config.snowballs)
                ValueSlider(title: "Hází zhruba každých", value: $settings.config.throwEvery, range: 3...180) {
                    "\(Int($0)) s"
                }
                .disabled(!settings.config.snowballs)
                Text("Klikni na sněhuláka – každý třetí zásah shodí jedno patro. Někdy se brání.")
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
            Section("Vychytávky") {
                Toggle("Kurzor rozhání vločky a rychlým tahem shrnuje sníh", isOn: $settings.config.mouse)
                Toggle("Ojíněné okraje obrazovky", isOn: $settings.config.frost)
                Toggle("Nesněžit přes aplikace na celé obrazovce", isOn: $settings.config.pauseFullscreen)
            }
            Section("Výkon") {
                Picker("Snímková frekvence", selection: $settings.config.fps) {
                    Text("30 fps (úsporné)").tag(30)
                    Text("60 fps").tag(60)
                    Text("120 fps (ProMotion)").tag(120)
                }
                Text("V režimu nízké spotřeby se frekvence vždy sníží na 30 fps. Když nesněží, vykreslování stojí.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Obecné") {
                Toggle("Spouštět po přihlášení", isOn: Binding(get: { settings.launchAtLogin },
                                                              set: { settings.setLaunchAtLogin($0) }))
                HStack {
                    Spacer()
                    Button("Obnovit výchozí nastavení") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
