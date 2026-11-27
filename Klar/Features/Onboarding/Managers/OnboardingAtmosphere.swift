import AppKit
import Metal
import QuartzCore

/// The mist around the setup's window, outside its frame. Fog lies over the
/// screen as the setup starts, and a field opens from the window's middle,
/// pushing it outward and leaving the window in clear air (`rollIn`). The
/// mist keeps drifting toward the window while the screens show, held off
/// by the field. As the window grows into the browser, the field rides on
/// its edges and pushes the mist off the screen (`clear`).
///
/// Drawn by a Metal shader in a click-through window behind the setup's,
/// over its screen: two layers of soft, slowly changing billows, drawn
/// toward the window and held off by a field around it, where they gather
/// and slide along its edge. The shader is compiled from
/// source at runtime, so the build needs no Metal toolchain; it's drawn at
/// half the screen's points, as mist has no detail to lose, at 60 frames a
/// second while it clears and 30 while it only drifts.
final class OnboardingAtmosphere: NSObject {
    /// Drawable pixels per point
    private static let renderScale: CGFloat = 0.5
    /// How far out from the window's edges the field holds the mist, and
    /// how deep its edge is, where the mist gathers
    private static let settledRadius: Float = 12
    private static let feather: Float = 320
    /// As the window grows into the browser: the field rides on its edges,
    /// the mist no longer gathering against it (pressed up there, it showed
    /// as a ring), and its edge widens as it pushes the mist away
    private static let pressedRadius: Float = 0
    private static let pressedFeather: Float = 200
    private static let clearingFeather: Float = 480
    /// No field yet: mist all over, the window's place included (its
    /// middle is 200 points inside its edges)
    private static let coveredRadius: Float = -260

    private let overlay: NSWindow
    private weak var window: NSWindow?
    private let screenFrame: CGRect
    private let metalLayer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let reduceMotion: Bool
    private var uniforms: MistUniforms
    private var link: CADisplayLink?
    private let createdAt = CACurrentMediaTime()
    private var rollInStart: CFTimeInterval?
    private var clearStart: CFTimeInterval?
    private var clearCompletion: (() -> Void)?
    /// Where the window is seen, while something else draws it growing
    private var frameSource: (() -> CGRect?)?

    /// Nil without Metal, or if the shader doesn't compile: no mist then
    init?(around window: NSWindow, reduceMotion: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "mistVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "mistFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            logError(.general, "Onboarding's mist shader didn't compile: \(error)")
            return nil
        }
        self.queue = queue
        self.window = window
        self.reduceMotion = reduceMotion

        let screen = window.screen ?? NSScreen.main
        screenFrame = screen?.frame ?? window.frame
        let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        uniforms = MistUniforms(
            size: SIMD2(Float(screenFrame.width), Float(screenFrame.height)),
            dark: isDark ? 1 : 0
        )

        let overlay = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        overlay.isExcludedFromWindowsMenu = true
        overlay.animationBehavior = .none

