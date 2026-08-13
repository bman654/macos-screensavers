import Foundation
import Metal

/// Loads a saver's Metal shaders, preferring a precompiled `default.metallib` and falling
/// back to compiling `.metal` source shipped in `Resources/Shaders/`.
///
/// The fallback exists because Command Line Tools ship no Metal compiler — `xcrun metal`
/// and `metallib` are Xcode-only — so on a machine without Xcode there is no way to
/// precompile, and `build-saver.sh` copies the source into the bundle instead.
///
/// Two constraints follow from the fallback, and both bite only on the machine *without* a
/// Metal toolchain — the author who has Xcode will never see them, which is precisely why
/// they are written down here:
///
/// - **File-scope names must be unique across all of a saver's `.metal` files.** The
///   fallback concatenates every source file into one translation unit, so two files each
///   declaring `struct Uniforms`, or each declaring a same-named file-scope helper, fail
///   with `redefinition of 'Uniforms'`. Prefix file-scope names per shader, as
///   `MetalProbe.metal` does with `metalProbe*`.
/// - **`#include` of a project header does not work.** `makeLibrary(source:)` has no include
///   search path, so a shared Swift/MSL uniform header — the usual way to keep struct
///   layouts in sync — is unavailable. Duplicate the struct on both sides and comment the
///   padding that makes the layouts match.
struct ShaderLibrary {
    enum LoadingPath: CustomStringConvertible {
        case defaultMetallib
        case runtimeSource([URL])

        var description: String {
            switch self {
            case .defaultMetallib:
                return "bundle default.metallib"
            case .runtimeSource(let urls):
                return "runtime source (\(urls.map(\.lastPathComponent).joined(separator: ", ")))"
            }
        }
    }

    let library: MTLLibrary
    let loadingPath: LoadingPath

    init(device: MTLDevice, bundle: Bundle) throws {
        do {
            library = try device.makeDefaultLibrary(bundle: bundle)
            loadingPath = .defaultMetallib
            NSLog("ShaderLibrary: loaded bundle default.metallib from %@", bundle.bundlePath)
            return
        } catch {
            let defaultLibraryError = error.localizedDescription
            let sourceURLs = bundle.urls(forResourcesWithExtension: "metal",
                                         subdirectory: "Shaders")?.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            } ?? []

            guard !sourceURLs.isEmpty else {
                throw ShaderLibraryError.noShaderSources(
                    bundlePath: bundle.bundlePath,
                    defaultLibraryError: defaultLibraryError)
            }

            var sources: [String] = []
            for url in sourceURLs {
                do {
                    sources.append(try String(contentsOf: url, encoding: .utf8))
                } catch {
                    throw ShaderLibraryError.cannotReadSource(
                        path: url.path,
                        defaultLibraryError: defaultLibraryError,
                        underlying: error)
                }
            }

            do {
                library = try device.makeLibrary(source: sources.joined(separator: "\n\n"),
                                                 options: nil)
                loadingPath = .runtimeSource(sourceURLs)
                NSLog("ShaderLibrary: no usable default.metallib (%@); compiled %@ at runtime",
                      defaultLibraryError,
                      sourceURLs.map(\.lastPathComponent).joined(separator: ", "))
            } catch {
                throw ShaderLibraryError.runtimeCompilationFailed(
                    paths: sourceURLs.map(\.path),
                    defaultLibraryError: defaultLibraryError,
                    underlying: error)
            }
        }
    }
}

enum ShaderLibraryError: LocalizedError {
    case noShaderSources(bundlePath: String, defaultLibraryError: String)
    case cannotReadSource(path: String, defaultLibraryError: String, underlying: Error)
    case runtimeCompilationFailed(paths: [String], defaultLibraryError: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noShaderSources(let bundlePath, let defaultLibraryError):
            return "No Metal shader library could be loaded from \(bundlePath). "
                + "default.metallib failed (\(defaultLibraryError)), and Resources/Shaders "
                + "contains no .metal source files."
        case .cannotReadSource(let path, let defaultLibraryError, let underlying):
            return "No Metal shader library could be loaded. default.metallib failed "
                + "(\(defaultLibraryError)), and fallback source \(path) could not be read "
                + "(\(underlying.localizedDescription))."
        case .runtimeCompilationFailed(let paths, let defaultLibraryError, let underlying):
            return "No Metal shader library could be loaded. default.metallib failed "
                + "(\(defaultLibraryError)), and runtime compilation of "
                + "\(paths.joined(separator: ", ")) failed "
                + "(\(underlying.localizedDescription)). If this occurs only in "
                + "legacyScreenSaver, its sandbox is blocking Metal source compilation."
        }
    }
}
