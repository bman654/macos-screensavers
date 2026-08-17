#!/usr/bin/env swift
// Spike 008 driver: walk a saver view through the ways a host stops showing it, and print the
// reference tree of anything that survives. Phases are chosen from the command line so the same
// driver can isolate one path at a time:
//
//   swift driver.swift build/LifeProbe.saver orderout,orderin,detach,drop
//
// Phase names: orderout | orderin | detach (contentView=nil) | attach (contentView=view)
//              | drop (view=nil,window=nil) | close (window.close()) | stop | start
// Each phase runs 5 s after the previous one. After the last one the driver waits 8 s, then
// runs `leaks --traceTree` on the view's address (from LifeProbe's init log) and exits.

import AppKit
import ScreenSaver

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let bundle = Bundle(path: arguments[0]), bundle.load(),
      let saverType = bundle.principalClass as? ScreenSaverView.Type else {
    FileHandle.standardError.write(Data("usage: driver.swift <path.saver> phase,phase,...\n".utf8))
    exit(2)
}
let phases = arguments[1].split(separator: ",").map(String.init)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// LIFEDRIVER_SIZE=3840x2160 for a full-size run; the drawable pool only matters at that size.
let sizeSpec = ProcessInfo.processInfo.environment["LIFEDRIVER_SIZE"]?.split(separator: "x").compactMap { Double($0) }
let frame = NSRect(x: 0, y: 0, width: sizeSpec?.first ?? 1200, height: sizeSpec?.last ?? 700)
// Created inside a pool: at top level, the +1 the initialiser autoreleases lands in the main
// thread's outermost pool, which never drains — and that alone makes the view "immortal".
// This is the same trap `docs/saver-host.md` records for the 445 MB "leak" that was not one.
var view: ScreenSaverView?
var window: NSWindow?
autoreleasepool {
    view = saverType.init(frame: frame, isPreview: false)
    window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
}
let viewAddress = view.map { "\(Unmanaged.passUnretained($0).toOpaque())" } ?? ""
func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
}
func note(_ message: String) {
    FileHandle.standardError.write(Data("\n=== \(message)   [footprint \(footprintMB()) MB]\n".utf8))
}
// A footprint line every 2 s so a release is visible as a step in the trace.
let footprintTimer = Timer(timeInterval: 2, repeats: true) { _ in
    FileHandle.standardError.write(Data("footprint \(footprintMB()) MB\n".utf8))
}
RunLoop.main.add(footprintTimer, forMode: .common)

window?.isReleasedWhenClosed = false
window?.contentView = view
window?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
window?.orderFrontRegardless()
note("phase 0: on screen and animating")
view?.startAnimation()

var delay = 8.0
for phase in phases {
    let body: () -> Void
    switch phase {
    case "orderout": body = { window?.orderOut(nil) }
    case "orderin":  body = { window?.orderFrontRegardless() }
    case "detach":   body = { window?.contentView = nil }
    case "close":    body = { window?.close() }
    case "stop":     body = { view?.stopAnimation() }
    case "start":    body = { view?.startAnimation() }
    case "attach":   body = { window?.contentView = view }
    case "drop":     body = {
        view = nil; window = nil
        // Kick the event loop so AppKit's per-event autorelease pool drains; an idle accessory
        // app can otherwise sit on the callout pool that holds the last autoreleased reference.
        if let kick = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, subtype: 0,
                                         data1: 0, data2: 0) {
            NSApp.postEvent(kick, atStart: false)
        }
    }
    default: FileHandle.standardError.write(Data("unknown phase \(phase)\n".utf8)); exit(2)
    }
    let timer = Timer(timeInterval: delay, repeats: false) { _ in
        note("phase: \(phase)")
        body()
    }
    RunLoop.main.add(timer, forMode: .common)
    delay += 8
}
let finish = Timer(timeInterval: delay + 3, repeats: false) { _ in
    note("done: tracing \(viewAddress)")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
    task.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "--traceTree=\(viewAddress)"]
    try? task.run()
    task.waitUntilExit()
    application.terminate(nil)
}
RunLoop.main.add(finish, forMode: .common)
application.run()
