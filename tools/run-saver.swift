#!/usr/bin/env swift
// Run with `tools/run-saver.swift ...`, or compile with:
//   swiftc -framework AppKit -framework ScreenSaver -framework ScreenCaptureKit \
//     tools/run-saver.swift -o /tmp/run-saver
//
// A fresh process for every run avoids trusting a bundle still mmap()ed by a long-lived host.
// Screenshots capture only this process's window, which needs no Screen Recording permission.

import AppKit
import Foundation
import ScreenCaptureKit
import ScreenSaver

struct Options {
    var saverArgument: String
    var isPreview = false
    var size: NSSize?
    var seconds = 2.0
    var screenshotPath: String?

    /// Reshape the view partway through the run.
    ///
    /// Exists because a saver's response to an aspect-ratio change is real logic — the
    /// aquarium repositions its whole school — and it is otherwise unreachable from a
    /// harness that only ever renders one fixed size.
    var resizeTo: NSSize?
}

func usage(program: String) -> String {
    """
    usage: \(program) <Name|path-to.saver> [--preview] [--size WxH] [--seconds N]
           [--resize WxH] [--screenshot out.png]

      Name                  opens build/Name.saver relative to the repository
      path-to.saver         opens that bundle directly
      --preview             uses a small window and passes isPreview=true
      --size WxH            sets the view size in points
      --seconds N           runs for N seconds (default: 2)
      --resize WxH          reshapes the view halfway through the run, to exercise a
                            saver's response to an aspect-ratio change
      --screenshot out.png  captures the view to PNG and exits
      --help                shows this help
    """
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func parseSize(_ value: String) -> NSSize? {
    let parts = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let width = Double(parts[0]), let height = Double(parts[1]),
          width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
    return NSSize(width: width, height: height)
}

func parseArguments() -> Options {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--help" || arguments.first == "-h" {
        print(usage(program: CommandLine.arguments[0]))
        exit(0)
    }
    guard let saverArgument = arguments.first, !saverArgument.hasPrefix("-") else {
        fail(usage(program: CommandLine.arguments[0]), code: 2)
    }

    var options = Options(saverArgument: saverArgument)
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--preview":
            options.isPreview = true
            index += 1
        case "--size":
            guard index + 1 < arguments.count,
                  let size = parseSize(arguments[index + 1]) else {
                fail("--size requires positive dimensions in WxH form", code: 2)
            }
            options.size = size
            index += 2
        case "--resize":
            guard index + 1 < arguments.count,
                  let size = parseSize(arguments[index + 1]) else {
                fail("--resize requires positive dimensions in WxH form", code: 2)
            }
            options.resizeTo = size
            index += 2
        case "--seconds":
            guard index + 1 < arguments.count,
                  let seconds = Double(arguments[index + 1]),
                  seconds >= 0, seconds.isFinite else {
                fail("--seconds requires a non-negative number", code: 2)
            }
            options.seconds = seconds
            index += 2
        case "--screenshot":
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                fail("--screenshot requires an output path", code: 2)
            }
            options.screenshotPath = arguments[index + 1]
            index += 2
        case "--help", "-h":
            print(usage(program: CommandLine.arguments[0]))
            exit(0)
        default:
            fail("unknown argument: \(arguments[index])", code: 2)
        }
    }
    return options
}

func repositoryRoot() -> URL {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let scriptRoot = script.deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: scriptRoot.appendingPathComponent("Shared/SaverKit").path) {
        return scriptRoot
    }
    // A binary compiled to /tmp cannot infer its source tree, so make Name resolution useful
    // when the documented swiftc command is run from the repository root.
    return currentDirectory
}

func saverURL(for argument: String) -> URL {
    if argument.contains("/") || argument.hasSuffix(".saver") {
        return URL(fileURLWithPath: argument).standardizedFileURL
    }
    return repositoryRoot().appendingPathComponent("build/\(argument).saver")
}

func className(_ cls: AnyClass) -> String {
    NSStringFromClass(cls)
}

func capturePNG(of view: NSView, in window: NSWindow, to path: String,
                completion: @escaping (Result<URL, Error>) -> Void) {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    let output = URL(fileURLWithPath: path).standardizedFileURL
    let parent = output.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        completion(.failure(NSError(
            domain: "run-saver", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "output directory does not exist: \(parent.path)"])))
        return
    }

    // Read every AppKit value here, on the main thread, and capture only plain values below.
    // Both ScreenCaptureKit completion handlers are delivered on a background thread, and
    // NSWindow/NSView are main-thread-only — touching them from inside the closures works by
    // luck until an AppKit thread assertion fires.
    let windowID = CGWindowID(window.windowNumber)
    let pixelBounds = view.convertToBacking(view.bounds)

    // AppKit's cacheDisplay path omits CAMetalLayer contents. ScreenCaptureKit can capture only
    // this process's window without TCC consent, preserving Metal output without screen scraping.
    SCShareableContent.getCurrentProcessShareableContent { content, error in
        guard let content else {
            completion(.failure(error ?? NSError(
                domain: "run-saver", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "could not enumerate this process's window"])))
            return
        }
        guard let capturedWindow = content.windows.first(where: {
            $0.windowID == windowID
        }) else {
            completion(.failure(NSError(
                domain: "run-saver", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "host window is not available for capture"])))
            return
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(pixelBounds.width.rounded()))
        configuration.height = max(1, Int(pixelBounds.height.rounded()))
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: capturedWindow)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
            image, error in
            do {
                guard let image else {
                    throw error ?? NSError(
                        domain: "run-saver", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "window capture returned no image"])
                }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(
                        domain: "run-saver", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "could not encode PNG"])
                }
                try png.write(to: output, options: .atomic)
                completion(.success(output))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

