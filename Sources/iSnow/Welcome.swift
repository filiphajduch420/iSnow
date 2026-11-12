import AppKit
import SwiftUI

// The welcome window: shown once on the first launch of a fresh install (and once as "New in 1.3" for
// users who upgrade), reopened from the menu with "Things to Try…".
//
// UserDefaults keys:
//   welcomeSeen  String    the welcome version last shown ("1.3"); missing = never shown
//   welcomeTips  [String]  the Things to Try the user has really done (`Tip` raw values)

/// Something worth trying that iSnow notices when the user really does it.
enum Tip: String, CaseIterable, Sendable {
    case shovel, dragSnowman, clickSnowman, dragWindow, temperature, christmas

    var title: LocalizedStringKey {
        switch self {
        case .shovel: "Hold ⌥ Option and sweep snow away"
        case .dragSnowman: "Drag a snowman"
        case .clickSnowman: "Click a snowman"
        case .dragWindow: "Drag a window with snow on it"
        case .temperature: "Try the temperature slider"
        case .christmas: "Turn on Christmas mode"
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .shovel: "A shovel appears at the cursor – it clears the Dock too."
        case .dragSnowman: "Put it on a window. If the window moves, it falls."
        case .clickSnowman: "Every third hit knocks off a level."
        case .dragWindow: "The whole drift slides off and falls apart."
        case .temperature: "Thaw, sleet or a hard frost with icicles."
        case .christmas: "Lights, a tree, Santa hats – and Santa himself."
        }
    }
}

/// The ticked Things to Try. `mark` is called from the code paths that do the thing; it is a set lookup
/// once the item is ticked, so it may be called often.
@MainActor @Observable
final class Tips {
    static let shared = Tips()

    private(set) var done: Set<Tip>
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private var lastTemperature: Double?

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Welcome.tipsKey) ?? []
        done = Set(raw.compactMap(Tip.init(rawValue:)))
        persists = true
    }

    /// A throwaway instance for screenshots – never touches the saved list.
    init(preview: Set<Tip>) {
        done = preview
        persists = false
    }

    func mark(_ tip: Tip) {
        guard !done.contains(tip) else { return }
        done.insert(tip)
        guard persists else { return }
        UserDefaults.standard.set(Tip.allCases.filter { done.contains($0) }.map(\.rawValue), forKey: Welcome.tipsKey)
    }

    /// The settings changed (also called once at launch for the baseline): a new temperature,
    /// Christmas mode turned on.
    func observe(_ c: SimConfig) {
        // Only a change the user makes counts – not the calendar switching Christmas mode on in December.
        if let m = lastChristmasMode, m != c.christmasMode, c.christmas { mark(.christmas) }
        lastChristmasMode = c.christmasMode
        if let t = lastTemperature, t != c.temperature { mark(.temperature) }
        lastTemperature = c.temperature
    }
    private var lastChristmasMode: Int?
}

@MainActor
enum Welcome {
    enum Mode { case welcome, whatsNew }

    static let seenKey = "welcomeSeen"
    static let tipsKey = "welcomeTips"
    /// Bump together with the "New in" list to show the What's New window once more after an update.
    static let version = "1.3"

    /// What's new in this version – informational, not ticked. Kept in one place so the texts are easy to fix.
    struct Newcomer: Identifiable {
        let id: Int
        let symbol: String
        let color: Color
        let title: LocalizedStringKey
        let hint: LocalizedStringKey
    }

    static var newcomers: [Newcomer] {
        [
            Newcomer(id: 0, symbol: "circle.circle.fill", color: .teal, title: "Roll your own snowman",
                     hint: "Hold ⌥ Option and ⇧ Shift and roll along the snow – stack three balls."),
            Newcomer(id: 1, symbol: "scope", color: .orange, title: "Throw snowballs back at the snowmen",
                     hint: "Hold ⌥ Option and click a snowman to throw one."),
            Newcomer(id: 2, symbol: "bird.fill", color: .indigo, title: "Watch for the penguin",
                     hint: "Now and then one waddles in along the snow."),
            Newcomer(id: 3, symbol: "cloud.sun.fill", color: .blue, title: "Living weather",
                     hint: "Snowfall, wind and temperature change on their own."),
            Newcomer(id: 4, symbol: "hare.fill", color: .brown, title: "A reindeer comes by at Christmas",
                     hint: "Keep an eye on your snowmen's carrots – sometimes it's Rudolph."),
            Newcomer(id: 5, symbol: "gift.fill", color: .red, title: "A whole new Christmas",
                     hint: "A snowy fir, glass bulbs, a gingerbread house – on its own from 1 December."),
        ]
    }

    private static var window: NSWindow?
    private static var host: NSHostingController<WelcomeView>?
    private static var closeObserver: NSObjectProtocol?

