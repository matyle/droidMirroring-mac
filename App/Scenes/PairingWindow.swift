import SwiftUI
import ADBKit

/// Standalone Window host for the pairing UI. The original `PairingSheet`
/// was designed for `.sheet`, so its Cancel button calls `@Environment(\.dismiss)`.
/// In a Window scene `dismiss` is a no-op; we wrap the sheet here and let
/// the user close via the window's own close button (red traffic light).
struct PairingWindow: View {
  let wireless: ADBWirelessClient

  var body: some View {
    PairingSheet(wireless: wireless)
  }
}