let options = parseArguments()
let application = NSApplication.shared
let bundleURL = saverURL(for: options.saverArgument)
guard let bundle = Bundle(path: bundleURL.path) else {
    fail("not a valid bundle path: \(bundleURL.path)")
}

// Capture the literal plist value before loading. CFBundle replaces an unresolvable
// NSPrincipalClass with its fallback class name in the bundle's live info dictionary.
guard let declaredName = bundle.infoDictionary?["NSPrincipalClass"] as? String,
      !declaredName.isEmpty else {
    fail("bundle Info.plist does not declare NSPrincipalClass")
}

do {
    try bundle.loadAndReturnError()
} catch {
    fail("could not load \(bundleURL.path): \(error.localizedDescription)")
}

// CFBundle falls back to the first Obj-C class when the plist name cannot resolve. Resolve the
// declaration independently so a successful load cannot disguise that silent fallback.
guard let declaredClass = NSClassFromString(declaredName) else {
    let fallback = bundle.principalClass.map(className) ?? "nil"
    fail("NSPrincipalClass '\(declaredName)' does not resolve. CFBundle principalClass returned " +
         "'\(fallback)' by falling back to the first Obj-C class in the bundle; declare the saver " +
         "as @objc(\(declaredName)).")
}

guard let principalClass = bundle.principalClass else {
    fail("Bundle.principalClass is nil for declared class '\(declaredName)'")
}

guard declaredClass === principalClass else {
    fail("NSPrincipalClass '\(declaredName)' resolves to '\(className(declaredClass))', but " +
         "Bundle.principalClass returned '\(className(principalClass))'. Refusing Foundation's " +
         "silent principal-class fallback.")
}

guard let saverType = declaredClass as? ScreenSaverView.Type else {
    fail("declared principal class '\(className(declaredClass))' is not a ScreenSaverView subclass. " +
         "CFBundle can fall back to the bundle's first Obj-C class when NSPrincipalClass does not " +
         "resolve, which otherwise produces a silent black screen.")
}

let defaultSize = options.isPreview ? NSSize(width: 480, height: 270)
                                    : NSSize(width: 960, height: 540)
let size = options.size ?? defaultSize
let frame = NSRect(origin: .zero, size: size)

guard let saverView = saverType.init(frame: frame, isPreview: options.isPreview) else {
    fail("\(declaredName).init(frame:isPreview:) returned nil")
}

// `.accessory` rather than `.regular`, and deliberately no `activate(ignoringOtherApps:)`.
//
// This tool is run in tight loops — often several times a minute while iterating on a saver,
// and by several agents at once. A window that activates its app steals keyboard focus from
// whatever the developer is actually typing into, every single run, which makes the harness
// hostile to the workflow it exists to support. `.accessory` also keeps it out of the Dock
// and the app switcher.
//
// The window must still be on screen and composited: the screenshot path captures it through
// ScreenCaptureKit, so ordering it front without focus is the correct trade, and hiding it
// off-screen would risk it never being composited at all.
application.setActivationPolicy(options.screenshotPath == nil ? .regular : .accessory)

// A borderless screenshot window makes the requested dimensions describe only saver content.
let style: NSWindow.StyleMask = options.screenshotPath == nil
    ? [.titled, .closable, .miniaturizable, .resizable]
    : [.borderless]
let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = declaredName
window.contentView = saverView
window.center()

if options.screenshotPath == nil {
    // Interactive viewing: the developer asked to watch it, so give it focus.
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
} else {
    // Scripted capture: visible and composited, but never key and never activated.
    window.orderFrontRegardless()
}
saverView.startAnimation()

if let resizeTo = options.resizeTo {
    // Halfway through, so there is animated content both before and after the reshape.
    let resizeTimer = Timer(timeInterval: options.seconds / 2, repeats: false) { _ in
        MainActor.assumeIsolated {
            var content = window.frame
            content.size = window.frameRect(forContentRect:
                NSRect(origin: .zero, size: resizeTo)).size
            window.setFrame(content, display: true)
            saverView.frame = NSRect(origin: .zero, size: resizeTo)
        }
    }
    RunLoop.main.add(resizeTimer, forMode: .common)
}

/// Guarantees the process exits even if a ScreenCaptureKit callback never arrives.
///
/// The main exit timer is one-shot and has already fired by the time capture starts, so
/// without this a missing callback hangs forever. In a scripted iteration loop a hang is
/// worse than a failure — it stalls the loop with no diagnostic.
@MainActor var captureSettled = false

@MainActor
func settleCapture(_ body: () -> Void) {
    guard !captureSettled else { return }
    captureSettled = true
    body()
}

@MainActor
func finish() {
    guard let path = options.screenshotPath else {
        saverView.stopAnimation()
        application.terminate(nil)
        return
    }

    let watchdog = Timer(timeInterval: 10.0, repeats: false) { _ in
        MainActor.assumeIsolated {
            settleCapture {
                fail("screenshot timed out after 10s — no ScreenCaptureKit callback arrived")
            }
        }
    }
    RunLoop.main.add(watchdog, forMode: .common)

    capturePNG(of: saverView, in: window, to: path) { result in
        DispatchQueue.main.async {
            settleCapture {
                watchdog.invalidate()
                saverView.stopAnimation()
                switch result {
                case .success(let output):
                    print("Wrote \(output.path)")
                    application.terminate(nil)
                case .failure(let error):
                    fail("could not capture screenshot: \(error.localizedDescription)")
                }
            }
        }
    }
}

let exitTimer = Timer(timeInterval: options.seconds, repeats: false) { _ in
    MainActor.assumeIsolated { finish() }
}
RunLoop.main.add(exitTimer, forMode: .common)
application.run()
