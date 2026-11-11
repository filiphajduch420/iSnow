import AppKit
import Metal

/// Debug mode: `iSnow --snapshot out.png` simulates a scene with fake windows and saves an image.
@MainActor
enum Snapshot {
    static func run(path: String) {
        guard let r = Renderer() else { print("no metal"); return }
        let size = CGSize(width: 1200, height: 760)
        let screen = CGRect(origin: .zero, size: size)
        let visible = CGRect(x: 0, y: 64, width: 1200, height: 668)
        let sim = Simulation(screenFrame: screen, visibleFrame: visible, hostsSnowman: true)
        var wins = [TrackedWindow(id: 1, frame: CGRect(x: 140, y: 250, width: 520, height: 360)),
                    TrackedWindow(id: 2, frame: CGRect(x: 560, y: 160, width: 470, height: 330))]
        if ProcessInfo.processInfo.environment["ISNOW_MAX"] != nil {
            // A zoomed window filling the visible frame (down to the Dock).
            wins = [TrackedWindow(id: 3, frame: CGRect(x: 0, y: 62, width: 1200, height: 666))]
        }
        let dock = CGRect(x: 330, y: 6, width: 540, height: 56)
        let icons = [CGRect(x: 1110, y: 620, width: 52, height: 52), CGRect(x: 1110, y: 530, width: 52, height: 52)]
        var cfg = SimConfig()
        cfg.apply(.blizzard)
        cfg.frost = true
        let env = ProcessInfo.processInfo.environment
        cfg.temperature = Double(env["ISNOW_TEMP"] ?? "") ?? -15
        cfg.snowmanCount = Double(env["ISNOW_SNOWMEN"] ?? "") ?? 3
        cfg.sparkle = true
        var t = 0.0
        let dt = 1.0 / 30
        while t < 75 {
            sim.sync(windows: wins, occluders: [], dock: dock, icons: icons, now: t, cfg: cfg)
            sim.step(dt: dt, now: t)
            t += dt
        }
        if let drag = ProcessInfo.processInfo.environment["ISNOW_DRAG"], let frames = Int(drag) {
            // Drag window 1 to the right and capture the snow mid-fall.
            for f in 1...frames {
                let w0 = wins[0].frame
                wins[0] = TrackedWindow(id: wins[0].id, frame: w0.offsetBy(dx: f <= 8 ? 22 : 0, dy: f <= 8 ? 6 : 0))
                sim.sync(windows: wins, occluders: [], dock: dock, icons: icons, now: t, cfg: cfg)
                sim.step(dt: dt, now: t)
                t += dt
            }
        } else {
            sim.throwSnowball()
            for _ in 0..<12 { sim.step(dt: dt, now: t); t += dt }
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
        let tex = r.device.makeTexture(descriptor: d)!
        r.render(to: tex, size: size, particles: particles, mesh: mesh)

        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let snow = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: info)!.makeImage()!

        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // desktop
        ctx.setFillColor(CGColor(red: 0.18, green: 0.30, blue: 0.45, alpha: 1)); ctx.fill(screen)
        // menu bar and Dock
        ctx.setFillColor(CGColor(gray: 0.92, alpha: 0.9)); ctx.fill(CGRect(x: 0, y: 728, width: 1200, height: 32))
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 0.6)); ctx.fill(dock)
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1)); for i in icons { ctx.fill(i) }
        // windows (back to front)
        for (k, wf) in wins.reversed().enumerated() {
            ctx.setFillColor(CGColor(gray: k == 0 ? 0.97 : 0.99, alpha: 1)); ctx.fill(wf.frame)
            ctx.setFillColor(CGColor(gray: 0.88, alpha: 1)); ctx.fill(CGRect(x: wf.frame.minX, y: wf.frame.maxY - 28, width: wf.frame.width, height: 28))
        }
        ctx.scaleBy(x: 1 / CGFloat(scale), y: 1 / CGFloat(scale))
        ctx.draw(snow, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("ok \(particles.count) particles, \(mesh.count) vertices")
    }
}
