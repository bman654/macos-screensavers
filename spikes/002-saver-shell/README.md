# Spike 002 — native `.saver` shell and raw Metal probe

**Question:** can the shared saver shell hand a drawable to a raw Metal host, load its
shaders without an offline Metal compiler, and animate a full-screen pass?

**Answer:** yes, and it was then confirmed in the real thing. Both probes were installed to
`~/Library/Screen Savers` and rendered correctly in the System Settings preview, driven by
Tahoe's sandboxed `legacyScreenSaver`.

**The load-bearing result: runtime Metal shader compilation is permitted inside the
sandbox.** `legacyScreenSaver` logs `(Metal) Metal Compiling Shader` while the probe
animates. Since Command Line Tools ship no offline Metal compiler, this is what makes the
whole shader-based half of `docs/saver-backlog.md` buildable on a machine without Xcode. If
it had failed, every field-simulation and space saver would have required a Metal toolchain
before it could ship.

## Reproduce

The verification driver is intentionally throwaway rather than another maintained shell.
It compiles `RenderHost.swift`, `SaverView.swift`, `ShaderLibrary.swift`, `MetalHost.swift`
and the MetalProbe sources together with:

```bash
swiftc -O -target arm64-apple-macosx26.0 \
    -framework AppKit -framework Metal -framework MetalKit \
    -framework QuartzCore -framework ScreenSaver \
    <sources> /tmp/metal-verify/Driver.swift -o /tmp/metal-verify/driver
/tmp/metal-verify/driver
```

The test bundle contains `Contents/Resources/Shaders/MetalProbe.metal` and deliberately
contains no `default.metallib`. The driver renders offscreen at several explicit time
values and writes PNGs before exiting.

## What held

- **One raw render pass is enough.** A vertex-ID full-screen triangle and a time uniform
  produce the animated plasma without vertex buffers, textures or simulation machinery.
- **The source fallback works outside the screensaver sandbox.** The loader first reports
  that no default library exists, finds `.metal` files under `Resources/Shaders`, and
  successfully compiles them with `makeLibrary(source:options:)`.
- **The host boundary is sufficient.** The probe only needs the supplied command buffer,
  render-pass descriptor, drawable size and timeline. It does not need access to the
  `CAMetalLayer` or drawable.
- **Failure is diagnosable.** A deliberately invalid fallback shader reports both the
  failed `default.metallib` attempt and the runtime compiler diagnostic, including the
  source path and the sandbox-specific suspicion.

## What did not

- **There is no offline Metal compiler in Command Line Tools.** `xcrun -sdk macosx metal`
  and `xcrun -sdk macosx metallib` both fail with exit 72, so this machine cannot produce
  `default.metallib`. The runtime path is therefore the only one this repo can currently
  exercise — which also means `ShaderLibrary`'s preferred `default.metallib` branch and
  `build-saver.sh`'s precompile branch are both **unverified**, and will stay that way until
  someone builds here with a Metal toolchain installed.

## Traps found, and why the code looks the way it does

- **The screensaver bundle is not `Bundle.main`.** At runtime the main bundle belongs to
  `legacyScreenSaver.appex`; shader lookup must start from `HostContext.bundle`.
- **Try the metallib before source.** A machine with the full Metal toolchain should use
  its precompiled default library without paying runtime compile cost. Source is a
  compatibility path, not the preferred production path.
- **A source fallback must preserve useful diagnostics.** Reporting only the runtime
  compiler error hides whether the metallib was missing; reporting only the metallib
  error hides whether sandboxed source compilation failed. The final error includes both.
- **The pipeline still declares the supplied depth format.** The probe does not depth-test,
  but its render pass has a depth attachment configured by `SaverView`; the pipeline
  descriptor must match that attachment.
- **MSAA adds nothing to a full-screen triangle.** The probe requests one sample, avoiding
  an extra color attachment and resolve for a shader that covers every pixel analytically.
- **Do not create a second frame transaction.** The saver owns presentation and hands the
  host its command buffer. The host encodes into that buffer rather than committing a
  separate one for each pass.

- **Shader source files share one translation unit.** The fallback concatenates every
  `.metal` file in the bundle before compiling, so two files declaring the same file-scope
  name collide, and `#include` of a project header does not resolve — `makeLibrary(source:)`
  has no include search path. Neither fails on a machine with the Metal toolchain, which is
  the worst possible direction for a trap. Documented on `ShaderLibrary`.

## Not addressed here

Compute ping-pong textures for the field simulations, multi-display behaviour (this machine
has one display), and the `default.metallib` path described above.
