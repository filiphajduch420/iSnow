import AppKit
import QuartzCore

final class MetalView: NSView {
    /// Pixels per point of the drawable (1 by default; the backing scale for Retina rendering).
    var renderScale: CGFloat = 1
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var isFlipped: Bool { false }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    // AppKit resets the layer's scale when the window's backing changes – keep ours.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if metalLayer.contentsScale != renderScale { metalLayer.contentsScale = renderScale }
    }
}

/// Transparent full-screen window; all clicks pass through it.
@MainActor
final class Overlay: NSObject {
    let screenID: CGDirectDisplayID
    let window: NSWindow
    let view: MetalView
    let sim: Simulation
    private let renderer: Renderer
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var particles: [Particle] = []
    private var mesh: [Vertex] = []
    private var buffers = FrameBuffers()
    private var renderScale: CGFloat = 0
    /// The effects are hidden: window ordered out, no frames.
    private(set) var hidden = false
    /// Screen asleep or locked: no frames, but the window stays.
    var suspended = false { didSet { if suspended { sleep() } } }
    var fps = 60 { didSet { if fps != oldValue { applyRate() } } }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Whether this overlay still fits `screen` (same display, same frame) and can be kept.
    func matches(_ screen: NSScreen) -> Bool {
        screenID == Self.displayID(of: screen) && sim.origin == screen.frame.origin && sim.size == screen.frame.size
    }

    init(screen: NSScreen, renderer: Renderer, hostsSnowman: Bool) {
        screenID = Self.displayID(of: screen)
        self.renderer = renderer
        sim = Simulation(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, hostsSnowman: hostsSnowman,
                         safeTop: screen.safeAreaInsets.top)
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        view = MetalView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.animationBehavior = .none
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        renderer.configure(view.metalLayer)
        setRenderScale(1)
        window.orderFrontRegardless()

        let dl = view.displayLink(target: self, selector: #selector(tick(_:)))
        dl.add(to: .main, forMode: .common)
        link = dl
        applyRate()
    }

    private func applyRate() {
        let maxRate = Float(fps)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(24, maxRate), maximum: maxRate, preferred: maxRate)
    }

    /// Drawable resolution: 1 pixel per point (cheap) or the screen's backing scale (Retina).
    func setRenderScale(_ scale: CGFloat) {
        guard scale > 0, scale != renderScale else { return }
        renderScale = scale
        view.renderScale = scale
        view.metalLayer.contentsScale = scale
        view.metalLayer.drawableSize = CGSize(width: (sim.size.width * scale).rounded(),
                                              height: (sim.size.height * scale).rounded())
        wake()
    }

    /// Keep the snow out of screenshots and screen sharing.
    func setHiddenFromCapture(_ on: Bool) {
        let t: NSWindow.SharingType = on ? .none : .readOnly
        if window.sharingType != t { window.sharingType = t }
    }

    /// Hide all effects (the simulation keeps its state) or bring them back.
    func setHidden(_ on: Bool) {
        guard on != hidden else { return }
        hidden = on
        if on {
            sleep()
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
            wake()                      // draw at least one frame with the kept state
        }
    }

    func wake() {
        guard !hidden, !suspended, let link, link.isPaused else { return }
        last = 0
        link.isPaused = false
    }

    func sleep() { link?.isPaused = true }

    func close() {
        link?.invalidate()
        link = nil
        window.orderOut(nil)
        window.close()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? 1.0 / 60 : min(1.0 / 20, now - last)
        last = now
        let m = NSEvent.mouseLocation
        let local = CGPoint(x: m.x - sim.origin.x, y: m.y - sim.origin.y)
        let inside = local.x >= 0 && local.y >= 0 && local.x <= sim.size.width && local.y <= sim.size.height
        let shovel = NSEvent.modifierFlags.contains(.option)
        sim.step(dt: dt, now: CACurrentMediaTime(), mouse: inside ? local : nil, shovel: shovel)
        particles.removeAll(keepingCapacity: true)
        mesh.removeAll(keepingCapacity: true)
        sim.buildParticles(into: &particles)
        sim.buildMesh(into: &mesh)
        let t = Settings.shared.config.tint
        renderer.tint = SIMD3(Float(t[safe: 0] ?? 1), Float(t[safe: 1] ?? 1), Float(t[safe: 2] ?? 1))
        renderer.draw(layer: view.metalLayer, size: view.bounds.size, particles: particles, mesh: mesh, buffers: &buffers)
        if !sim.isAnimating || hidden || suspended { link.isPaused = true }
    }
}

/// Small panel right above a snowman – the only place that catches clicks.
/// A click knocks the snowman; dragging carries it somewhere else.
@MainActor
final class SnowmanPanel {
    private let panel: NSPanel
    private let view = ClickView()
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onDrop: ((CGPoint) -> Void)?

    /// The user is carrying the snowman right now.
    var isDragging: Bool { view.dragging }

    /// Whether the panel is on screen and contains the global point `p` (plus a margin).
    func contains(_ p: CGPoint, margin: CGFloat = 0) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -margin, dy: -margin).contains(p)
    }

    /// Keep the click panel out of screenshots and screen sharing.
    func setHiddenFromCapture(_ on: Bool) {
        let t: NSWindow.SharingType = on ? .none : .readOnly
        if panel.sharingType != t { panel.sharingType = t }
    }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1, alpha: 0.002)   // almost transparent, but still clickable
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        view.onClick = { [weak self] p in self?.onClick?(p) }
        view.onDrag = { [weak self] p in self?.onDrag?(p) }
        view.onDrop = { [weak self] p in self?.onDrop?(p) }
        panel.contentView = view
    }

    /// `rect` in global coordinates, nil = hide.
    func update(_ rect: CGRect?) {
        if view.dragging { return }            // keep the panel still while dragging
        guard let rect else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if abs(panel.frame.minX - rect.minX) > 1 || abs(panel.frame.minY - rect.minY) > 1
            || abs(panel.frame.width - rect.width) > 1 || abs(panel.frame.height - rect.height) > 1 {
            panel.setFrame(rect, display: false)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() { panel.orderOut(nil) }

    final class ClickView: NSView {
        var onClick: ((CGPoint) -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onDrop: ((CGPoint) -> Void)?
        private(set) var dragging = false
        private var start: CGPoint = .zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            dragging = false
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            let p = NSEvent.mouseLocation
            if !dragging && hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true }
            if dragging { onDrag?(p) }
        }

        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
            let p = NSEvent.mouseLocation
            if dragging {
                dragging = false
                onDrop?(p)
            } else {
                onClick?(p)
            }
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
