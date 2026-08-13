import Foundation
import Metal

class MetalHost: RenderHost {
    let device: MTLDevice
    let shaders: ShaderLibrary

    // EVERY customisation point is redeclared here rather than inherited from `RenderHost`'s
    // protocol extension, and that is load-bearing. A protocol extension default is
    // statically dispatched: a member this class does not declare has its witness frozen to
    // the extension's value, so a subclass's override is SILENTLY IGNORED when SaverView
    // reads it through the protocol — compiling cleanly and rendering with the wrong
    // settings, or skipping the callback entirely. Declaring them here puts them in the
    // class's vtable. If you add a member to `RenderHost`, add it here too.
    var colorPixelFormat: MTLPixelFormat { .bgra8Unorm }
    var depthPixelFormat: MTLPixelFormat { .depth32Float }
    var sampleCount: Int { 4 }
    var clearColor: MTLClearColor { MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1) }

    func hostDidResize(to targets: RenderTargets, device: MTLDevice) {}
    func teardown() {}

    private var reportedEncoderFailure = false
    private var reportedMissingPassImplementation = false

    init(context: HostContext) throws {
        device = context.device
        shaders = try ShaderLibrary(device: context.device, bundle: context.bundle)
    }

    func encode(_ frame: FrameContext) {
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(
            descriptor: frame.passDescriptor) else {
            if !reportedEncoderFailure {
                NSLog("MetalHost: failed to create a render command encoder")
                reportedEncoderFailure = true
            }
            return
        }

        encodePass(frame, with: encoder)
        encoder.endEncoding()
    }

    /// Deliberately not `final`: a command buffer allows only one live encoder at a time,
    /// so a future compute host cannot open a compute encoder from inside `encodePass` —
    /// it overrides `encode`, does its compute work, then calls `super.encode(frame)`.
    /// Note that a *render* pass encoded before `super` would be erased, because the pass
    /// descriptor's colour `loadAction` is `.clear`.

    func encodePass(_ frame: FrameContext, with encoder: MTLRenderCommandEncoder) {
        if !reportedMissingPassImplementation {
            NSLog("MetalHost: %@ did not implement encodePass(_:with:)",
                  String(describing: type(of: self)))
            reportedMissingPassImplementation = true
        }
    }
}
