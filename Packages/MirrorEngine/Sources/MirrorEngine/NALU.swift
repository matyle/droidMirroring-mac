import Foundation

/// Annex-B byte-stream NAL unit utilities.
///
/// Annex-B uses start codes `00 00 00 01` (4-byte) or `00 00 01` (3-byte) as
/// NAL boundaries. VideoToolbox wants AVCC: each NAL is prefixed with its
/// 4-byte big-endian length.
public enum NALU {
  /// Split an Annex-B encoded payload into a flat array of NAL unit bodies
  /// (start codes stripped).
  public static func split(annexB data: Data) -> [Data] {
    var nalus: [Data] = []
    let bytes = [UInt8](data)
    var i = 0
    var naluStart = -1
    while i < bytes.count {
      let scLen = startCodeLength(at: i, bytes: bytes)
      if scLen > 0 {
        if naluStart >= 0 {
          nalus.append(Data(bytes[naluStart..<i]))
        }
        i += scLen
        naluStart = i
      } else {
        i += 1
      }
    }
    if naluStart >= 0, naluStart < bytes.count {
      nalus.append(Data(bytes[naluStart..<bytes.count]))
    }
    return nalus
  }

  /// Convert Annex-B → AVCC (length-prefixed) in one pass.
  public static func annexBToAVCC(_ data: Data) -> Data {
    var out = Data()
    out.reserveCapacity(data.count)
    for nal in split(annexB: data) {
      var len = UInt32(nal.count).bigEndian
      withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
      out.append(nal)
    }
    return out
  }

  private static func startCodeLength(at i: Int, bytes: [UInt8]) -> Int {
    if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
      return 4
    }
    if i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
      return 3
    }
    return 0
  }

  // MARK: HEVC NAL types (RFC 7798 §1.1.4)
  public enum HEVCType: UInt8 {
    case vpsNut = 32
    case spsNut = 33
    case ppsNut = 34
  }

  /// Extract the HEVC NAL unit type from the first byte: bits 1..6.
  public static func hevcType(of nal: Data) -> UInt8 {
    guard let first = nal.first else { return 0 }
    return (first >> 1) & 0x3F
  }

  // MARK: H.264 NAL types
  public enum AVCType: UInt8 {
    case sps = 7
    case pps = 8
  }

  public static func avcType(of nal: Data) -> UInt8 {
    guard let first = nal.first else { return 0 }
    return first & 0x1F
  }
}
