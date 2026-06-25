import AppKit
import FusionEngine

// Fusion Mode host: each Android freeform app becomes a native NSWindow.
// Owns the per-window scrcpy stream lifecycle. M4 fills in.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