        self.overlay = overlay
        super.init()

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.contentsScale = screen?.backingScaleFactor ?? 2
        metalLayer.drawableSize = CGSize(
            width: (screenFrame.width * Self.renderScale).rounded(),
            height: (screenFrame.height * Self.renderScale).rounded()
        )
        let view = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        // Layer-hosting: AppKit leaves the layer be
        view.layer = metalLayer
        view.wantsLayer = true
        overlay.contentView = view
        overlay.order(.below, relativeTo: window.windowNumber)
    }

    // MARK: - Moving

    /// Over everything, then clearing from the middle as the window arrives
    func rollIn() {
        rollInStart = CACurrentMediaTime()
        startDrawing()
    }

    /// Clears away as the window grows, then closes. `completion` once it's
    /// gone.
    func clear(completion: @escaping () -> Void) {
        clearStart = CACurrentMediaTime()
        clearCompletion = completion
        startDrawing()
        setFrameRate(60)
    }

    /// The field follows this frame instead of the window's, while the
    /// window is drawn by a stand-in
    func follow(_ source: @escaping () -> CGRect?) {
        frameSource = source
    }

    /// Gone at once
    func dismiss() {
        link?.invalidate()
        link = nil
        overlay.close()
    }

    private func startDrawing() {
        guard link == nil else { return }
        let link = overlay.displayLink(target: self, selector: #selector(draw(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        setFrameRate(60)
    }

    private func setFrameRate(_ rate: Float) {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
    }

    // MARK: - Drawing

    @objc private func draw(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        guard update(at: now) else {
            dismiss()
            clearCompletion?()
            clearCompletion = nil
            return
        }
        guard let drawable = metalLayer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MistUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// The mist at `now`. False once it has cleared away.
    private func update(at now: CFTimeInterval) -> Bool {
        // Around the window as it is, also while it grows
        if let frame = frameSource?() ?? window?.frame {
            uniforms.center = SIMD2(Float(frame.midX - screenFrame.minX), Float(screenFrame.maxY - frame.midY))
            uniforms.halfSize = SIMD2(Float(frame.width / 2), Float(frame.height / 2))
        }
        uniforms.time = reduceMotion ? 0 : Float(now - createdAt)

        if let clearStart {
            let elapsed = now - clearStart
            if reduceMotion {
                uniforms.opacity = 1 - Float(min(elapsed / 0.6, 1))
                return elapsed < 0.6
            }
            // The field rides on the window's edges as it grows, then calmly
            // pushes the mist on past the screen's edges, its edge softening
            // as it goes and the last of the mist fading
            let press = Float(Self.smoothstep(0, 0.7, elapsed))
            let push = Float(Self.easeInOut(min(max((elapsed - 0.5) / 2.8, 0), 1)))
            let distance = Float(max(screenFrame.width, screenFrame.height) * 0.6)
            uniforms.gather = 1 - Float(Self.smoothstep(0, 0.9, elapsed))
            uniforms.feather = Self.feather + (Self.pressedFeather - Self.feather) * press + (Self.clearingFeather - Self.pressedFeather) * push
            uniforms.clearRadius = Self.settledRadius + (Self.pressedRadius - Self.settledRadius) * press + push * distance
            uniforms.opacity = 1 - Float(Self.smoothstep(2, 3.3, elapsed))
            return elapsed < 3.35
        }

        uniforms.feather = Self.feather
        uniforms.gather = 1

        let elapsed = now - (rollInStart ?? now)
        if reduceMotion {
            uniforms.clearRadius = Self.settledRadius
            uniforms.opacity = Float(min(elapsed / 0.6, 1))
            return true
        }
        // Drifting in over 1.6 s, then the field opens from the window's
        // middle and gently pushes the mist out over 2.8 s
        uniforms.opacity = Float(Self.smoothstep(0, 1.6, elapsed))
        let clearing = Float(Self.easeInOut(min(max((elapsed - 0.6) / 2.8, 0), 1)))
        uniforms.clearRadius = Self.coveredRadius + (Self.settledRadius - Self.coveredRadius) * clearing
        if elapsed > 3.6 {
            setFrameRate(30)
        }
        return true
    }

    /// Slow in, slow out
    private static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// As `MistUniforms` in the shader
    private struct MistUniforms {
        /// The screen, in points
        var size: SIMD2<Float>
        /// The window's center, from the screen's top left, y down
        var center = SIMD2<Float>(0, 0)
        var halfSize = SIMD2<Float>(0, 0)
        var time: Float = 0
        /// How far out from the window's edge the air is clear
        var clearRadius: Float = OnboardingAtmosphere.coveredRadius
        var feather: Float = OnboardingAtmosphere.feather
        var opacity: Float = 0
        var dark: Float
        /// How much the mist gathers against the field, 0 to 1
        var gather: Float = 1
    }

    // MARK: - Shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MistUniforms {
        float2 size;
        float2 center;
        float2 halfSize;
        float time;
        float clearRadius;
        float feather;
        float opacity;
        float dark;
        float gather;
    };

    struct MistVertex {
        float4 position [[position]];
        float2 uv;
    };

    // A triangle over the whole screen, uv from the top left
    vertex MistVertex mistVertex(uint id [[vertex_id]]) {
        float2 corner = float2(float((id << 1) & 2), float(id & 2));
        MistVertex out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    static float hash(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }

    static float noise(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float a = hash(i);
        float b = hash(i + float3(1, 0, 0));
        float c = hash(i + float3(0, 1, 0));
        float d = hash(i + float3(1, 1, 0));
        float e = hash(i + float3(0, 0, 1));
        float g = hash(i + float3(1, 0, 1));
        float h = hash(i + float3(0, 1, 1));
        float k = hash(i + float3(1, 1, 1));
        return mix(mix(mix(a, b, u.x), mix(c, d, u.x), u.y),
                   mix(mix(e, g, u.x), mix(h, k, u.x), u.y), u.z);
    }

    // Octaves turned against each other, so no grid shows; the finer ones
    // change faster, as small eddies do
    static float fbm(float3 p, int octaves) {
        const float2x2 turn = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
        float value = 0.0;
        float amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            value += amplitude * noise(p);
            p.xy = turn * p.xy * 2.03 + float2(3.1, 1.7);
            p.z *= 1.8;
            amplitude *= 0.5;
        }
        return value;
    }

    // Soft billows: noise, barely warped, changing slowly
    static float mistDensity(float2 p, float t) {
        float3 q = float3(p, t * 0.03);
        float2 warp = float2(fbm(q, 2), fbm(q + float3(5.2, 1.3, 3.7), 2)) - 0.5;
        return fbm(float3(p + 0.55 * warp, t * 0.04), 4);
    }

    // The mist carried along `flow` (points per cycle): two phases of the
    // cycle crossfaded, so it keeps moving without stretching
    static float flowingDensity(float2 point, float scale, float2 drift, float2 flow, float t) {
        float cycle = t / 9.0;
        float phaseA = fract(cycle);
        float phaseB = fract(cycle + 0.5);
        float weightA = 1.0 - abs(2.0 * phaseA - 1.0);
        float a = mistDensity((point - flow * phaseA) / scale + drift, t);
        float b = mistDensity((point - flow * phaseB) / scale + drift + float2(3.7, 8.1), t);
        return mix(b, a, weightA);
    }

    fragment float4 mistFragment(MistVertex in [[stage_in]], constant MistUniforms &u [[buffer(0)]]) {
        float2 point = in.uv * u.size;
        float t = u.time;
        float2 fromWindow = point - u.center;
        float2 outward = normalize(fromWindow + float2(0.001, 0.0));
        float2 along = float2(-outward.y, outward.x);

        // A field around the window, a rounded box grown by clearRadius, its
        // edge wavering slowly: how far outside it this point is
        float2 q = abs(fromWindow) - u.halfSize + 24.0;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 24.0;
        float waver = (fbm(float3(point / 420.0, t * 0.05 + 11.0), 3) - 0.5) * 130.0;
        float outside = distance + waver - u.clearRadius;

        // Drawn toward the window, slowing as it meets the field and
        // sliding along it there
        float approach = smoothstep(0.0, 420.0, outside);
        float2 flow = -outward * 130.0 * (0.25 + 0.75 * approach) + along * 60.0 * (1.0 - approach);

        // Far: smaller billows; near: broad ones, carried a little faster
        float far = flowingDensity(point, 640.0, float2(t * 0.006, t * 0.002), flow, t);
        float near = flowingDensity(point, 1150.0, float2(7.3 + t * 0.012, 2.1), flow * 1.4, t * 1.2 + 40.0);
        float farThickness = smoothstep(0.26, 0.66, far);
        float nearThickness = smoothstep(0.30, 0.72, near);
        float alpha = nearThickness * 0.55 + farThickness * 0.6 * (1.0 - nearThickness * 0.55);
        float thickness = max(farThickness, nearThickness);

        // Held off by the field, gathering softly against it
        float held = smoothstep(-20.0, u.feather, outside);
        float gathered = exp(-pow((outside - u.feather * 0.8) / u.feather, 2.0));

        bool dark = u.dark > 0.5;
        float3 shade = dark ? float3(0.50, 0.54, 0.61) : float3(0.76, 0.79, 0.84);
        float3 light = dark ? float3(0.86, 0.89, 0.95) : float3(0.99, 0.99, 1.0);
        // Brighter where it's thick, as light scatters more in it, and where
        // it gathers by the window
        float3 color = mix(shade, light, clamp(0.3 + 0.5 * thickness + 0.12 * gathered * u.gather, 0.0, 1.0));

        // A thin haze in between, the air itself
        alpha = alpha + 0.05 * (1.0 - alpha);
        alpha *= held * (0.8 + 0.55 * gathered * u.gather) * u.opacity * (dark ? 0.85 : 0.95);
        alpha = min(alpha, 1.0);
        // Against banding in the soft gradients
        float dither = (hash(float3(point, t * 60.0)) - 0.5) / 255.0;
        return float4(color * alpha + dither, alpha);
    }
    """
}
