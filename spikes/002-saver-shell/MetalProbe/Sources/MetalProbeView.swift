import Foundation
import Metal

@objc(MetalProbeView)
final class MetalProbeView: SaverView {
    override func makeHost(_ context: HostContext) -> RenderHost? {
        do {
            return try MetalProbeHost(context: context)
        } catch {
            NSLog("MetalProbe: could not create the Metal render host: %@",
                  error.localizedDescription)
            return nil
        }
    }
}

final class MetalProbeHost: MetalHost {
    private var pipeline: MTLRenderPipelineState?
    private var pipelineSampleCount = 0
    private var reportedPipelineFailure = false

    // A full-screen triangle has no interior edges to alias, so MSAA would cost bandwidth
    // and change nothing. This is a fact about this probe, not about raw Metal hosts in
    // general — a saver drawing actual geometry should leave the default alone.
    override var sampleCount: Int { 1 }

    /// The pipeline is built here rather than in `init` because it must match the sample
    /// count `SaverView` actually allocated, which is the requested count clamped to what
    /// the device supports. Building it from this host's own request would produce a
    /// pipeline that disagrees with the attachments whenever the clamp changes anything —
    /// a Metal validation failure rather than a graceful downgrade.
    override func hostDidResize(to targets: RenderTargets, device: MTLDevice) {
        guard pipeline == nil || pipelineSampleCount != targets.sampleCount else { return }

        do {
            guard let vertexFunction = shaders.library.makeFunction(
                name: "metalProbeFullscreenVertex") else {
                throw MetalProbeError.missingShaderFunction("metalProbeFullscreenVertex")
            }
            guard let fragmentFunction = shaders.library.makeFunction(
                name: "metalProbeFragment") else {
                throw MetalProbeError.missingShaderFunction("metalProbeFragment")
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Metal Probe Full-Screen Pass"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = targets.colorPixelFormat
            descriptor.depthAttachmentPixelFormat = targets.depthPixelFormat
            descriptor.rasterSampleCount = targets.sampleCount
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelineSampleCount = targets.sampleCount
        } catch {
            pipeline = nil
            if !reportedPipelineFailure {
                NSLog("MetalProbe: could not build the render pipeline: %@",
                      error.localizedDescription)
                reportedPipelineFailure = true
            }
        }
    }

    override func encodePass(_ frame: FrameContext, with encoder: MTLRenderCommandEncoder) {
        guard let pipeline else { return }

        var uniforms = MetalProbeUniforms(
            resolution: SIMD2(Float(frame.drawableSize.width), Float(frame.drawableSize.height)),
            time: Float(Self.wrappedTime(frame.time)),
            padding: 0)

        encoder.label = "Metal Probe Full-Screen Pass"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<MetalProbeUniforms>.stride,
                                 index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Wraps the animation clock to the shader's exact repeat period, in `Double`, before it
    /// is narrowed to the `Float` the uniform carries.
    ///
    /// A screensaver on an unattended machine runs for days, and an ever-growing `Float`
    /// loses timing resolution as it does: by about 48 hours the ULP is 1/64 s, so the
    /// animation starts advancing in visibly uneven steps, and by a week only ~16 distinct
    /// values per second survive. Wrapping after the conversion cannot recover precision
    /// that the conversion already discarded, so it has to happen here.
    ///
    /// The period is exact rather than arbitrary: the shader's three time coefficients
    /// (1.15, 0.83, 0.57) each complete a whole number of cycles in 200π seconds — 115, 83
    /// and 57 respectively — so the wrap is seamless rather than a visible jump.
    private static func wrappedTime(_ time: CFTimeInterval) -> CFTimeInterval {
        time.truncatingRemainder(dividingBy: 200 * .pi)
    }
}

/// Mirrors the struct of the same name in `MetalProbe.metal`. The two are kept in sync by
/// hand because the runtime-compiled shader path cannot `#include` a shared header — see
/// `ShaderLibrary`. `padding` is what makes the layouts agree (16-byte stride, `float2`
/// 8-aligned); removing it looks safe and is not.
private struct MetalProbeUniforms {
    let resolution: SIMD2<Float>
    let time: Float
    let padding: Float
}

private enum MetalProbeError: LocalizedError {
    case missingShaderFunction(String)

    var errorDescription: String? {
        switch self {
        case .missingShaderFunction(let name):
            return "The loaded Metal shader library does not contain function '\(name)'."
        }
    }
}
