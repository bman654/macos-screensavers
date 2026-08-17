// Enough UI driving to open the Screen Saver sheet and read a saver's tile back.
//
// System Settings renders each pane in an out-of-process ExtensionKit view, so the accessibility
// tree of the "System Settings" process is *empty* -- `entire contents of window 1` returns zero
// elements and there is no button to press with System Events. Synthetic events are the only way
// in, and they need Accessibility permission for whatever runs this.
//
// The cursor is returned to where it was found, because the user is working while this runs.
//
//   swiftc -O settings-ui.swift -o /tmp/settings-ui
//   /tmp/settings-ui list                    # id, x,y, WxH, owner, title for every large window
//   /tmp/settings-ui click <x> <y>
//   /tmp/settings-ui scroll <x> <y> [ticks]  # positive scrolls down

import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func settle(_ seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}

func listWindows() {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        let height = bounds["Height"] as? Double ?? 0
        // Menu-bar extras and other furniture are noise for this purpose.
        guard width >= 200, height >= 200 else { continue }
        let x = bounds["X"] as? Double ?? 0
        let y = bounds["Y"] as? Double ?? 0
        let number = window[kCGWindowNumber as String] as? Int ?? -1
        let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
        let title = window[kCGWindowName as String] as? String ?? ""
        print("\(number)\t\(Int(x)),\(Int(y))\t\(Int(width))x\(Int(height))\t\(owner)\t\(title)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let action = arguments.first else {
    fail("usage: settings-ui <list|click|scroll> [x] [y] [ticks]")
}

if action == "list" {
    listWindows()
    exit(0)
}

guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    fail("usage: settings-ui \(action) <x> <y> [ticks]")
}
let point = CGPoint(x: x, y: y)
let origin = CGEvent(source: nil)?.location ?? .zero

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
}

post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
             mouseButton: .left))
settle(0.2)

switch action {
case "click":
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
                 mouseButton: .left))
    settle(0.08)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
                 mouseButton: .left))
case "scroll":
    let ticks = Int(arguments.count > 3 ? arguments[3] : "40") ?? 40
    for _ in 0..<abs(ticks) {
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: Int32(ticks > 0 ? -3 : 3), wheel2: 0, wheel3: 0)
        wheel?.location = point
        post(wheel)
        settle(0.03)
    }
default:
    fail("error: unknown action \(action)")
}

settle(0.2)
post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: origin,
             mouseButton: .left))
print("ok")