    /// The window to show on this launch: nil when this version's welcome was already shown.
    /// Call before anything else writes to UserDefaults on a first launch.
    static func modeAtLaunch() -> Mode? {
        let d = UserDefaults.standard
        let seen = d.string(forKey: seenKey)
        guard seen != version else { return nil }
        // Settings, an Accessibility answer or an older welcome: iSnow ran here before.
        let upgrade = seen != nil || d.data(forKey: "config") != nil
            || d.object(forKey: "askedAccessibility") != nil || d.object(forKey: "axGrantedOnce") != nil
        return upgrade ? .whatsNew : .welcome
    }

    /// Opens the window (or brings it to the front). `axLost`: macOS dropped the Accessibility permission –
    /// the window explains how to restore it instead of the separate alert.
    static func show(mode: Mode, axLost: Bool = false, delegate: AppDelegate) {
        UserDefaults.standard.set(version, forKey: seenKey)
        if let w = window, w.isVisible {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        release()
        let view = WelcomeView(mode: mode, settings: .shared, tips: .shared, axLost: axLost, live: true,
                               openSettings: { [weak delegate] in delegate?.showSettings() },
                               close: { window?.close() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = String(localized: "Welcome to iSnow")
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        Self.host = host
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            // Free the SwiftUI hierarchy once the window is gone (reopening builds a new one).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { releaseIfClosed() } }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private static func releaseIfClosed() {
        guard let w = window, !w.isVisible else { return }
        release()
    }

    private static func release() {
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        closeObserver = nil
        window?.contentViewController = nil
        window = nil
        host = nil
    }
}

// MARK: - The view

struct WelcomeView: View {
    let mode: Welcome.Mode
    @Bindable var settings: Settings
    let tips: Tips
    var axLost = false
    /// Polls the Accessibility permission while it is missing (off for screenshots).
    var live = true
    var openSettings: () -> Void = {}
    var close: () -> Void = {}

    /// The Accessibility step stays (as a green check) once granted while the window is open.
    @State private var asksAX: Bool

    init(mode: Welcome.Mode, settings: Settings, tips: Tips, axLost: Bool = false, live: Bool = true,
         openSettings: @escaping () -> Void = {}, close: @escaping () -> Void = {}) {
        self.mode = mode
        self.settings = settings
        self.tips = tips
        self.axLost = axLost
        self.live = live
        self.openSettings = openSettings
        self.close = close
        _asksAX = State(initialValue: axLost || !settings.axTrusted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if asksAX { accessibility }
            if mode == .whatsNew {
                newSection
                tipsSection
            } else {
                tipsSection
                newSection
            }
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)              // below the transparent title bar (its safe area)
        .padding(.bottom, 20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // The tracker notices a grant only every few seconds: look once a second while the window is open.
            guard live else { return }
            while !Task.isCancelled && !settings.axTrusted {
                try? await Task.sleep(for: .seconds(1))
                if AXIsProcessTrusted() { settings.axTrusted = true }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                if mode == .whatsNew {
                    Text("New in 1.3")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.accentColor)
                    Text("What's New in iSnow").font(.title2.weight(.semibold))
                    Text("A few new friends in the snow – and the tricks you may have missed.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Welcome to iSnow").font(.title2.weight(.semibold))
                    Text("It's snowing on your Mac. Here's how to play with it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    // MARK: Accessibility

    private var accessibility: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                if settings.axTrusted && !axLostNow {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20)).foregroundStyle(.green)
                        .frame(width: 24, height: 24)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    IconTile(symbol: "hand.raised.fill", color: .orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Snow on the Dock and Icons").font(.headline)
                    if settings.axTrusted && !axLostNow {
                        Text("Accessibility allowed – snow settles on the Dock and desktop icons.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if axLost {
                        Text("macOS stopped recognizing iSnow after the update.")
                        // The steps need the full width: the button goes below them.
                        VStack(alignment: .trailing, spacing: 8) {
                            Text("In Privacy & Security › Accessibility, remove iSnow with −, add it again with + and switch it on.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .fixedSize()
                        }
                    } else {
                        Text("Allow Accessibility so snow can settle on the Dock, desktop icons and the exact edges of windows.")
                        HStack(alignment: .bottom) {
                            Text("iSnow only reads where things are – never what's in them.")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Allow Accessibility…") { Tracker.requestAccessibility() }
                                .fixedSize()
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
        .animation(.spring(duration: 0.4), value: settings.axTrusted)
    }

    /// The lost permission is back once macOS trusts the app again.
    private var axLostNow: Bool { axLost && !settings.axTrusted }

    // MARK: Things to Try

    private var tipsSection: some View {
        let count = Tip.allCases.filter { tips.done.contains($0) }.count
        return Card(title: "Things to Try",
                    trailing: Text("\(count) of \(Tip.allCases.count)").monospacedDigit()) {
            ForEach(Array(Tip.allCases.enumerated()), id: \.element) { i, tip in
                if i > 0 { Divider().padding(.leading, 30) }
                TipRow(tip: tip, done: tips.done.contains(tip)) {
                    switch tip {
                    case .temperature:
                        Button("Settings…") { openSettings() }
                    case .christmas:
                        // Through Holidays, so the automatic Christmas mode doesn't switch it back off.
                        Button("Turn On") { Holidays.setChristmas(true, in: &settings.config) }
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: tips.done)
    }

    // MARK: New in 1.3

    private var newSection: some View {
        Card(title: mode == .whatsNew ? "New Friends in the Snow" : "New in 1.3") {
            if mode == .whatsNew {
                ForEach(Welcome.newcomers) { n in
                    if n.id > 0 { Divider().padding(.leading, 34) }
                    NewcomerView(newcomer: n).padding(.vertical, 6)
                }
            } else {
                // A compact two-column grid: for a new user these are just more things to discover.
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 0) {
                    ForEach(0..<(Welcome.newcomers.count / 2), id: \.self) { row in
                        if row > 0 { Divider() }
                        GridRow {
                            ForEach(Welcome.newcomers[(row * 2)..<(row * 2 + 2)]) { n in
                                NewcomerView(newcomer: n)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                       set: { settings.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Let It Snow") { close() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            if let error = settings.loginError {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }
}

/// A rounded group like a section of the settings window's grouped forms.
private struct Card<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var trailing: Text? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    if let trailing { trailing.font(.callout).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .quaternarySystemFill).opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        }
    }
}

private struct NewcomerView: View {
    let newcomer: Welcome.Newcomer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: newcomer.symbol, color: newcomer.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(newcomer.title)
                Text(newcomer.hint).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// A small coloured square with a white symbol, like the icons in System Settings.
private struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

private struct TipRow<Accessory: View>: View {
    let tip: Tip
    let done: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(tip.title)
                    .foregroundStyle(done ? .secondary : .primary)
                Text(tip.hint).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !done { accessory.controlSize(.small) }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Screenshots

extension Promo {
    /// Renders the welcome window (`welcome`), the What's New version (`welcome-new`) and What's New after
    /// macOS dropped the Accessibility permission (`welcome-lost`) to PNG.
    static func renderWelcome(dir: String, names: [String], done: @escaping () -> Void) {
        var cfg = SimConfig()
        cfg.christmas = false
        let preview = Settings(preview: cfg)
        preview.axTrusted = false
        if let icon = NSImage(contentsOfFile: "build/AppIcon.icns") { NSApp.applicationIconImage = icon }
        // name, mode, ticked items, Accessibility lost after the update
        let jobs: [(String, Welcome.Mode, Set<Tip>, Bool)] = [
            ("welcome", .welcome, [.shovel, .dragSnowman], false),
            ("welcome-new", .whatsNew, [.shovel, .dragSnowman, .clickSnowman, .temperature], false),
            ("welcome-lost", .whatsNew, [.shovel], true),
        ].filter { names.contains($0.0) }
        guard !jobs.isEmpty else { done(); return }
        var pending = jobs.count
        for (idx, (name, mode, ticked, lost)) in jobs.enumerated() {
            // The first-launch window asks for Accessibility; What's New has it (unless it was lost).
            let settings = mode == .welcome || lost ? preview : Settings(preview: cfg)
            let host = NSHostingView(rootView: WelcomeView(mode: mode, settings: settings, tips: Tips(preview: ticked),
                                                           axLost: lost, live: false)
                .environment(\.colorScheme, .light)
                .environment(\.controlActiveState, .key))
            host.appearance = NSAppearance(named: .aqua)
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: size)
            // A titled window that is key, so the default button is drawn in the accent color.
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered,
                               defer: false)
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            win.setFrameOrigin(CGPoint(x: -4000 - CGFloat(idx) * 700, y: -4000))
            NSApp.activate()
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let cg = rep.cgImage { composeWelcome(cg, size: host.bounds.size, path: "\(dir)/\(name).png") }
                }
                win.orderOut(nil)
                print("welcome \(name): \(Int(size.width))×\(Int(size.height)) pt")
                pending -= 1
                if pending == 0 { done() }
            }
        }
    }

    /// The welcome content in a window with a transparent title bar on a soft winter background.
    static func composeWelcome(_ content: CGImage, size s: CGSize, path: String) {
        let pad: CGFloat = 60
        let W = s.width + pad * 2, H = s.height + pad * 2
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        gradient(ctx, [rgb(0.16, 0.30, 0.58), rgb(0.48, 0.66, 0.88)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
        let r = CGRect(x: pad, y: pad, width: s.width, height: s.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: rgb(0, 0, 0, 0.4))
        ctx.addPath(rounded(ctx, r, 16))
        ctx.setFillColor(rgb(0.96, 0.96, 0.97))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rounded(ctx, r, 16))
        ctx.clip()
        ctx.draw(content, in: r)
        ctx.restoreGState()
        for (i, c) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: r.minX + 18 + CGFloat(i) * 20, y: r.maxY - 24, width: 12, height: 12))
        }
        Snapshot.savePNG(ctx.makeImage(), path)
    }
}
