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

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 size; float2 pad; float4 tint; };
    struct P { float4 pos [[position]]; float2 uv; float alpha; float hard; };
    vertex P particle_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device float4* inst [[buffer(0)]], constant U& u [[buffer(1)]]) {
        float4 d = inst[iid];
        float s = abs(d.z);                       // negative size = solid snow clump
        float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float2 p = d.xy + c * s * 0.5;
        P o; o.pos = float4(p / u.size * 2.0 - 1.0, 0.0, 1.0); o.uv = c; o.alpha = d.w;
        o.hard = d.z < 0.0 ? 1.0 : 0.0; return o;
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
        } else {
            a = smoothstep(1.0, 0.25, r) * in.alpha;
            col = mix(float3(1.0), float3(0.80, 0.85, 0.93), r * r * 0.7);
        }
        col *= u.tint.rgb;
        return float4(col * a, a);
    }
    struct V { packed_float2 pos; packed_float4 color; };
    struct M { float4 pos [[position]]; float4 color; };
    vertex M mesh_vs(uint vid [[vertex_id]], const device V* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
        M o; o.pos = float4(float2(v[vid].pos) / u.size * 2.0 - 1.0, 0.0, 1.0); o.color = float4(v[vid].color); return o;
    }
    fragment float4 mesh_fs(M in [[stage_in]]) { return float4(in.color.rgb * in.color.a, in.color.a); }
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
            NSLog("Vločka: shader error – \(error)")
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
        var u = Uniforms(size: SIMD2(Float(size.width), Float(size.height)), pad: .zero, tint: SIMD4(tint, 1))

        if !mesh.isEmpty, let buf = buffers.mesh(device: device, count: mesh.count) {
            mesh.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            enc.setRenderPipelineState(meshPipeline)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
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

struct Uniforms {
    var size: SIMD2<Float>
    var pad: SIMD2<Float>
    var tint: SIMD4<Float>
}
