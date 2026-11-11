import AppKit
import Metal
import SwiftUI

/// Renders the README screenshots without any screen-recording permission: a drawn winter desktop
/// (wallpaper, windows, widgets, Dock, menu bar) with iSnow's real simulation and renderer on top,
/// plus the settings window rendered from its SwiftUI view.
@MainActor
enum Promo {
    struct Scene {
        let name: String
        var temperature: Double = -6
        var seconds: Double = 140
        var christmas = false
        var snowmen = 3.0
        var frostEdges = false
        var sparkle = false
        var dragFrames = 0
        var finalDensity = 1.4
    }

    static let size = CGSize(width: 1440, height: 900)
    static let menuH: CGFloat = 32
    static let dock = CGRect(x: 372, y: 6, width: 696, height: 64)
    static let terminal = CGRect(x: 700, y: 170, width: 560, height: 360)
    static let notes = CGRect(x: 110, y: 290, width: 660, height: 450)
    static let widgetRects = [CGRect(x: 1262, y: 672, width: 158, height: 158), CGRect(x: 1262, y: 492, width: 158, height: 158)]

    static let scenes: [Scene] = [
        Scene(name: "hero"),
        Scene(name: "christmas", temperature: -4, seconds: 120, christmas: true, snowmen: 2),
        Scene(name: "slide", temperature: -5, seconds: 140, snowmen: 2, dragFrames: 9),
        Scene(name: "frost", temperature: -20, seconds: 200, snowmen: 1, frostEdges: true, sparkle: true, finalDensity: 2.2),
    ]

