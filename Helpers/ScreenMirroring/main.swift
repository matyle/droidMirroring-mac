import AppKit
import MirrorEngine

// LSUIElement helper: hosts mirror NSWindows so closing the main app keeps mirror alive.
// Communicates with main App via XPC + AppGroup. M2 fills in.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
