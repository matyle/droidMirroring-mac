import Foundation
import Network
import SharedModels

/// Wire-format messages sent FROM scrcpy-server TO the client on the control socket.
/// Reference: scrcpy/server/src/main/java/com/genymobile/scrcpy/control/DeviceMessage.java
public enum DeviceMessageType: UInt8, Sendable {
  case clipboard = 0           // device clipboard text
  case ackClipboard = 1        // ack for a SET_CLIPBOARD round-trip (sequence echo)
  case uhidOutput = 2          // virtual HID device response
}

public enum DeviceMessage: Sendable {
  case clipboard(text: String)
  case ackClipboard(sequence: UInt64)
  case uhidOutput(id: UInt16, data: Data)
  case unknown(type: UInt8)
}

/// Reads `DeviceMessage`s off the control socket. The scrcpy control socket is
/// bidirectional — clients can write `ControlMessage`s and the server pushes
/// `DeviceMessage`s back. Run alongside `ControlSocketWriter` on the same NWConnection.
public actor DeviceMessageReader {
  private let conn: NWConnection
  private var closed = false

  public init(connection: NWConnection) {
    self.conn = connection
  }

  /// Subscribe to the stream of device messages. The stream terminates when the
  /// underlying connection is closed.
  public nonisolated func messages() -> AsyncStream<DeviceMessage> {
    AsyncStream { continuation in
      let task = Task { [weak self] in
        guard let self else { continuation.finish(); return }
        while !Task.isCancelled, await !self.closed {
          do {
            let msg = try await self.nextMessage()
            continuation.yield(msg)
          } catch {
            continuation.finish()
            return
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  public func close() {
    closed = true
  }

  // MARK: framing

  private func nextMessage() async throws -> DeviceMessage {
    let typeByte = try await readExact(1)[0]
    guard let type = DeviceMessageType(rawValue: typeByte) else {
      // Unknown type — we don't know the payload length, so we can't safely skip.
      // Close the channel to avoid desync.
      closed = true
      throw DroidMirroringError.scrcpyProtocol("unknown device message type \(typeByte)")
    }
    switch type {
    case .clipboard:
      let len = try await readBEUInt32()
      let bytes = try await readExact(Int(len))
      let text = String(data: bytes, encoding: .utf8) ?? ""
      return .clipboard(text: text)
    case .ackClipboard:
      let seq = try await readBEUInt64()
      return .ackClipboard(sequence: seq)
    case .uhidOutput:
      let id = try await readBEUInt16()
      let len = try await readBEUInt16()
      let data = try await readExact(Int(len))
      return .uhidOutput(id: id, data: data)
    }
  }

  // MARK: reads

  private func readExact(_ count: Int) async throws -> Data {
    guard count > 0 else { return Data() }
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
        if let error { cont.resume(throwing: error); return }
        if let data, data.count == count {
          cont.resume(returning: data); return
        }
        if isComplete {
          cont.resume(throwing: DroidMirroringError.scrcpyProtocol("control socket closed mid-message"))
          return
        }
        cont.resume(throwing: DroidMirroringError.scrcpyProtocol("short read on device message"))
      }
    }
  }

  private func readBEUInt16() async throws -> UInt16 {
    let bytes = try await readExact(2)
    return bytes.withUnsafeBytes { $0.load(as: UInt16.self) }.bigEndian
  }
  private func readBEUInt32() async throws -> UInt32 {
    let bytes = try await readExact(4)
    return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
  }
  private func readBEUInt64() async throws -> UInt64 {
    let bytes = try await readExact(8)
    return bytes.withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
  }
}