    static func run(dir: String, delegate: AppDelegate) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let renderer = Renderer() else { print("no metal"); exit(1) }
        for s in scenes {
            render(s, renderer: renderer, path: "\(dir)/\(s.name).png")
            print("scene \(s.name)")
        }
        renderSettings(dir: dir, delegate: delegate)
    }

    // MARK: Desktop scenes

    static func render(_ scene: Scene, renderer: Renderer, path: String) {
        let screen = CGRect(origin: .zero, size: size)
        let visible = CGRect(x: 0, y: dock.maxY, width: size.width, height: size.height - menuH - dock.maxY)
        let sim = Simulation(screenFrame: screen, visibleFrame: visible, hostsSnowman: true)
        var cfg = SimConfig()
        cfg.apply(.blizzard)
        cfg.temperature = scene.temperature
        cfg.christmas = scene.christmas
        cfg.snowmanCount = scene.snowmen
        cfg.frost = scene.frostEdges
        cfg.sparkle = scene.sparkle
        cfg.icicleLength = 1.2
        var wins = [TrackedWindow(id: 2, frame: terminal), TrackedWindow(id: 1, frame: notes)]
        let widgets = widgetRects.enumerated().map { TrackedWindow(id: 100 + $0.offset, frame: $0.element) }
        var t = 0.0
        let dt = 1.0 / 30
        func tick() {
            sim.sync(windows: wins, occluders: [], dock: dock, icons: [], widgets: widgets, now: t, cfg: cfg)
            sim.step(dt: dt, now: t)
            t += dt
        }
        // Pile up snow in a blizzard, then let a lighter snowfall show.
        while t < scene.seconds { tick() }
        cfg.density = scene.finalDensity
        cfg.maxFlakes = 1200
        sim.restartSnowmen()           // make sure no snowman is mid-melt in the picture
        for _ in 0..<300 { tick() }
        if scene.dragFrames > 0 {
            for f in 1...scene.dragFrames {
                if f <= 4 { wins[1] = TrackedWindow(id: 1, frame: wins[1].frame.offsetBy(dx: 30, dy: -6)) }
                tick()
            }
        }

        var particles: [Particle] = []
        var mesh: [Vertex] = []
        sim.buildParticles(into: &particles)
        sim.buildMesh(into: &mesh)
        let scale = 2
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: d) else { return }
        renderer.render(to: tex, size: size, particles: particles, mesh: mesh)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let snow = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: cs, bitmapInfo: info)?.makeImage(),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: info) else { return }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        drawDesktop(ctx, windows: wins, christmas: scene.christmas, temperature: scene.temperature)
        ctx.draw(snow, in: screen)
        save(ctx.makeImage(), path)
    }

    static func save(_ image: CGImage?, _ path: String) {
        guard let image else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Drawing helpers

    static func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: p)
    }

    static func symbol(_ name: String, in r: CGRect, color: NSColor, weight: NSFont.Weight = .semibold) {
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: weight).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        let k = min(r.width / s.width, r.height / s.height)
        img.draw(in: CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k))
    }

    static func rounded(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func gradient(_ ctx: CGContext, _ colors: [CGColor], from a: CGPoint, to b: CGPoint) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: The desktop

    static func drawDesktop(_ ctx: CGContext, windows: [TrackedWindow], christmas: Bool, temperature: Double) {
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Wallpaper: winter night sky over layered mountains.
        gradient(ctx, [rgb(0.05, 0.09, 0.24), rgb(0.16, 0.30, 0.58), rgb(0.48, 0.66, 0.88)],
                 from: CGPoint(x: 0, y: size.height), to: CGPoint(x: 0, y: 0))
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgb(0.55, 0.45, 0.95, 0.45), rgb(0.55, 0.45, 0.95, 0)] as CFArray, locations: nil)!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 1100, y: 760), startRadius: 0,
                               endCenter: CGPoint(x: 1100, y: 760), endRadius: 520, options: [])
        func ridge(_ base: CGFloat, _ amp: CGFloat, _ seed: CGFloat, _ color: CGColor) {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= size.width {
                let y = base + amp * (0.55 * sin(x / 170 + seed) + 0.3 * sin(x / 61 + seed * 2.3) + 0.15 * sin(x / 23 + seed))
                p.addLine(to: CGPoint(x: x, y: y))
                x += 6
            }
            p.addLine(to: CGPoint(x: size.width, y: 0))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(color)
            ctx.fillPath()
        }
        ridge(330, 90, 1.2, rgb(0.22, 0.34, 0.60, 0.85))
        ridge(230, 70, 3.1, rgb(0.15, 0.25, 0.48, 0.92))
        ridge(140, 45, 5.0, rgb(0.10, 0.18, 0.38, 1))

        drawWidgets(ctx, christmas: christmas, temperature: temperature)
        for w in windows.reversed() {
            if w.id == 1 { drawNotes(ctx, w.frame) } else { drawTerminal(ctx, w.frame) }
        }
        drawDock(ctx)
        drawMenuBar(ctx)
    }

    static func windowChrome(_ ctx: CGContext, _ r: CGRect, dark: Bool, title: String) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0, 0, 0, 0.45))
        ctx.addPath(rounded(ctx, r, 14))
        ctx.setFillColor(dark ? rgb(0.11, 0.11, 0.13) : rgb(0.99, 0.99, 0.99))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(rounded(ctx, r, 14))
        ctx.setStrokeColor(dark ? rgb(1, 1, 1, 0.12) : rgb(0, 0, 0, 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()
        for (i, c) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: r.minX + 16 + CGFloat(i) * 20, y: r.maxY - 26, width: 12, height: 12))
        }
        text(title, CGPoint(x: r.midX - CGFloat(title.count) * 3.6, y: r.maxY - 28), size: 13, weight: .semibold,
             color: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1))
    }

    static func drawNotes(_ ctx: CGContext, _ r: CGRect) {
        windowChrome(ctx, r, dark: false, title: "Winter plans")
        var y = r.maxY - 84
        text("Winter plans ❄︎", CGPoint(x: r.minX + 36, y: y), size: 26, weight: .bold, color: NSColor(white: 0.1, alpha: 1))
        y -= 46
        let lines = ["Make hot chocolate", "Build a snowman on the Dock", "Drag a window and watch the drift slide off",
                     "Hold ⌥ and shovel the bottom of the screen", "Turn on Christmas mode on December 1st",
                     "Set the temperature to −20 °C for real icicles"]
        for (i, l) in lines.enumerated() {
            let done = i < 2
            ctx.setStrokeColor(done ? rgb(0.95, 0.66, 0.1) : rgb(0.7, 0.7, 0.72))
            ctx.setLineWidth(1.6)
            let box = CGRect(x: r.minX + 38, y: y + 4, width: 15, height: 15)
            ctx.strokeEllipse(in: box)
            if done {
                ctx.setFillColor(rgb(0.95, 0.66, 0.1))
                ctx.fillEllipse(in: box.insetBy(dx: 3, dy: 3))
            }
            text(l, CGPoint(x: r.minX + 64, y: y), size: 17, color: NSColor(white: done ? 0.55 : 0.15, alpha: 1))
            y -= 36
        }
    }

    static func drawTerminal(_ ctx: CGContext, _ r: CGRect) {
        windowChrome(ctx, r, dark: true, title: "isnow — zsh")
        let lines: [(String, NSColor)] = [
            ("~/iSnow $ ./build.sh --install", NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)),
            ("Build complete!", NSColor(white: 0.85, alpha: 1)),
            ("Signed and installed: ~/Applications/iSnow.app", NSColor(white: 0.85, alpha: 1)),
            ("~/iSnow $ ./scripts/release.sh 1.0", NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)),
            ("Created dist/iSnow-v1.0.dmg", NSColor(white: 0.85, alpha: 1)),
            ("~/iSnow $ █", NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)),
        ]
        var y = r.maxY - 70
        for (l, c) in lines {
            text(l, CGPoint(x: r.minX + 20, y: y), size: 14, color: c, mono: true)
            y -= 26
        }
    }

    static func drawWidgets(_ ctx: CGContext, christmas: Bool, temperature: Double) {
        for (i, r) in widgetRects.enumerated() {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0, 0, 0, 0.3))
            ctx.addPath(rounded(ctx, r, 24))
            ctx.clip()
            if i == 0 {
                gradient(ctx, [rgb(0.25, 0.48, 0.86), rgb(0.12, 0.24, 0.55)], from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))
            } else {
                ctx.setFillColor(rgb(0.98, 0.98, 0.99, 0.92))
                ctx.fill(r)
            }
            ctx.restoreGState()
            if i == 0 {
                text("Mountains", CGPoint(x: r.minX + 16, y: r.maxY - 34), size: 15, weight: .semibold, color: .white)
                text("−\(Int(-temperature))°", CGPoint(x: r.minX + 14, y: r.maxY - 84), size: 44, weight: .light, color: .white)
                symbol("cloud.snow.fill", in: CGRect(x: r.minX + 16, y: r.minY + 34, width: 26, height: 22), color: .white)
                text("Heavy snow", CGPoint(x: r.minX + 16, y: r.minY + 12), size: 13, weight: .medium, color: .white)
            } else {
                text(christmas ? "THURSDAY" : "MONDAY", CGPoint(x: r.minX + 16, y: r.maxY - 32), size: 12, weight: .bold,
                     color: NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
                text(christmas ? "24" : "7", CGPoint(x: r.minX + 14, y: r.maxY - 92), size: 54, weight: .light,
                     color: NSColor(white: 0.1, alpha: 1))
                text(christmas ? "Christmas Eve" : "Ski trip", CGPoint(x: r.minX + 16, y: r.minY + 14), size: 13,
                     weight: .medium, color: NSColor(white: 0.3, alpha: 1))
            }
        }
    }

    static func drawDock(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 16, color: rgb(0, 0, 0, 0.3))
        ctx.addPath(rounded(ctx, dock, 20))
        ctx.setFillColor(rgb(1, 1, 1, 0.24))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(rounded(ctx, dock, 20))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.4))
        ctx.setLineWidth(1)
        ctx.strokePath()
        let icons: [(String, CGColor, CGColor)] = [
            ("folder.fill", rgb(0.35, 0.7, 1), rgb(0.1, 0.45, 0.95)), ("globe", rgb(0.3, 0.75, 1), rgb(0.05, 0.4, 0.9)),
            ("envelope.fill", rgb(0.35, 0.65, 1), rgb(0.1, 0.35, 0.95)), ("message.fill", rgb(0.4, 0.9, 0.45), rgb(0.1, 0.7, 0.25)),
            ("photo.fill", rgb(1, 0.75, 0.3), rgb(0.95, 0.4, 0.4)), ("music.note", rgb(1, 0.4, 0.5), rgb(0.9, 0.15, 0.3)),
            ("calendar", rgb(1, 1, 1), rgb(0.9, 0.9, 0.92)), ("note.text", rgb(1, 0.88, 0.4), rgb(1, 0.75, 0.15)),
            ("terminal.fill", rgb(0.25, 0.25, 0.28), rgb(0.08, 0.08, 0.1)), ("gearshape.fill", rgb(0.65, 0.66, 0.7), rgb(0.4, 0.41, 0.45)),
            ("snowflake", rgb(0.3, 0.55, 0.95), rgb(0.06, 0.15, 0.4)), ("trash.fill", rgb(0.85, 0.87, 0.9), rgb(0.65, 0.67, 0.72)),
        ]
        var x = dock.minX + 14
        for (i, ic) in icons.enumerated() {
            if i == icons.count - 1 {
                ctx.setFillColor(rgb(1, 1, 1, 0.35))
                ctx.fill(CGRect(x: x + 1, y: dock.minY + 12, width: 1, height: 40))
                x += 8
            }
            let r = CGRect(x: x, y: dock.minY + 8, width: 48, height: 48)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: rgb(0, 0, 0, 0.25))
            ctx.addPath(rounded(ctx, r, 11))
            ctx.clip()
            gradient(ctx, [ic.1, ic.2], from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))
            ctx.restoreGState()
            let dark = ic.0 == "calendar" || ic.0 == "trash.fill"
            symbol(ic.0, in: r.insetBy(dx: 12, dy: 12), color: dark ? NSColor(white: 0.25, alpha: 1) : .white)
            x += 56
        }
    }

    static func drawMenuBar(_ ctx: CGContext) {
        let bar = CGRect(x: 0, y: size.height - menuH, width: size.width, height: menuH)
        ctx.setFillColor(rgb(0.02, 0.05, 0.15, 0.35))
        ctx.fill(bar)
        let y = bar.minY + 8
        text("Notes", CGPoint(x: 20, y: y), size: 13.5, weight: .bold, color: .white)
        var x: CGFloat = 76
        for m in ["File", "Edit", "Format", "View", "Window", "Help"] {
            text(m, CGPoint(x: x, y: y), size: 13.5, color: .white)
            x += CGFloat(m.count) * 8 + 22
        }
        symbol("snowflake", in: CGRect(x: 1186, y: bar.minY + 8, width: 16, height: 16), color: .white)
        symbol("wifi", in: CGRect(x: 1216, y: bar.minY + 8, width: 18, height: 15), color: .white)
        symbol("battery.75percent", in: CGRect(x: 1246, y: bar.minY + 8, width: 26, height: 14), color: .white)
        text("Thu 24 Dec  9:41", CGPoint(x: 1290, y: y), size: 13.5, weight: .medium, color: .white)
    }

    // MARK: Settings window

    static func renderSettings(dir: String, delegate: AppDelegate) {
        var cfg = SimConfig()
        cfg.christmas = true
        let preview = Settings(preview: cfg)
        let tabs = [(0, "settings-snowfall"), (1, "settings-drifts"), (2, "settings-snowman"), (3, "settings-christmas")]
        var pending = tabs.count
        for (idx, (tab, name)) in tabs.enumerated() {
            let host = NSHostingView(rootView: SettingsView(settings: preview, delegate: delegate, tab: tab, activates: false)
                .environment(\.colorScheme, .light)
                .environment(\.controlActiveState, .key))
            host.appearance = NSAppearance(named: .aqua)
            let fit = host.fittingSize
            host.frame = CGRect(x: 0, y: 0, width: 500, height: max(420, fit.height))
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            win.setFrameOrigin(CGPoint(x: -4000 - CGFloat(idx) * 600, y: -4000))
            win.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let cg = rep.cgImage { composeWindow(cg, size: host.bounds.size, path: "\(dir)/\(name).png") }
                }
                win.orderOut(nil)
                print("settings \(name)")
                pending -= 1
                if pending == 0 { exit(0) }
            }
        }
    }

    /// Put the settings content into a window frame on a soft winter background.
    static func composeWindow(_ content: CGImage, size s: CGSize, path: String) {
        let pad: CGFloat = 60, titleH: CGFloat = 52
        let W = s.width + pad * 2, H = s.height + titleH + pad * 2
        let scale: CGFloat = 2
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        gradient(ctx, [rgb(0.16, 0.30, 0.58), rgb(0.48, 0.66, 0.88)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
        let r = CGRect(x: pad, y: pad, width: s.width, height: s.height + titleH)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: rgb(0, 0, 0, 0.4))
        ctx.addPath(rounded(ctx, r, 16))
        ctx.setFillColor(rgb(0.96, 0.96, 0.97))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(rounded(ctx, r, 16))
        ctx.clip()
        ctx.draw(content, in: CGRect(x: pad, y: pad, width: s.width, height: s.height))
        ctx.restoreGState()
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        for (i, c) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: r.minX + 18 + CGFloat(i) * 20, y: r.maxY - 32, width: 12, height: 12))
        }
        text("iSnow Settings", CGPoint(x: r.midX - 50, y: r.maxY - 35), size: 14, weight: .semibold,
             color: NSColor(white: 0.2, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        save(ctx.makeImage(), path)
    }
}
