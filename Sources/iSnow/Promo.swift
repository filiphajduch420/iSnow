import AppKit
import ImageIO
import Metal
import SwiftUI
import UniformTypeIdentifiers

/// Renders the README screenshots without any screen-recording permission: a drawn winter desktop
/// (wallpaper, windows, widgets, Dock, menu bar) with iSnow's real simulation and renderer on top,
/// plus every tab of the settings window rendered from its SwiftUI view.
@MainActor
enum Promo {
    /// What happens in the last seconds before the picture is taken.
    enum Action { case none, skiers, plow, shovel, fullscreen }

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
        var santa = false              // send Santa's sleigh so it is on screen in the picture
        var action: Action = .none
        var lightSize = 1.0
        var lightGlow = 1.0
        var treeSize = 1.3
        /// Close-ups saved instead of the whole screen: file name and region in points.
        var crops: [(String, CGRect)] = []
    }

    static let size = CGSize(width: 1440, height: 900)
    static let menuH: CGFloat = 32
    static let dock = CGRect(x: 372, y: 6, width: 696, height: 64)
    static let terminal = CGRect(x: 700, y: 170, width: 560, height: 360)
    static let notes = CGRect(x: 110, y: 290, width: 660, height: 450)
    static let widgetRects = [CGRect(x: 1262, y: 672, width: 158, height: 158), CGRect(x: 1262, y: 492, width: 158, height: 158)]

    static let scenes: [Scene] = [
        Scene(name: "hero"),
        Scene(name: "christmas", temperature: -4, seconds: 120, christmas: true, snowmen: 2, santa: true),
        Scene(name: "slide", temperature: -5, seconds: 140, snowmen: 2, dragFrames: 9),
        Scene(name: "frost", temperature: -20, seconds: 200, snowmen: 1, frostEdges: true, sparkle: true, finalDensity: 2.2),
        Scene(name: "skiers", temperature: -6, seconds: 140, snowmen: 2, action: .skiers),
        Scene(name: "snowplow", temperature: -6, seconds: 150, snowmen: 2, action: .plow),
        Scene(name: "shovel", temperature: -6, seconds: 140, snowmen: 2, action: .shovel,
              crops: [("shovel", CGRect(x: 0, y: 0, width: 560, height: 350))]),
        Scene(name: "lights", temperature: -5, seconds: 120, christmas: true, snowmen: 2, lightSize: 2.1, lightGlow: 1.9,
              treeSize: 1.9, crops: [("lights", CGRect(x: 0, y: 500, width: 640, height: 400)),
                                     ("tree", CGRect(x: 60, y: 0, width: 640, height: 400))]),
        Scene(name: "fullscreen", temperature: -8, seconds: 150, snowmen: 2, finalDensity: 3.2, action: .fullscreen),
    ]

    static func run(dir: String, delegate: AppDelegate) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let renderer = Renderer() else { print("no metal"); exit(1) }
        let only = ProcessInfo.processInfo.environment["ISNOW_PROMO_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for s in scenes where only?.contains(s.name) ?? true {
            render(s, renderer: renderer, dir: dir)
            print("scene \(s.name)")
        }
        if only == nil || only!.contains("settings") { renderSettings(dir: dir, delegate: delegate) } else { exit(0) }
    }

    // MARK: Desktop scenes

    /// One frame of the simulation: its particles and triangles.
    struct Frame { var particles: [Particle] = []; var mesh: [Vertex] = [] }

    static func capture(_ sim: Simulation) -> Frame {
        var f = Frame()
        sim.buildParticles(into: &f.particles)
        sim.buildMesh(into: &f.mesh)
        return f
    }

    static func render(_ scene: Scene, renderer: Renderer, dir: String) {
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
        cfg.lightSize = scene.lightSize
        cfg.lightGlow = scene.lightGlow
        cfg.treeSize = scene.treeSize
        cfg.santa = false              // no random visitors: the scene sends Santa, skiers or the plow itself
        cfg.skier = false
        cfg.snowplow = false           // (sendPlow() still works)
        var wins = [TrackedWindow(id: 2, frame: terminal), TrackedWindow(id: 1, frame: notes)]
        var menuBars: [CGRect]? = nil
        let widgets = widgetRects.enumerated().map { TrackedWindow(id: 100 + $0.offset, frame: $0.element) }
        var t = 0.0
        let dt = 1.0 / 30
        func tick(mouse: CGPoint? = nil, shovel: Bool = false) {
            sim.sync(windows: wins, occluders: [], dock: dock, icons: [], widgets: widgets, menuBars: menuBars, now: t, cfg: cfg)
            sim.step(dt: dt, now: t, mouse: mouse, shovel: shovel)
            t += dt
        }
        // Pile up snow in a blizzard, then let a lighter snowfall show.
        while t < scene.seconds { tick() }
        cfg.density = scene.finalDensity
        cfg.maxFlakes = 1200
        sim.restartSnowmen()           // make sure no snowman is mid-melt in the picture
        let finalTicks = 300
        for i in 0..<finalTicks {
            // Santa flies at about 190 pt/s from just off screen: 2.7 s before the end he is well inside.
            if scene.santa && i == finalTicks - 80 { sim.launchSanta() }
            tick()
        }
        if scene.dragFrames > 0 {
            for f in 1...scene.dragFrames {
                if f <= 4 { wins[1] = TrackedWindow(id: 1, frame: wins[1].frame.offsetBy(dx: 30, dy: -6)) }
                tick()
            }
        }

        var frame: Frame
        var crops = scene.crops
        var cursor: CGPoint?
        var fullscreen = false
        switch scene.action {
        case .none:
            frame = capture(sim)
        case .skiers:
            // Send a group and keep the moment with the most skiers in the picture – best with one in the air.
            _ = sim.sendSkier()
            tick()
            // The group rides away from the edge it came in at; frame the end of the Dock where they jump off.
            let toRight = (skierXs(capture(sim).mesh).first ?? 0) < Float(size.width / 2)
            let region = CGRect(x: toRight ? dock.maxX - 420 : dock.minX - 220, y: 0, width: 640, height: 400)
            crops = [("skiers", region)]
            frame = capture(sim)
            var best = -1.0
            for _ in 0..<(14 * 30) {
                tick()
                let f = capture(sim)
                let score = skierScore(f.mesh, region: region)
                if score > best { best = score; frame = f }
            }
            print("skiers: score \(best)")
        case .plow:
            // The truck comes in from one edge (chosen at random) – follow it with an animated GIF of that side
            // and take the picture while it clears the bottom just before the Dock.
            sim.sendPlow()
            tick()
            let fromLeft = (plowX(capture(sim).mesh) ?? 0) < Float(size.width / 2)
            let gifRegion = CGRect(x: fromLeft ? 0 : size.width - 720, y: 0, width: 720, height: 240)
            crops = [("snowplow", CGRect(x: fromLeft ? 0 : size.width - 640, y: 0, width: 640, height: 400))]
            let bg = desktopImage(windows: wins, christmas: false, temperature: scene.temperature, scale: 1)
            var gif: [CGImage] = []
            frame = capture(sim)
            var shot = false
            for i in 0..<(9 * 30) {
                tick()
                let f = capture(sim)
                guard let x = plowX(f.mesh) else { if shot { break } else { continue } }
                let along = fromLeft ? x : Float(size.width) - x
                if !shot && along >= 215 { frame = f; shot = true }
                if i % 2 == 0, along < 820, let img = image(f, renderer: renderer, scale: 1, background: { ctx in
                    ctx.draw(bg, in: CGRect(origin: .zero, size: size))
                }), let c = img.cropping(to: pixelRect(gifRegion, scale: 1)) {
                    gif.append(c)
                }
                if shot && along >= 820 { break }
            }
            writeGIF(gif, path: "\(dir)/snowplow.gif", delay: 2.0 / 30)
        case .shovel:
            // Hold ⌥ at the bottom left, then push the shovel to the right through the drift.
            let y = CGFloat(min(40, max(10, surface(capture(sim).mesh, x: 140) - 2)))
            var x: CGFloat = 110
            for _ in 0..<12 { tick(mouse: CGPoint(x: x, y: y), shovel: true) }
            for _ in 0..<66 {
                x += 2.6
                tick(mouse: CGPoint(x: x, y: y), shovel: true)
            }
            cursor = CGPoint(x: x, y: y)
            frame = capture(sim)
        case .fullscreen:
            // A video player goes full screen: only faded snowfall and the icicles at the top stay.
            wins = [TrackedWindow(id: 50, frame: screen)]
            menuBars = []
            fullscreen = true
            for _ in 0..<90 { tick() }
            frame = capture(sim)
        }

        guard let img = image(frame, renderer: renderer, scale: 2, background: { ctx in
            if fullscreen {
                drawVideoApp(ctx)
            } else {
                drawDesktop(ctx, windows: wins, christmas: scene.christmas, temperature: scene.temperature)
            }
        }, foreground: { ctx in
            if let c = cursor { drawCursor(ctx, at: c) }
        }) else { print("render failed: \(scene.name)"); return }
        if crops.isEmpty {
            Snapshot.savePNG(img, "\(dir)/\(scene.name).png")
        } else {
            for (name, r) in crops { Snapshot.savePNG(img.cropping(to: pixelRect(r, scale: 2)), "\(dir)/\(name).png") }
        }
    }

    /// A region in points (origin bottom left) as a pixel rectangle of an image (origin top left).
    static func pixelRect(_ r: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: r.minX * scale, y: (size.height - r.maxY) * scale, width: r.width * scale, height: r.height * scale)
    }

    /// Renders a frame over `background` (and under `foreground`) at the given scale.
    static func image(_ f: Frame, renderer: Renderer, scale: Int, background: (CGContext) -> Void,
                      foreground: (CGContext) -> Void = { _ in }) -> CGImage? {
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: d) else { return nil }
        renderer.render(to: tex, size: size, particles: f.particles, mesh: f.mesh)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let snow = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: cs, bitmapInfo: info)?.makeImage(),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: info) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        background(ctx)
        ctx.draw(snow, in: CGRect(origin: .zero, size: size))
        foreground(ctx)
        return ctx.makeImage()
    }

    /// The drawn desktop as an image (drawn once for all frames of the GIF).
    static func desktopImage(windows: [TrackedWindow], christmas: Bool, temperature: Double, scale: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        drawDesktop(ctx, windows: windows, christmas: christmas, temperature: temperature)
        return ctx.makeImage()!
    }

    static func writeGIF(_ frames: [CGImage], path: String, delay: Double) {
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, loop)
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, props) }
        if CGImageDestinationFinalize(dest) { print("gif \(frames.count) frames: \(path)") }
    }

    // MARK: Finding things in a frame (by their exact colours)

    /// The top of the snow at the bottom of the screen or on the Dock near x (drift columns use the snow material).
    static func surface(_ mesh: [Vertex], x: Float) -> Float {
        var top: Float = Float(dock.minX)...Float(dock.maxX) ~= x ? Float(dock.maxY) : 0
        for v in mesh where v.r >= 2048 && v.r < 4096 && v.y < 160 && abs(v.x - x) <= 4 { top = max(top, v.y) }
        return top
    }

    /// The snowplow's position: the centre of its orange trim.
    static func plowX(_ mesh: [Vertex]) -> Float? {
        var sum: Float = 0, n: Float = 0
        for v in mesh where abs(v.r - 0.72) < 0.002 && abs(v.g - 0.4) < 0.002 && abs(v.b - 0.05) < 0.002 { sum += v.x; n += 1 }
        return n > 0 ? sum / n : nil
    }

    /// How good a skier picture is: one point per skier in the region, three more if one of them is in the air.
    static func skierScore(_ mesh: [Vertex], region: CGRect) -> Double {
        var score = 0.0, air = 0.0
        for g in skierGroups(mesh) {
            let cx = g.map(\.x).reduce(0, +) / Float(g.count)
            guard cx > Float(region.minX) + 30, cx < Float(region.maxX) - 30 else { continue }
            score += 1
            let low = g.map(\.y).min() ?? 0
            let height = low - surface(mesh, x: cx)
            if height > 34 { air = max(air, 3 + Double(min(1, (height - 34) / 40))) }
        }
        return score + air
    }

    /// The centres of the skiers on screen, from left to right.
    static func skierXs(_ mesh: [Vertex]) -> [Float] {
        skierGroups(mesh).map { g in g.map(\.x).reduce(0, +) / Float(g.count) }
    }

    /// The skiers' jacket vertices, one group per skier.
    static func skierGroups(_ mesh: [Vertex]) -> [[(x: Float, y: Float)]] {
        let jackets: [(Float, Float, Float)] = [(0.9, 0.16, 0.2), (0.16, 0.45, 0.95), (1, 0.55, 0.1),
                                                (0.14, 0.68, 0.36), (0.6, 0.3, 0.86), (0.98, 0.78, 0.12)]
        var pts: [(x: Float, y: Float)] = []
        for v in mesh where v.y < 300 && jackets.contains(where: { abs($0.0 - v.r) < 0.002 && abs($0.1 - v.g) < 0.002 && abs($0.2 - v.b) < 0.002 }) {
            pts.append((v.x, v.y))
        }
        pts.sort { $0.x < $1.x }
        var groups: [[(x: Float, y: Float)]] = []
        for p in pts {
            if let last = groups.last?.last, p.x - last.x < 20 { groups[groups.count - 1].append(p) } else { groups.append([p]) }
        }
        return groups
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
            ("~/iSnow $ ./scripts/release.sh 1.1", NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)),
            ("Created dist/iSnow-v1.1.dmg", NSColor(white: 0.85, alpha: 1)),
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

    /// A video player in full screen: a mountain sunset with the playback controls.
    static func drawVideoApp(_ ctx: CGContext) {
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        defer { NSGraphicsContext.restoreGraphicsState() }
        gradient(ctx, [rgb(0.16, 0.12, 0.34), rgb(0.62, 0.30, 0.48), rgb(0.98, 0.58, 0.36), rgb(1, 0.82, 0.55)],
                 from: CGPoint(x: 0, y: size.height), to: CGPoint(x: 0, y: 280))
        let sun = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [rgb(1, 0.95, 0.75, 1), rgb(1, 0.85, 0.5, 0.5), rgb(1, 0.7, 0.4, 0)] as CFArray,
                             locations: [0, 0.25, 1])!
        ctx.drawRadialGradient(sun, startCenter: CGPoint(x: 900, y: 330), startRadius: 0,
                               endCenter: CGPoint(x: 900, y: 330), endRadius: 420, options: [])
        func ridge(_ base: CGFloat, _ amp: CGFloat, _ seed: CGFloat, _ color: CGColor) {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= size.width {
                let y = base + amp * (0.6 * sin(x / 210 + seed) + 0.28 * sin(x / 77 + seed * 1.7) + 0.12 * sin(x / 29 + seed))
                p.addLine(to: CGPoint(x: x, y: y))
                x += 6
            }
            p.addLine(to: CGPoint(x: size.width, y: 0))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(color)
            ctx.fillPath()
        }
        ridge(330, 110, 0.4, rgb(0.42, 0.24, 0.42, 0.9))
        ridge(240, 80, 2.2, rgb(0.24, 0.14, 0.30, 1))
        ridge(130, 50, 4.1, rgb(0.11, 0.07, 0.17, 1))
        // Playback controls
        let bar = CGRect(x: 320, y: 46, width: 800, height: 92)
        ctx.saveGState()
        ctx.addPath(rounded(ctx, bar, 22))
        ctx.setFillColor(rgb(0.08, 0.08, 0.1, 0.55))
        ctx.fillPath()
        ctx.restoreGState()
        symbol("backward.fill", in: CGRect(x: bar.midX - 92, y: bar.maxY - 44, width: 34, height: 22), color: .white)
        symbol("pause.fill", in: CGRect(x: bar.midX - 16, y: bar.maxY - 48, width: 32, height: 30), color: .white)
        symbol("forward.fill", in: CGRect(x: bar.midX + 58, y: bar.maxY - 44, width: 34, height: 22), color: .white)
        symbol("speaker.wave.2.fill", in: CGRect(x: bar.minX + 26, y: bar.maxY - 44, width: 26, height: 20), color: .white)
        symbol("pip.enter", in: CGRect(x: bar.maxX - 54, y: bar.maxY - 44, width: 26, height: 20), color: .white)
        let track = CGRect(x: bar.minX + 84, y: bar.minY + 20, width: bar.width - 168, height: 5)
        ctx.addPath(rounded(ctx, track, 2.5))
        ctx.setFillColor(rgb(1, 1, 1, 0.3))
        ctx.fillPath()
        ctx.addPath(rounded(ctx, CGRect(x: track.minX, y: track.minY, width: track.width * 0.38, height: track.height), 2.5))
        ctx.setFillColor(rgb(1, 1, 1, 0.95))
        ctx.fillPath()
        text("0:41:12", CGPoint(x: bar.minX + 22, y: bar.minY + 14), size: 12.5, weight: .medium, color: .white)
        text("−1:07:48", CGPoint(x: bar.maxX - 76, y: bar.minY + 14), size: 12.5, weight: .medium, color: .white)
    }

    /// The macOS arrow cursor with its tip at p.
    static func drawCursor(_ ctx: CGContext, at p: CGPoint) {
        let pts: [CGPoint] = [(0, 0), (0, -17), (4.2, -13), (7, -19.6), (9.6, -18.5), (6.9, -12.2), (12.3, -12.2)]
            .map { CGPoint(x: p.x + $0.0 * 1.1, y: p.y + $0.1 * 1.1) }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: rgb(0, 0, 0, 0.35))
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(1, 1, 1))
        ctx.setLineWidth(2.4)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.fillPath()
    }

    // MARK: Settings window

    static func renderSettings(dir: String, delegate: AppDelegate) {
        var cfg = SimConfig()
        cfg.christmas = true
        let preview = Settings(preview: cfg)
        // Run from `swift build` there is no app bundle: take the icon and version from the sources.
        if let icon = NSImage(contentsOfFile: "build/AppIcon.icns") { NSApp.applicationIconImage = icon }
        if let info = NSDictionary(contentsOfFile: "Info.plist"), let v = info["CFBundleShortVersionString"] as? String {
            AboutTab.fallbackVersion = v
        }
        let tabs = [(0, "settings-snowfall"), (1, "settings-drifts"), (2, "settings-snowman"), (3, "settings-christmas"),
                    (4, "settings-other"), (5, "settings-about")]
        var pending = tabs.count
        for (idx, (tab, name)) in tabs.enumerated() {
            let host = NSHostingView(rootView: SettingsView(settings: preview, delegate: delegate, tab: tab, activates: false)
                .environment(\.colorScheme, .light)
                .environment(\.controlActiveState, .key))
            host.appearance = NSAppearance(named: .aqua)
            // A grouped form scrolls – make the window tall enough to show the whole tab.
            host.frame = CGRect(x: 0, y: 0, width: 500, height: 2000)
            host.layoutSubtreeIfNeeded()
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .aqua)
            win.contentView = host
            win.setFrameOrigin(CGPoint(x: -4000 - CGFloat(idx) * 600, y: -4000))
            win.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                host.layoutSubtreeIfNeeded()
                // Measure the form's content and shrink the window to it.
                let content = contentHeight(host) ?? max(420, host.fittingSize.height)
                win.setContentSize(CGSize(width: 500, height: content))
                host.frame = CGRect(x: 0, y: 0, width: 500, height: content)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        if let cg = rep.cgImage { composeWindow(cg, size: host.bounds.size, path: "\(dir)/\(name).png") }
                    }
                    win.orderOut(nil)
                    print("settings \(name): \(Int(content)) pt")
                    pending -= 1
                    if pending == 0 { exit(0) }
                }
            }
        }
    }

    /// Height the window needs to show the whole scrolling form: the scroll view's document height plus
    /// everything above the scroll view (the tab bar).
    static func contentHeight(_ host: NSView) -> CGFloat? {
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, s.documentView != nil { return s }
            for c in v.subviews { if let s = find(c) { return s } }
            return nil
        }
        guard let scroll = find(host), let doc = scroll.documentView else { return nil }
        let inHost = scroll.convert(scroll.bounds, to: host)
        let above = host.isFlipped ? inHost.minY : host.bounds.height - inHost.maxY
        let below = host.isFlipped ? host.bounds.height - inHost.maxY : inHost.minY
        return ceil(above + below + doc.frame.height + scroll.contentInsets.top + scroll.contentInsets.bottom)
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
        Snapshot.savePNG(ctx.makeImage(), path)
    }
}
