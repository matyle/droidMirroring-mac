import Foundation
import Network
import SharedModels

/// Audio codec id signalled by scrcpy-server (first 4 bytes on the audio socket).
/// FourCC values per com.genymobile.scrcpy.audio.AudioCodec (scrcpy 3.x).
public enum AudioCodec: Sendable, Equatable {
  case opus
  case aac
  case flac
  case raw

  /// Parse a big-endian FourCC. scrcpy uses ASCII tags, e.g. "opus", " aac", "flac", "raw ".
  public static func parse(fourCC value: UInt32) -> AudioCodec? {
    switch value {
    case Self.fourCC("opus"): return .opus
    case Self.fourCC(" aac"): return .aac
    case Self.fourCC("flac"): return .flac
    case Self.fourCC("raw "): return .raw
    default: return nil
    }
  }

  public var debugName: String {
    switch self {
    case .opus: return "opus"
    case .aac: return "aac"
    case .flac: return "flac"
    case .raw: return "raw"
    }
  }

  private static func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for byte in s.utf8 { v = (v << 8) | UInt32(byte) }
    return v
  }
}

/// One audio packet from scrcpy-server.
/// Header layout matches the video framing (12 bytes, big-endian):
///   bits 63-62 : flags (bit 63 = CONFIG, bit 62 = KEY_FRAME)
///   bits 61-0  : PTS in microseconds
///   bytes 8-11 : payload size (u32)
public struct AudioFrame: Sendable {
  public static let configFlag: UInt64 = 1 << 63
  public static let keyFrameFlag: UInt64 = 1 << 62
  public static let ptsMask: UInt64 = 0x3FFF_FFFF_FFFF_FFFF

  public let pts: UInt64
  public let isConfig: Bool
  public let isKeyframe: Bool
  public let payload: Data

  public init(pts: UInt64, isConfig: Bool, isKeyframe: Bool, payload: Data) {
    self.pts = pts
    self.isConfig = isConfig
    self.isKeyframe = isKeyframe
    self.payload = payload
  }
}

/// Reads the scrcpy 3.x audio framing protocol off an `NWConnection`.
/// Usage: call `readCodecHeader()` once to read the 4-byte FourCC, then
/// loop on `nextFrame()`.
public actor AudioStream {
  private let conn: NWConnection
  private var codecRead = false

  public init(connection: NWConnection) {
    self.conn = connection
  }

  public func readCodecHeader() async throws -> AudioCodec {
    let header = try await readExact(4)
    let fourCC = header.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
    guard let codec = AudioCodec.parse(fourCC: fourCC) else {
      throw DroidMirroringError.scrcpyProtocol("unknown audio codec fourCC=0x\(String(fourCC, radix: 16))")
    }
    codecRead = true
    return codec
  }

  public func nextFrame() async throws -> AudioFrame {
    let header = try await readExact(12)
    let pts64 = header.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
    let size = header.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian

    let isConfig = (pts64 & AudioFrame.configFlag) != 0
    let isKey = (pts64 & AudioFrame.keyFrameFlag) != 0
    let pts = pts64 & AudioFrame.ptsMask

    let payload = try await readExact(Int(size))
    return AudioFrame(pts: pts, isConfig: isConfig, isKeyframe: isKey, payload: payload)
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
            cont.resume(throwing: DroidMirroringError.scrcpyProtocol("audio socket closed"))
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
