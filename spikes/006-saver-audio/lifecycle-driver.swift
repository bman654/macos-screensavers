#!/usr/bin/env swift
// Throwaway. Reproduces the three ways a host can stop showing a saver view, so the one that
// leaves audio playing can be identified without driving System Settings by hand.
//
// The real host does something this repo's harness never did: it abandons a view without
// calling `stopAnimation()`. There are three distinguishable versions of that and they fire
// different callbacks — which is the whole problem, because a saver that gates on the wrong
// one goes on making a noise in an empty room.
//
//   ordered out  window still exists, view still has a window   -> viewDidMoveToWindow: no
//   detached     contentView cleared, view has no window        -> viewDidMoveToWindow: yes
//   released     every reference dropped, no stopAnimation      -> deinit: only if not immortal
//
// Run it and read the `AudioProbe[...]` lines on stderr, which is where NSLog goes for a
// command-line process. `rendered=` is the audio frame count: if it keeps climbing after a
// phase, that phase leaves the view audible.
//
//   swift spikes/006-saver-audio/lifecycle-driver.swift build/AudioProbe.saver

import AppKit
import ScreenSaver

let arguments = Array(CommandLine.arguments.dropFirst())
guard let bundlePath = arguments.first else {
    FileHandle.standardError.write(Data("usage: lifecycle-driver.swift <path.saver>\n".utf8))
    exit(2)
}

guard let bundle = Bundle(path: bundlePath), bundle.load(),
      let saverType = bundle.principalClass as? ScreenSaverView.Type else {
    FileHandle.standardError.write(Data("error: could not load \(bundlePath)\n".utf8))
    exit(1)
}

let application = NSApplication.shared
// Never takes focus: this runs while the developer is typing somewhere else.
application.setActivationPolicy(.accessory)

let frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
var view: ScreenSaverView? = saverType.init(frame: frame, isPreview: false)
var window: NSWindow? = NSWindow(contentRect: frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)

func note(_ message: String) {
    FileHandle.standardError.write(Data("\n=== \(message)\n".utf8))
}

func phase(_ seconds: Double, _ name: String, _ body: @escaping @MainActor () -> Void) {
    let timer = Timer(timeInterval: seconds, repeats: false) { _ in
        MainActor.assumeIsolated {
            note(name)
            body()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
}

window?.isReleasedWhenClosed = false
window?.contentView = view
// Parked at desktop level, never key, never activated — same discipline as `run-saver`.
window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
window?.orderFrontRegardless()
note("phase 1: on screen and animating")
view?.startAnimation()

phase(6, "phase 2: window.orderOut — the window still exists and the view still has one") {
    window?.orderOut(nil)
}

phase(12, "phase 3: contentView = nil — the view now has no window, and nobody stopped it") {
    window?.contentView = nil
}

phase(18, "phase 4: every reference dropped, still without stopAnimation") {
    view = nil
    window = nil
}

phase(26, "done — anything still counting frames above is playing to nobody") {
    application.terminate(nil)
}

application.run()
