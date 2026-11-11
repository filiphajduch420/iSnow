import AppKit
import Metal

/// Debug mode: `iSnow --snapshot out.png` simulates a scene with fake windows and saves an image.
@MainActor
enum Snapshot {
    static func run(path: String) {
        guard let r = Renderer() else { print("no metal"); return }
        let env = ProcessInfo.processInfo.environment
        let size = CGSize(width: 1200, height: 760)
        let screen = CGRect(origin: .zero, size: size)
        let visible = CGRect(x: 0, y: 64, width: 1200, height: 668)
        let notchFull = env["ISNOW_NOTCHFULL"] != nil
        let sim = Simulation(screenFrame: screen, visibleFrame: visible, hostsSnowman: true, safeTop: notchFull ? 32 : 0)
        var wins = [TrackedWindow(id: 1, frame: CGRect(x: 140, y: 250, width: 520, height: 360)),
                    TrackedWindow(id: 2, frame: CGRect(x: 560, y: 160, width: 470, height: 330))]
        if env["ISNOW_MAX"] != nil {
            // A zoomed window filling the visible frame (down to the Dock).
            wins = [TrackedWindow(id: 3, frame: CGRect(x: 0, y: 62, width: 1200, height: 666))]
        }
        let dock = CGRect(x: 330, y: 6, width: 540, height: 56)
        let icons = [CGRect(x: 1110, y: 620, width: 52, height: 52), CGRect(x: 1110, y: 530, width: 52, height: 52)]
        var cfg = SimConfig()
        cfg.apply(.blizzard)
        cfg.frost = true
        cfg.temperature = Double(env["ISNOW_TEMP"] ?? "") ?? -15
        cfg.snowmanCount = Double(env["ISNOW_SNOWMEN"] ?? "") ?? 3
        cfg.christmas = env["ISNOW_XMAS"] != nil
        cfg.lightStyle = Int(env["ISNOW_XMAS"] ?? "") ?? 0
        if let v = env["ISNOW_LIGHTSIZE"].flatMap(Double.init) { cfg.lightSize = v }
        if let v = env["ISNOW_GLOW"].flatMap(Double.init) { cfg.lightGlow = v }
        cfg.sparkle = true
        var t = 0.0
        let dt = 1.0 / 30
        let seconds = Double(env["ISNOW_SECONDS"] ?? "") ?? 75
        // ISNOW_WIDGETS=1 adds a desktop widget that collects snow, =0 adds one that snow falls through.
        let widgetEnv = env["ISNOW_WIDGETS"]
        let widgets = widgetEnv == nil ? [] : [TrackedWindow(id: 9, frame: CGRect(x: 1060, y: 330, width: 120, height: 120))]
        if let w = widgetEnv { cfg.onWidgets = w == "1" }
        // ISNOW_SANTA=1 sends Santa's sleigh about 2.5 s before the picture is taken, so it is on screen.
        var santaAt: Double? = env["ISNOW_SANTA"] == "1" ? max(0, seconds - 2.5) : nil
        // ISNOW_SKIER=1.5 sends a group of skiers along the bottom that many seconds before the picture.
        var skierAt: Double? = env["ISNOW_SKIER"].flatMap(Double.init).map { max(0, seconds - $0) }
        while t < seconds {
            if let s = santaAt, t >= s { sim.launchSanta(); santaAt = nil }
            if let s = skierAt, t >= s { print("skier:", sim.sendSkier()); skierAt = nil }
            if notchFull && t > 60 {
                // From now on a full-screen window fills everything below the notch; no menu bar.
                let full = [TrackedWindow(id: 50, frame: CGRect(x: 0, y: 0, width: size.width, height: size.height - 32))]
                sim.sync(windows: full, occluders: [], dock: dock, icons: icons, widgets: widgets, menuBars: [], now: t, cfg: cfg)
            } else {
                sim.sync(windows: wins, occluders: [], dock: dock, icons: icons, widgets: widgets, now: t, cfg: cfg)
            }
            sim.step(dt: dt, now: t)
            t += dt
        }
        if let drag = env["ISNOW_DRAG"], let frames = Int(drag), frames > 0 {
            // Drag window 1 to the right and capture the snow mid-fall.
            for f in 1...frames {
                let w0 = wins[0].frame
                wins[0] = TrackedWindow(id: wins[0].id, frame: w0.offsetBy(dx: f <= 8 ? 22 : 0, dy: f <= 8 ? 6 : 0))
                sim.sync(windows: wins, occluders: [], dock: dock, icons: icons, widgets: widgets, now: t, cfg: cfg)
                sim.step(dt: dt, now: t)
                t += dt
            }
        } else {
            sim.throwSnowball()
            for _ in 0..<12 { sim.step(dt: dt, now: t); t += dt }
        }

        let result = renderPNG(sim, renderer: r, size: size, path: path) { ctx in
            // desktop
            ctx.setFillColor(CGColor(red: 0.18, green: 0.30, blue: 0.45, alpha: 1)); ctx.fill(screen)
            // menu bar and Dock
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 0.9)); ctx.fill(CGRect(x: 0, y: 728, width: 1200, height: 32))
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 0.6)); ctx.fill(dock)
            ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1)); for i in icons { ctx.fill(i) }
            ctx.setFillColor(CGColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1)); for w in widgets { ctx.fill(w.frame) }
            // windows (back to front)
            for (k, wf) in wins.reversed().enumerated() {
                ctx.setFillColor(CGColor(gray: k == 0 ? 0.97 : 0.99, alpha: 1)); ctx.fill(wf.frame)
                ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
                ctx.fill(CGRect(x: wf.frame.minX, y: wf.frame.maxY - 28, width: wf.frame.width, height: 28))
            }
        }
        if let result { print("ok \(result.particles) particles, \(result.vertices) vertices") } else { print("render failed") }
    }

    /// Renders the simulation's current frame at 2× over a background drawn by `background` (in points,
    /// origin bottom left) and writes it to `path` as a PNG. Returns the particle and vertex counts.
    @discardableResult
    static func renderPNG(_ sim: Simulation, renderer: Renderer, size: CGSize, path: String,
                          background: (CGContext) -> Void) -> (particles: Int, vertices: Int)? {
        var particles: [Particle] = []
        var mesh: [Vertex] = []
        sim.buildParticles(into: &particles)
        sim.buildMesh(into: &mesh)
        let scale = 2
        let w = Int(size.width) * scale, h = Int(size.height) * scale
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        guard let tex = renderer.device.makeTexture(descriptor: d) else { return nil }
        renderer.render(to: tex, size: size, particles: particles, mesh: mesh)

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
        guard savePNG(ctx.makeImage(), path) else { return nil }
        return (particles.count, mesh.count)
    }

    @discardableResult
    static func savePNG(_ image: CGImage?, _ path: String) -> Bool {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
