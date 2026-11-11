import Metal
import QuartzCore

/// Minimal Metal renderer: one instanced draw call for all particles
/// and one for triangles (drifts, icicles, snowman). Shaders are compiled from source.
@MainActor
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let particlePipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState

    /// Shaders. Mesh vertices normally carry a plain colour in 0…1. Snow vertices built by the `Mesh.snow…`
    /// helpers carry a *material* instead (see `Mesh.snowMaterial`): the red channel is offset by 2048·kind
    /// (kind 1 = drift: red = depth below the surface in points, green = gradient 0 top…1 base; kind 2 = snow
    /// ball: plain colour), green/blue hold a per-shape anchor (quarter points, mod 512) in their integer part,
    /// so the procedural grain moves with the drift/ball instead of sliding over it. Alpha is always the real
    /// alpha, so code that fades vertices (`a *= …`) keeps working. Plain colours never exceed 1024.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 size; float scale; float time; float4 tint; };

    static float hash1(uint2 c) {
        uint h = c.x * 0x8da6b343u + c.y * 0xd8163841u + 0x9e3779b9u;
        h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
        return float(h) * (1.0 / 4294967296.0);
    }
    // Value noise, q in cells, periodic with `period` cells (a power of two).
    static float vnoise(float2 q, uint period) {
        float2 i = floor(q); float2 f = q - i; f = f * f * (3.0 - 2.0 * f);
        uint m = period - 1u;
        uint2 c = as_type<uint2>(int2(i));
        uint x0 = c.x & m, x1 = (c.x + 1u) & m, y0 = c.y & m, y1 = (c.y + 1u) & m;
        float a = hash1(uint2(x0, y0)), b = hash1(uint2(x1, y0));
        float e = hash1(uint2(x0, y1)), d = hash1(uint2(x1, y1));
        return mix(mix(a, b, f.x), mix(e, d, f.x), f.y);
    }
    static float band(float lo, float hi, float x) { return 1.0 - smoothstep(lo, hi, x); }

    struct P { float4 pos [[position]]; float2 uv; float alpha; float hard; float size; float2 ruv; float seed; };
    vertex P particle_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device float4* inst [[buffer(0)]], constant U& u [[buffer(1)]]) {
        float4 d = inst[iid];
        float s = abs(d.z);                       // negative size = solid snow clump
        float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float2 p = d.xy + c * s * 0.5;
        P o; o.pos = float4(p / u.size * 2.0 - 1.0, 0.0, 1.0); o.uv = c; o.alpha = d.w;
        o.hard = d.z < 0.0 ? 1.0 : 0.0; o.size = s;
        // Slow tumble: the pattern turns as the particle travels (flakes by position, clumps roll).
        float ang = d.z < 0.0 ? (d.x + 0.4 * d.y) / max(s, 1.0) * 0.6 : (d.x * 0.011 + d.y * 0.017);
        float cs = cos(ang), sn = sin(ang);
        o.ruv = float2(c.x * cs - c.y * sn, c.x * sn + c.y * cs);
        o.seed = fract(s * 7.31);
        return o;
    }
    fragment float4 particle_fs(P in [[stage_in]], constant U& u [[buffer(0)]]) {
        float r = length(in.uv);
        float a;
        float3 col;
        if (in.hard > 0.5) {
            // Clump: crisp edge, lit from the top left, bluish shade bottom right – visible on white.
            a = smoothstep(1.0, 0.82, r) * in.alpha;
            float light = clamp(0.5 + 0.5 * dot(normalize(float2(-0.6, 0.8)), in.uv) - r * 0.25, 0.0, 1.0);
            col = mix(float3(0.76, 0.83, 0.94), float3(1.0), light);
            // Packed-snow surface: soft dents and a few bright crystals that roll with the clump.
            float2 q = in.ruv * 2.3 + in.seed * 37.0;
            float m = vnoise(q, 256u) * 0.65 + vnoise(q * 2.7 + 11.0, 256u) * 0.35;
            col = mix(col, float3(0.70, 0.78, 0.92), smoothstep(0.45, 0.85, m) * 0.24 * (1.0 - 0.4 * light));
            col = mix(col, float3(1.0), band(0.08, 0.30, m) * 0.5);
        } else {
            a = smoothstep(1.0, 0.25, r) * in.alpha;
            col = mix(float3(1.0), float3(0.80, 0.85, 0.93), r * r * 0.7);
            // Big flakes: a faint six-armed crystal inside the soft disc.
            float k = smoothstep(4.8, 7.0, in.size);
            if (k > 0.0) {
                float2 v = in.ruv;
                float d0 = abs(v.y);
                float d1 = abs(dot(v, float2(0.8660254, 0.5)));
                float d2 = abs(dot(v, float2(-0.8660254, 0.5)));
                float w = 0.05 + 0.4 / in.size;                 // keep arms about half a point wide
                float arm = band(w * 0.5, w * 1.6, min(d0, min(d1, d2))) * band(0.55, 0.9, r);
                float core = band(0.10, 0.32, r);
                float soft = smoothstep(1.0, 0.25, r);
                float shape = max(soft * (1.0 - 0.3 * k), max(arm, core) * k);
                a = shape * in.alpha;
                col = mix(col, float3(1.0), max(arm, core) * k);
            }
        }
        col *= u.tint.rgb;
        return float4(col * a, a);
    }

    struct V { packed_float2 pos; packed_float4 color; };
    struct M { float4 pos [[position]]; float4 color; float4 mat [[flat]]; };
    vertex M mesh_vs(uint vid [[vertex_id]], const device V* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
        M o; o.pos = float4(float2(v[vid].pos) / u.size * 2.0 - 1.0, 0.0, 1.0); o.color = float4(v[vid].color);
        o.mat = o.color; return o;
    }

    // Grain shared by drifts and snow balls: soft cool mottling plus fine powder grain (q in points).
    static float3 snowGrain(float3 col, float2 q, float amount) {
        float m = vnoise(q * 0.0625, 32u) * 0.65 + vnoise(q * 0.125 + 0.5, 64u) * 0.35;
        float g = vnoise(q, 512u);
        float3 shade = float3(0.79, 0.85, 0.96);
        col = mix(col, shade, smoothstep(0.45, 0.85, m) * 0.20 * amount);          // cool hollows
        col = mix(col, float3(1.0), band(0.15, 0.45, m) * 0.30 * amount);         // wind-polished patches
        col += (g - 0.5) * float3(0.032, 0.028, 0.018) * amount;                   // powder grain
        return min(col, float3(1.0));
    }

    // Tiny glints on a 16-pt grid (deterministic per cell), twinkling slowly.
    static float glint(float2 q, float t, float density) {
        float2 cell = floor(q * 0.0625);
        uint2 ci = as_type<uint2>(int2(cell)) & 31u;
        float h = hash1(ci + uint2(101u, 37u));
        if (h > density) return 0.0;
        float2 gp = (cell + 0.2 + 0.6 * float2(hash1(ci + uint2(7u, 0u)), hash1(ci + uint2(0u, 9u)))) * 16.0;
        float2 d = abs(q - gp);
        float ph = hash1(ci + uint2(3u, 5u));
        float tw = smoothstep(0.35, 1.0, sin(t * (0.6 + 1.2 * ph) + ph * 40.0));
        float core = band(0.25, 0.85, length(d));
        float arms = max(band(0.15, 0.4, d.x) * band(0.4, 2.2, d.y), band(0.15, 0.4, d.y) * band(0.4, 2.2, d.x));
        return max(core, arms * 0.65) * tw;
    }

    fragment float4 mesh_fs(M in [[stage_in]], constant U& u [[buffer(0)]]) {
        if (in.mat.r < 1024.0) return float4(in.color.rgb * in.color.a, in.color.a);
        float kind = floor(in.mat.r / 2048.0);
        float2 anc = floor(in.mat.gb * 0.25);
        float3 v = in.color.rgb - float3(kind * 2048.0, anc * 4.0);
        float2 p = float2(in.pos.x, u.size.y * u.scale - in.pos.y) / u.scale;    // points, y up
        float2 q = p - anc * 0.25;                                                // anchored, 512-periodic
        float a = in.color.a;
        float3 col;
        if (kind < 1.5) {
            // Drift: crisp bright crust on top, a faint cool shadow under it, mottled body, glints.
            float depth = max(v.r, 0.0), grad = clamp(v.g, 0.0, 1.0);
            float h = depth / max(grad, 0.001);                                   // column height here
            col = mix(float3(0.975, 0.985, 1.0), float3(0.84, 0.89, 0.97), grad);
            float thin = smoothstep(2.0, 7.0, h);
            float shadow = smoothstep(0.9, 2.2, depth) * band(2.6, 7.0, depth) * thin;
            col = mix(col, float3(0.80, 0.86, 0.96), shadow * 0.28);
            col = snowGrain(col, q, smoothstep(0.8, 3.0, depth));
            float crust = band(0.7, 1.5, depth);
            col = mix(col, float3(1.0), crust);
            a = mix(a, 1.0, crust * 0.8);
            float gl = glint(q, u.time, 0.42) * smoothstep(2.5, 4.0, depth);
            col = mix(col, float3(1.0), gl);
            a = max(a, gl);
            col *= u.tint.rgb;
        } else {
            // Snow ball (snowman): keep its shading, add the same grain (no tint – as before).
            col = snowGrain(v, q, 0.8);
            float gl = glint(q * 1.3, u.time, 0.3);
            col = mix(col, float3(1.0), gl);
        }
        return float4(col * a, a);
    }
    """

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            func pipeline(_ vs: String, _ fs: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: vs)
                d.fragmentFunction = lib.makeFunction(name: fs)
                let a = d.colorAttachments[0]!
                a.pixelFormat = .bgra8Unorm
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            particlePipeline = try pipeline("particle_vs", "particle_fs")
            meshPipeline = try pipeline("mesh_vs", "mesh_fs")
        } catch {
            NSLog("iSnow: shader error – \(error)")
            return nil
        }
    }

    func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.maximumDrawableCount = 2
        layer.backgroundColor = .clear
    }

    var tint = SIMD3<Float>(1, 1, 1)
    /// Clock for twinkling glints (wrapped hourly so Float stays precise).
    private let startTime = CACurrentMediaTime()

    func draw(layer: CAMetalLayer, size: CGSize, particles: [Particle], mesh: [Vertex], buffers: inout FrameBuffers) {
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else { return }
        encode(cmd: cmd, texture: drawable.texture, size: size, particles: particles, mesh: mesh, buffers: &buffers)
        cmd.present(drawable)
        cmd.commit()
        buffers.advance()
    }

    /// Render into a texture (debug snapshot without a window).
    func render(to texture: MTLTexture, size: CGSize, particles: [Particle], mesh: [Vertex]) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        var b = FrameBuffers()
        encode(cmd: cmd, texture: texture, size: size, particles: particles, mesh: mesh, buffers: &b)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func encode(cmd: MTLCommandBuffer, texture: MTLTexture, size: CGSize, particles: [Particle],
                        mesh: [Vertex], buffers: inout FrameBuffers) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let w = Float(max(1, size.width))
        let clock = Float((CACurrentMediaTime() - startTime).truncatingRemainder(dividingBy: 3600))
        var u = Uniforms(size: SIMD2(Float(size.width), Float(size.height)), scale: Float(texture.width) / w,
                         time: clock, tint: SIMD4(tint, 1))

        if !mesh.isEmpty, let buf = buffers.mesh(device: device, count: mesh.count) {
            mesh.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            enc.setRenderPipelineState(meshPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
        }
        if !particles.isEmpty, let buf = buffers.particles(device: device, count: particles.count) {
            particles.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            enc.setRenderPipelineState(particlePipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: particles.count)
        }
        enc.endEncoding()
    }
}

/// Triple ring buffer – the CPU never overwrites data the GPU is still reading.
struct FrameBuffers {
    private var meshBufs: [MTLBuffer?] = [nil, nil, nil]
    private var partBufs: [MTLBuffer?] = [nil, nil, nil]
    private var index = 0

    mutating func mesh(device: MTLDevice, count: Int) -> MTLBuffer? {
        get(&meshBufs, device: device, bytes: count * MemoryLayout<Vertex>.stride)
    }

    mutating func particles(device: MTLDevice, count: Int) -> MTLBuffer? {
        get(&partBufs, device: device, bytes: count * MemoryLayout<Particle>.stride)
    }

    private func get(_ arr: inout [MTLBuffer?], device: MTLDevice, bytes: Int) -> MTLBuffer? {
        if let b = arr[index], b.length >= bytes { return b }
        let cap = max(4096, Int(Double(bytes) * 1.5))
        arr[index] = device.makeBuffer(length: cap, options: .storageModeShared)
        return arr[index]
    }

    mutating func advance() { index = (index + 1) % 3 }
}

/// Matches `U` in the shader: 32 B, 16-byte aligned.
struct Uniforms {
    var size: SIMD2<Float>
    var scale: Float          // pixels per point
    var time: Float           // seconds, for twinkling glints
    var tint: SIMD4<Float>
}
