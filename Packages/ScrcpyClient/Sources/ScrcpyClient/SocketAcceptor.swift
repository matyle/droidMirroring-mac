import Foundation
import Network
import SharedModels

/// Spins up a TCP listener on `127.0.0.1:<port>` and yields the first `expected`
/// connections that arrive. Used to receive the video / audio / control sockets
/// that scrcpy-server opens through the `adb reverse` tunnel.
public actor SocketAcceptor {
  public let port: NWEndpoint.Port
  private let expected: Int
  private var listener: NWListener?
  private var pending: [NWConnection] = []
  private var waiters: [CheckedContinuation<NWConnection, Error>] = []

  public init(port: UInt16 = 0, expected: Int) throws {
    let p = NWEndpoint.Port(rawValue: port == 0 ? UInt16.random(in: 30_000..<60_000) : port)!
    self.port = p
    self.expected = expected
  }

  public func start() throws -> UInt16 {
    let params: NWParameters = .tcp
    if let tcpOpts = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
      tcpOpts.noDelay = true
    }
    // Bind to loopback only — scrcpy reverses through `localabstract:` to this port.
    params.requiredInterfaceType = .loopback

    let listener = try NWListener(using: params, on: port)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] conn in
      Task { await self?.accept(conn) }
    }
    listener.start(queue: .global(qos: .userInitiated))
    return port.rawValue
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    for w in waiters {
      w.resume(throwing: DroidMirroringError.scrcpyProtocol("acceptor stopped"))
    }
    waiters.removeAll()
  }

  /// Take the next connection (in arrival order). Blocks until one arrives.
  public func next(timeout: TimeInterval = 10) async throws -> NWConnection {
    if !pending.isEmpty {
      return pending.removeFirst()
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWConnection, Error>) in
        waiters.append(cont)
        Task { [weak self] in
          try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          await self?.timeoutOldestWaiter()
        }
      }
    } onCancel: {
      Task { [weak self] in await self?.cancelAllWaiters() }
    }
  }

  private func accept(_ conn: NWConnection) async {
    await waitReady(conn)
    if let waiter = waiters.first {
      waiters.removeFirst()
      waiter.resume(returning: conn)
    } else {
      pending.append(conn)
    }
  }

  private func waitReady(_ conn: NWConnection) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      conn.stateUpdateHandler = { state in
        if case .ready = state {
          conn.stateUpdateHandler = nil
          cont.resume()
        } else if case .failed = state {
          conn.stateUpdateHandler = nil
          cont.resume()
        }
      }
      conn.start(queue: .global(qos: .userInitiated))
    }
  }

  private func timeoutOldestWaiter() {
    guard let waiter = waiters.first else { return }
    waiters.removeFirst()
    waiter.resume(throwing: DroidMirroringError.scrcpyProtocol("timeout waiting for scrcpy socket"))
  }

  private func cancelAllWaiters() {
    for w in waiters { w.resume(throwing: CancellationError()) }
    waiters.removeAll()
  }
}
