// Lists every window owned by a pid, on-screen or not, with its layer and bounds — the
// outside view of what a host has done with a saver's window. `swift winlist.swift <pid>`.
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    print(w)
}
