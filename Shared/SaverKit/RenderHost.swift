// The contract between `SaverView` and whatever actually draws.
//
// There are two hosts — SceneKit for the aquarium, raw Metal for the field-simulation and
// space savers — and they share one `CAMetalLayer`, one display link and one resize path.
// Keeping that plumbing in `SaverView` and handing a host nothing but a command buffer and
// a pass descriptor is what lets a saver pick either one, or composite both into a single
// drawable, without either host knowing the other exists.
//
// Everything here is `internal`: `tools/build-saver.sh` compiles SaverKit and the saver's
// own sources into a single module per bundle, so there is no cross-module boundary to
// annotate.

import Foundation
import Metal
import QuartzCore

/// Everything a host needs to build its GPU resources, handed over once at creation.
struct HostContext {
    let device: MTLDevice

    /// The bundle to load assets from.
    ///
    /// Always this, never `Bundle.main` — inside a screensaver `Bundle.main` is
    /// `legacyScreenSaver.appex`, not us, so `Bundle.main` silently finds nothing.
    let bundle: Bundle

    /// True when the view is small enough to be the System Settings thumbnail.
    ///
    /// Derived from view size rather than `ScreenSaverView.isPreview`, which is unreliable
    /// on Tahoe. A host should use this to cut particle counts and skip expensive passes,
    /// not to change the composition — the preview should look like the real thing.
    let isPreview: Bool

    /// Size in *pixels*, not points.
    ///
    /// Deliberately not accompanied by a backing scale. A host is created on the first layout
    /// with a usable size, and that layout routinely happens *before* the view is in a window
    /// — at which point the layer's scale is still 1 whatever display it is about to land on.
    /// A creation-time scale would therefore be a value that is quietly wrong on exactly the
    /// displays it exists for. The scale arrives with `RenderTargets`, which is delivered
    /// before any frame is encoded and again whenever it changes.
    let drawableSize: CGSize
}

/// The render targets `SaverView` actually created, which is not always what the host asked
/// for — `sampleCount` here is the *effective* count after clamping to device support.
///
/// A host must build any pipeline state from these values rather than from its own declared
/// preferences. Requesting 8x MSAA on a device that supports 4x and then building a pipeline
/// for 8x produces a pipeline that does not match the attachments, which is a Metal
/// validation failure rather than a graceful downgrade.
struct RenderTargets {
    let drawableSize: CGSize
    let sampleCount: Int
    let colorPixelFormat: MTLPixelFormat
    let depthPixelFormat: MTLPixelFormat

    /// Pixels per point: 1 on a conventional display, 2 on a Retina one.
    ///
    /// The one property of the drawable a resize can change without changing its shape, and
    /// the only place a host can learn it. Anything sized in target pixels that should look
    /// the same physical size to a viewer must be multiplied by this — SceneKit's
    /// post-process radii are the case that prompted it. `SCNCamera.bloomBlurRadius` is
    /// documented in points and measured to be applied in render-target pixels, so an
    /// unscaled radius arrives on a Retina display at half its intended apparent size.
    ///
    /// It changes under a live view: attaching, mirroring or unplugging a display moves a
    /// window between scales, and the very first resize after host creation usually carries
    /// the real value in place of the provisional 1 the host was built under.
    let backingScale: CGFloat
}

/// State for a single frame.
struct FrameContext {
    /// Seconds since animation started, taken from the display link's `targetTimestamp` —
    /// the vsync this frame is *for*, not the one that just happened. Using it removes a
    /// frame of latency.
    let time: CFTimeInterval

    /// Seconds since the previous frame, clamped to survive the pause between
    /// `stopAnimation()` and `startAnimation()` without a simulation explosion.
    let deltaTime: CFTimeInterval

    let drawableSize: CGSize
    let commandBuffer: MTLCommandBuffer

    /// Colour attachment 0 and the depth attachment are already configured, including MSAA
    /// resolve when `sampleCount > 1`. A host that just wants SceneKit to draw can hand
    /// this straight to `SCNRenderer`; a raw host encodes against it.
    let passDescriptor: MTLRenderPassDescriptor
}

protocol RenderHost: AnyObject {
    var colorPixelFormat: MTLPixelFormat { get }
    var depthPixelFormat: MTLPixelFormat { get }

    /// Requested MSAA sample count. `SaverView` clamps this to what the device actually
    /// supports — asking an M1 Max for 8x is a hard assertion inside Metal, not a nil
    /// return, so the clamp is not optional.
    var sampleCount: Int { get }

    /// Ignored when a SceneKit host enables HDR: SceneKit renders into its own buffer and
    /// composites the tone-mapped result, discarding both this and the drawable's alpha.
    /// Set `scene.background.contents` in that case. See `SceneKitHost`.
    var clearColor: MTLClearColor { get }

    /// Called after the attachments exist and before any frame is encoded against them, so
    /// this is the correct place to build pipeline state that depends on sample count or
    /// pixel format.
    func hostDidResize(to targets: RenderTargets, device: MTLDevice)
    func encode(_ frame: FrameContext)
    func teardown()
}

// These defaults are STATICALLY dispatched. A conforming class that does not redeclare a
// member freezes its witness to the value here, and a subclass's override is then silently
// ignored when SaverView reads it through the protocol. Any class in this file's hierarchy
// meant to be subclassed must redeclare every member it wants subclasses to customise —
// see `MetalHost`.
extension RenderHost {
    var colorPixelFormat: MTLPixelFormat { .bgra8Unorm }
    var depthPixelFormat: MTLPixelFormat { .depth32Float }
    var sampleCount: Int { 4 }
    var clearColor: MTLClearColor { MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1) }

    func hostDidResize(to targets: RenderTargets, device: MTLDevice) {}
    func teardown() {}
}
