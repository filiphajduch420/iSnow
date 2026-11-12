import AppKit
import Metal

/// Debug mode: `iSnow --snapshot out.png` simulates a scene with fake windows and saves an image.
@MainActor
enum Snapshot {
    static func run(path: String) {
        guard let r = Renderer() else { print("no metal"); return }
        let env = ProcessInfo.processInfo.environment
        if env["ISNOW_REINDEER"] == "sheet" { ReindeerSheet.render(path: path, renderer: r); return }   // [1.3 reindeer]
        let size = CGSize(width: 1200, height: 760)
        let screen = CGRect(origin: .zero, size: size)
        let visible = CGRect(x: 0, y: 64, width: 1200, height: 668)
        let notchFull = env["ISNOW_NOTCHFULL"] != nil
        let sim = Simulation(screenFrame: screen, visibleFrame: visible, hostsSnowman: true, safeTop: notchFull ? 32 : 0)
        SnowmenDemo.setUp(sim, env: env)        // [1.3 snowmen] ISNOW_PARTY=1 party hats + sparklers
        var wins = [TrackedWindow(id: 1, frame: CGRect(x: 140, y: 250, width: 520, height: 360)),
                    TrackedWindow(id: 2, frame: CGRect(x: 560, y: 160, width: 470, height: 330))]
        if env["ISNOW_MAX"] != nil {
            // A zoomed window filling the visible frame (down to the Dock).
            wins = [TrackedWindow(id: 3, frame: CGRect(x: 0, y: 62, width: 1200, height: 666))]
        }
        // [1.3 tree] ISNOW_DOCK=left|right|none puts the Dock on a side of the screen or hides it.
        let dock: CGRect? = switch env["ISNOW_DOCK"] {
        case "left": CGRect(x: 0, y: 170, width: 62, height: 420)
        case "right": CGRect(x: 1138, y: 170, width: 62, height: 420)
        case "none": nil
        default: CGRect(x: 330, y: 6, width: 540, height: 56)
        }
        let icons = [CGRect(x: 1110, y: 620, width: 52, height: 52), CGRect(x: 1110, y: 530, width: 52, height: 52)]
        // ISNOW_AUTOHIDE=up|mid|down: an auto-hiding Dock, hidden while it snows; then it slides up out of the
        // snow at the bottom (mid: the picture is taken halfway up), or comes up and slides away again (down).
        let autohide = env["ISNOW_AUTOHIDE"]
        var liveDock: CGRect? = autohide != nil ? nil : dock
        var cfg = SimConfig()
        cfg.apply(.blizzard)
        cfg.frost = true
        cfg.temperature = Double(env["ISNOW_TEMP"] ?? "") ?? -15
        cfg.snowmanCount = Double(env["ISNOW_SNOWMEN"] ?? "") ?? 3
        cfg.christmas = env["ISNOW_XMAS"] != nil
        // [1.3 holidays] ISNOW_DATE=2026-12-31T23:58:00 sets the holiday clock: the picture is taken at that moment
        // (Christmas mode follows the calendar, the front window gets its lights). ISNOW_FIREWORKS=1 starts the
        // fireworks show 7 s before the picture.
        let holidayDate = env["ISNOW_DATE"].flatMap(Holidays.parse)
        if let d = holidayDate, env["ISNOW_XMAS"] == nil { cfg.christmas = Holidays.christmasActive(mode: 2, at: d) }
        let activeWin: CGRect? = holidayDate != nil ? wins.first?.frame : nil
        cfg.lightStyle = Int(env["ISNOW_XMAS"] ?? "") ?? 0
        if let v = env["ISNOW_TREESIZE"].flatMap(Double.init) { cfg.treeSize = v }   // [1.3 tree]
        if let v = env["ISNOW_LIGHTSIZE"].flatMap(Double.init) { cfg.lightSize = v }
        if let v = env["ISNOW_GLOW"].flatMap(Double.init) { cfg.lightGlow = v }
        cfg.sparkle = true
        cfg.penguin = false             // [1.3 penguin] no random visitor – ISNOW_PENGUIN sends one
        cfg.reindeer = false            // [1.3 reindeer] no random visitor – ISNOW_REINDEER sends one
        // [1.3 decor] ISNOW_DECOR=0 turns the Christmas decorations off, =canes makes every item stuck in the snow a
        // candy cane, a number (e.g. 2) sets the decoration size.
        if let d = env["ISNOW_DECOR"] {
            if d == "0" { cfg.christmasDecor = false }
            else if d == "canes" { sim.decorItems = sim.decorItems.map { var it = $0; it.kind = .cane; return it } }
            else if let v = Double(d) { cfg.decorSize = v }
        }
        // [1.3 weather] ISNOW_WEATHER=blizzard|heavy|steady|flurry|clear|coldsnap|thaw forces a living-weather phase
        // around the Normal preset (=live runs the state machine, =log prints two simulated hours and quits);
        // ISNOW_WEATHER_SPEED=60 fast-forwards the weather clock.
        let weatherEnv = env["ISNOW_WEATHER"]
        if weatherEnv == "log" { LivingWeather.printTrace(); return }
        let weather = weatherEnv.map { _ in LivingWeather.fromEnvironment(seed: 11) }
        if weather != nil { cfg.apply(.normal) }
        let userCfg = cfg
        var t = 0.0
        let dt = 1.0 / 30
        let seconds = Double(env["ISNOW_SECONDS"] ?? "") ?? 75
        // ISNOW_WIDGETS=1 adds a desktop widget that collects snow, =0 adds one that snow falls through.
        let widgetEnv = env["ISNOW_WIDGETS"]
        let widgets = widgetEnv == nil ? [] : [TrackedWindow(id: 9, frame: CGRect(x: 1060, y: 330, width: 120, height: 120))]
        if let w = widgetEnv { cfg.onWidgets = w == "1" }
        // ISNOW_SANTA=1 sends Santa's sleigh about 2.5 s before the picture is taken, so it is on screen.
        // [1.3 tree] ISNOW_SANTA=12 sends him that many seconds before (24–26 Dec: his presents have landed).
        var santaAt: Double? = env["ISNOW_SANTA"].flatMap { v in
            v == "1" ? max(0, seconds - 2.5) : Double(v).map { max(0, seconds - $0) }
        }
        // ISNOW_SKIER=1.5 sends a group of skiers along the bottom that many seconds before the picture.
        var skierAt: Double? = env["ISNOW_SKIER"].flatMap(Double.init).map { max(0, seconds - $0) }
        // [1.3 penguin] ISNOW_PENGUIN=20 sends a penguin along the bottom that many seconds before the picture.
        var penguinAt: Double? = env["ISNOW_PENGUIN"].flatMap(Double.init).map { max(0, seconds - $0) }
        // [1.3 reindeer] ISNOW_REINDEER=20 sends a reindeer along the bottom that many seconds before the picture.
        var reindeerAt: Double? = env["ISNOW_REINDEER"].flatMap(Double.init).map { max(0, seconds - $0) }
        let reindeerTrace = env["ISNOW_REINDEER_TRACE"] != nil
        var fireworksAt: Double? = env["ISNOW_FIREWORKS"] == "1" ? max(0, seconds - 7) : nil   // [1.3 holidays]
        // ISNOW_MESHEVERY=3 also builds the mesh and particles every 3rd frame (exercises the drawing code over time).
        let meshEvery = max(0, Int(env["ISNOW_MESHEVERY"] ?? "") ?? 0)
        var frame = 0, scratchMesh: [Vertex] = [], scratchParticles: [Particle] = []
        while t < seconds {
            if autohide != nil { liveDock = t < dt && env["ISNOW_AUTOHIDE_FRESH"] == nil ? dock : nil }   // shown once at the start (ISNOW_AUTOHIDE_FRESH: never), then hidden
            frame += 1
            if meshEvery > 0 && frame % meshEvery == 0 {
                scratchMesh.removeAll(keepingCapacity: true); scratchParticles.removeAll(keepingCapacity: true)
                sim.buildMesh(into: &scratchMesh); sim.buildParticles(into: &scratchParticles)
            }
            if let d = holidayDate { Holidays.fixedNow = d.addingTimeInterval(t - seconds) }   // [1.3 holidays]
            if let s = fireworksAt, t >= s { sim.launchFireworks(); fireworksAt = nil }
            if let s = penguinAt, t >= s { print("penguin:", sim.sendPenguin()); penguinAt = nil }
            if let s = reindeerAt, t >= s { print("reindeer:", sim.sendReindeer()); reindeerAt = nil }   // [1.3 reindeer]
            if reindeerTrace && Int((t * 30).rounded()) % 10 == 0 {             // [1.3 reindeer] ISNOW_REINDEER_TRACE=1
                for p in sim.reindeerSpots { print(String(format: "%5.1f", t), p) }
            }
            if let weather {                                   // [1.3 weather] ISNOW_GUST=1: a gust at the end
                if env["ISNOW_GUST"] != nil && t > seconds - 3 { weather.holdGust() }
                cfg = userCfg
                weather.apply(to: &cfg, now: t)
            }
            if let s = santaAt, t >= s { sim.launchSanta(); santaAt = nil }
            if let s = skierAt, t >= s { print("skier:", sim.sendSkier()); skierAt = nil }
            if notchFull && t > 60 {
                // From now on a full-screen window fills everything below the notch; no menu bar.
                let full = [TrackedWindow(id: 50, frame: CGRect(x: 0, y: 0, width: size.width, height: size.height - 32))]
                sim.sync(windows: full, occluders: [], dock: liveDock, icons: icons, widgets: widgets,
                         dockAutoHides: autohide != nil, menuBars: [], now: t, cfg: cfg)
            } else {
                sim.sync(windows: wins, occluders: [], dock: liveDock, icons: icons, widgets: widgets,
                         dockAutoHides: autohide != nil,
                         activeWindow: activeWin, now: t, cfg: cfg)      // [1.3 holidays] activeWindow
            }
            sim.step(dt: dt, now: t)
            t += dt
        }
        func printSnowmen(_ label: String) {
            let list = sim.snowmen.map { s in
                "x \(Int(s.anchorX)) y \(Int(s.baseY)) on \(s.hostKey == Simulation.dockKey ? "Dock" : s.hostKey == Simulation.groundKey ? "ground" : "\(s.hostKey)")\(s.falling ? " falling" : "")"
            }
            print("snowmen \(label):", list.joined(separator: " | "))
        }
        if env["ISNOW_FSBACK"] != nil {
            // A full-screen app for two seconds (with no snow over it), then back to the desktop: the snowfall
            // should carry on where it was, not start again at the top.
            func report(_ label: String) {
                let ys = sim.flakes.map(\.y)
                let mean = ys.isEmpty ? 0 : ys.reduce(0, +) / Float(ys.count)
                print("flakes \(label): \(ys.count), mean height \(Int(mean)) of \(Int(size.height))")
            }
            var fcfg = cfg
            fcfg.fullscreenSnow = 0
            fcfg.pauseFullscreen = true
            report("before")
            let full = [TrackedWindow(id: 60, frame: CGRect(origin: .zero, size: size))]
            for _ in 0..<60 {
                sim.sync(windows: full, occluders: [], dock: liveDock, icons: icons, widgets: widgets, now: t, cfg: fcfg)
                sim.step(dt: dt, now: t); t += dt
            }
            report("full screen")
            for _ in 0..<2 {
                sim.sync(windows: wins, occluders: [], dock: liveDock, icons: icons, widgets: widgets, now: t, cfg: fcfg)
                sim.step(dt: dt, now: t); t += dt
            }
            report("back")
        }
        if let mode = autohide, let rest = dock {
            // The Dock slides like the real one: about a quarter of a second, a frame at a time.
            let hidden = rest.offsetBy(dx: 0, dy: -(rest.maxY + 2))
            func frames(_ n: Int, dock d: CGRect?) {
                for _ in 0..<n {
                    liveDock = d
                    sim.sync(windows: wins, occluders: [], dock: d, icons: icons, widgets: widgets,
                             dockAutoHides: true, now: t, cfg: cfg)
                    sim.step(dt: dt, now: t)
                    t += dt
                }
            }
            func slide(from a: CGRect, to b: CGRect, steps: Int, stopAfter: Int? = nil) {
                for k in 1...steps {
                    if let stop = stopAfter, k > stop { return }
                    frames(1, dock: a.offsetBy(dx: 0, dy: (b.minY - a.minY) * CGFloat(k) / CGFloat(steps)))
                }
            }
            switch mode {
            case "hidden": break
            case "cycle":
                // Up, a while on the Dock, away (the snowmen on it fall off), then up again.
                slide(from: hidden, to: rest, steps: 8)
                frames(40, dock: rest)
                printSnowmen("up")
                slide(from: rest, to: hidden, steps: 8)
                frames(60, dock: nil)
                printSnowmen("hidden")
                slide(from: hidden, to: rest, steps: 8)
                frames(40, dock: rest)
            case "mid": slide(from: hidden, to: rest, steps: 8, stopAfter: 4)
            case "down":
                slide(from: hidden, to: rest, steps: 8)
                frames(30, dock: rest)
                slide(from: rest, to: hidden, steps: 8)
                frames(Int(env["ISNOW_AUTOHIDE_FALL"] ?? "") ?? 10, dock: nil)
            default:
                slide(from: hidden, to: rest, steps: 8)
                frames(20, dock: rest)
            }
            if liveDock == hidden { liveDock = nil }
            printSnowmen("end")
            print("autohide \(mode): dock \(liveDock.map { "\($0)" } ?? "hidden")")
        } else if let drag = env["ISNOW_DRAG"], let frames = Int(drag), frames > 0 {
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

        for p in sim.penguinSpots { print("penguin at", p) }     // [1.3 penguin]
        for p in sim.reindeerSpots { print("reindeer at", p) }   // [1.3 reindeer]
        // [1.3 snowmen] ISNOW_BUILD=1 rolls balls into a snowman (+ one half-rolled), ISNOW_FIGHT=1 a snowball fight
        SnowmenDemo.stage(sim, env: env, t: &t, dt: dt)
        let result = renderPNG(sim, renderer: r, size: size, path: path) { ctx in
            // desktop
            ctx.setFillColor(CGColor(red: 0.18, green: 0.30, blue: 0.45, alpha: 1)); ctx.fill(screen)
            // menu bar and Dock
            ctx.setFillColor(CGColor(gray: 0.92, alpha: 0.9)); ctx.fill(CGRect(x: 0, y: 728, width: 1200, height: 32))
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 0.6)); if let liveDock { ctx.fill(liveDock) }
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

/// Debug renders only (`--snapshot`, `--promo`): quits the process if it ever uses more than `limitMB` of memory,
/// so a runaway loop in drawing code cannot eat all of the Mac's memory while renders run unattended.
enum DebugMemoryGuard {
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    static func start(limitMB defaultMB: UInt64 = 2048) {
        let limitMB = ProcessInfo.processInfo.environment["ISNOW_MEMLIMIT_MB"].flatMap { UInt64($0) } ?? defaultMB
        let limit = limitMB * 1024 * 1024
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS && info.phys_footprint > limit {
                fputs("iSnow debug render: over \(limitMB) MB of memory – stopped (runaway loop?)\n", stderr)
                exit(3)
            }
        }
        t.resume()
        timer = t
    }
}
