import Foundation
import Network
import SharedModels

/// One frame as delivered by scrcpy-server over the video socket.
///
/// Header layout (12 bytes, big-endian):
///   bits 63-62 : flags (bit 63 = CONFIG, bit 62 = KEY_FRAME)
///   bits 61-0  : PTS in microseconds
///   bytes 8-11 : payload size (u32)
public struct VideoFrame: Sendable {
  public static let configFlag: UInt64 = 1 << 63
  public static let keyFrameFlag: UInt64 = 1 << 62
  public static let ptsMask: UInt64 = 0x3FFF_FFFF_FFFF_FFFF

  public let pts: UInt64          // microseconds; .max for config packets
  public let isConfig: Bool
  public let isKeyframe: Bool
  public let payload: Data        // Annex-B NAL units

  public init(pts: UInt64, isConfig: Bool, isKeyframe: Bool, payload: Data) {
    self.pts = pts
    self.isConfig = isConfig
    self.isKeyframe = isKeyframe
    self.payload = payload
  }
}

/// Reads the scrcpy 3.x video framing protocol off an `NWConnection`.
/// Each call to `nextFrame()` reads one 12-byte header followed by `size` bytes of payload.
public actor VideoStream {
  private let conn: NWConnection

  public init(connection: NWConnection) {
    self.conn = connection
  }

  public func nextFrame() async throws -> VideoFrame {
    let header = try await readExact(12)
    let pts64 = header.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
    let size = header.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian

    let isConfig = (pts64 & VideoFrame.configFlag) != 0
    let isKey = (pts64 & VideoFrame.keyFrameFlag) != 0
    let pts = pts64 & VideoFrame.ptsMask

    let payload = try await readExact(Int(size))
    return VideoFrame(pts: pts, isConfig: isConfig, isKeyframe: isKey, payload: payload)
  }

  public func close() {
    conn.cancel()
  }

  private func readExact(_ count: Int) async throws -> Data {
    var acc = Data()
    acc.reserveCapacity(count)
    while acc.count < count {
      let want = count - acc.count
      let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        conn.receive(minimumIncompleteLength: 1, maximumLength: want) { data, _, isComplete, error in
          if let error { cont.resume(throwing: error); return }
          if let data, !data.isEmpty {
            cont.resume(returning: data); return
          }
          if isComplete {
            cont.resume(throwing: DroidMirroringError.scrcpyProtocol("video socket closed"))
            return
          }
          cont.resume(returning: Data())
        }
      }
      acc.append(chunk)
    }
    return acc
  }
}
