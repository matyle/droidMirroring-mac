import Foundation
import AppKit
import ScrcpyClient

/// Bidirectional clipboard sync between the macOS pasteboard and the connected
/// Android device. Lives for the lifetime of a mirror session.
///
/// Direction A (Mac → Device): poll `NSPasteboard.general.changeCount` and ship
/// the latest string via SET_CLIPBOARD when it changes.
///
/// Direction B (Device → Mac): subscribe to the scrcpy control socket's
/// DeviceMessage stream; on DEVICE_CLIPBOARD payloads, write to NSPasteboard.
///
/// Loop prevention: each side stamps a hash of what it last wrote. If the
/// next pasteboard event matches that hash, we know it came from us and we
/// silently drop it.
@MainActor
final class ClipboardBridge {
  let writer: ControlSocketWriter
  let reader: DeviceMessageReader

  private var pollTimer: Timer?
  private var lastWrittenChangeCount: Int
  private var lastIncomingHash: Int?
  private var lastOutgoingHash: Int?
  private var deviceListener: Task<Void, Never>?
  private var sequence: UInt64 = 1

  /// Master switch — when false, both directions are skipped.
  var enabled: Bool = true

  init(writer: ControlSocketWriter, reader: DeviceMessageReader) {
    self.writer = writer
    self.reader = reader
    self.lastWrittenChangeCount = NSPasteboard.general.changeCount
  }

  func start() {
    stop()
    let reader = self.reader
    deviceListener = Task { [weak self] in
      for await message in reader.messages() {
        guard !Task.isCancelled else { return }
        if case .clipboard(let text) = message {
          await self?.handleDeviceClipboard(text)
        }
      }
    }
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pollMacPasteboard() }
    }
  }

  func stop() {
    deviceListener?.cancel()
    deviceListener = nil
    pollTimer?.invalidate()
    pollTimer = nil
  }

  // MARK: Mac → Device

  private func pollMacPasteboard() {
    guard enabled else { return }
    let pb = NSPasteboard.general
    guard pb.changeCount != lastWrittenChangeCount else { return }
    lastWrittenChangeCount = pb.changeCount
    guard let text = pb.string(forType: .string), !text.isEmpty else { return }
    let hash = text.hashValue
    // Skip if this content originated from the device — we don't want to ping-pong.
    if hash == lastIncomingHash { return }
    lastOutgoingHash = hash
    let seq = nextSequence()
    Task { [writer] in
      try? await writer.send(.setClipboard(text: text, sequence: seq, paste: false))
    }
  }

  // MARK: Device → Mac

  private func handleDeviceClipboard(_ text: String) {
    guard enabled else { return }
    let hash = text.hashValue
    if hash == lastOutgoingHash { return }   // it's the value we just pushed; ignore the echo
    lastIncomingHash = hash
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    lastWrittenChangeCount = pb.changeCount   // suppress the poll we just caused
  }

  private func nextSequence() -> UInt64 {
    defer { sequence &+= 1 }
    return sequence
  }
}
