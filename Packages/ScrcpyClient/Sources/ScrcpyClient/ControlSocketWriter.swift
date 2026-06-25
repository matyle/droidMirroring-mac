import Foundation
import Network
import SharedModels

/// Serializes ControlMessages onto the scrcpy control socket. All writes run on the
/// actor's executor so messages never interleave on the wire.
public actor ControlSocketWriter {
  private let conn: NWConnection
  private var closed = false

  public init(connection: NWConnection) {
    self.conn = connection
  }

  public func send(_ message: ControlMessage) async throws {
    guard !closed else { return }
    let data = message.serialize()
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      conn.send(content: data, completion: .contentProcessed { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      })
    }
  }

  public func close() {
    closed = true
    conn.cancel()
  }
}
