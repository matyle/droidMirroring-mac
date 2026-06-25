import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import SharedModels

/// Hardware H.264/H.265 decoder backed by VideoToolbox.
/// Consumes Annex-B NAL packets from scrcpy-server, emits CVPixelBuffers.
public final class VTDecoder: @unchecked Sendable {
  public enum Codec: Sendable { case h264, h265 }

  public typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime) -> Void

  private let codec: Codec
  private let onFrame: FrameHandler

  private var formatDescription: CMVideoFormatDescription?
  private var session: VTDecompressionSession?

  // HEVC parameter sets — wait until we have all three before building the format.
  private var vps: Data?
  private var sps: Data?
  private var pps: Data?

  public init(codec: Codec, onFrame: @escaping FrameHandler) {
    self.codec = codec
    self.onFrame = onFrame
  }

  deinit {
    if let s = session { VTDecompressionSessionInvalidate(s) }
  }

  /// Feed an Annex-B encoded packet. May contain parameter sets (config packet)
  /// or a coded picture. Decoded frames are delivered via `onFrame`.
  public func feed(packet: Data, pts: CMTime, isConfig: Bool) throws {
    let nalus = NALU.split(annexB: packet)
    if isConfig {
      try ingestParameterSets(nalus)
      return
    }
    try ensureSession()
    guard let format = formatDescription, let session = session else { return }
    let avcc = avccPayload(from: nalus)
    let sampleBuffer = try makeSampleBuffer(avcc: avcc, pts: pts, format: format)
    var flagsOut: VTDecodeInfoFlags = []
    let status = VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sampleBuffer,
      flags: [._EnableAsynchronousDecompression],
      frameRefcon: nil,
      infoFlagsOut: &flagsOut
    )
    if status != noErr {
      throw DroidMirroringError.decoder("VTDecompressionSessionDecodeFrame status=\(status)")
    }
  }

  /// Drop session + parameter sets. Next config packet rebuilds everything.
  public func reset() {
    if let s = session { VTDecompressionSessionInvalidate(s); self.session = nil }
    formatDescription = nil
    vps = nil; sps = nil; pps = nil
  }

  // MARK: parameter sets

  private func ingestParameterSets(_ nalus: [Data]) throws {
    switch codec {
    case .h265:
      for nal in nalus {
        switch NALU.hevcType(of: nal) {
        case NALU.HEVCType.vpsNut.rawValue: vps = nal
        case NALU.HEVCType.spsNut.rawValue: sps = nal
        case NALU.HEVCType.ppsNut.rawValue: pps = nal
        default: break
        }
      }
    case .h264:
      for nal in nalus {
        switch NALU.avcType(of: nal) {
        case NALU.AVCType.sps.rawValue: sps = nal
        case NALU.AVCType.pps.rawValue: pps = nal
        default: break
        }
      }
    }
    formatDescription = nil
    if let s = session { VTDecompressionSessionInvalidate(s); self.session = nil }
  }

  private func ensureSession() throws {
    if session != nil { return }
    if formatDescription == nil {
      formatDescription = try buildFormatDescription()
    }
    guard let format = formatDescription else { return }
    let attrs: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var session: VTDecompressionSession?
    var callbacks = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: vtCallback,
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    let status = VTDecompressionSessionCreate(
      allocator: nil,
      formatDescription: format,
      decoderSpecification: nil,
      imageBufferAttributes: attrs as CFDictionary,
      outputCallback: &callbacks,
      decompressionSessionOut: &session
    )
    guard status == noErr, let s = session else {
      throw DroidMirroringError.decoder("VTDecompressionSessionCreate status=\(status)")
    }
    VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    self.session = s
  }

  private func buildFormatDescription() throws -> CMVideoFormatDescription {
    switch codec {
    case .h265:
      guard let vps, let sps, let pps else {
        throw DroidMirroringError.decoder("HEVC parameter sets incomplete")
      }
      return try makeHEVCFormat(vps: vps, sps: sps, pps: pps)
    case .h264:
      guard let sps, let pps else {
        throw DroidMirroringError.decoder("H.264 parameter sets incomplete")
      }
      return try makeAVCFormat(sps: sps, pps: pps)
    }
  }

  private func makeHEVCFormat(vps: Data, sps: Data, pps: Data) throws -> CMVideoFormatDescription {
    let params: [Data] = [vps, sps, pps]
    let pointers = params.map { ($0 as NSData).bytes.assumingMemoryBound(to: UInt8.self) }
    let sizes = params.map { $0.count }
    var format: CMVideoFormatDescription?
    let status = pointers.withUnsafeBufferPointer { ptrBuf in
      sizes.withUnsafeBufferPointer { sizeBuf in
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
          allocator: nil,
          parameterSetCount: params.count,
          parameterSetPointers: ptrBuf.baseAddress!,
          parameterSetSizes: sizeBuf.baseAddress!,
          nalUnitHeaderLength: 4,
          extensions: nil,
          formatDescriptionOut: &format
        )
      }
    }
    _ = params  // keep alive
    guard status == noErr, let f = format else {
      throw DroidMirroringError.decoder("HEVC format creation status=\(status)")
    }
    return f
  }

  private func makeAVCFormat(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
    let params: [Data] = [sps, pps]
    let pointers = params.map { ($0 as NSData).bytes.assumingMemoryBound(to: UInt8.self) }
    let sizes = params.map { $0.count }
    var format: CMVideoFormatDescription?
    let status = pointers.withUnsafeBufferPointer { ptrBuf in
      sizes.withUnsafeBufferPointer { sizeBuf in
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: nil,
          parameterSetCount: params.count,
          parameterSetPointers: ptrBuf.baseAddress!,
          parameterSetSizes: sizeBuf.baseAddress!,
          nalUnitHeaderLength: 4,
          formatDescriptionOut: &format
        )
      }
    }
    _ = params
    guard status == noErr, let f = format else {
      throw DroidMirroringError.decoder("H.264 format creation status=\(status)")
    }
    return f
  }

  // MARK: sample buffer construction

  private func avccPayload(from nalus: [Data]) -> Data {
    var out = Data()
    out.reserveCapacity(nalus.reduce(0) { $0 + 4 + $1.count })
    for nal in nalus {
      var len = UInt32(nal.count).bigEndian
      withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
      out.append(nal)
    }
    return out
  }

  private func makeSampleBuffer(avcc: Data, pts: CMTime, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 1)
    avcc.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: avcc.count)
    let status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: bytes,
      blockLength: avcc.count,
      blockAllocator: kCFAllocatorDefault,   // frees `bytes` when block dies
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: avcc.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr, let bb = blockBuffer else {
      bytes.deallocate()
      throw DroidMirroringError.decoder("CMBlockBufferCreate status=\(status)")
    }
    var sampleSize = avcc.count
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    let s2 = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: bb,
      formatDescription: format,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard s2 == noErr, let sb = sampleBuffer else {
      throw DroidMirroringError.decoder("CMSampleBufferCreate status=\(s2)")
    }
    return sb
  }

  fileprivate func deliver(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    onFrame(pixelBuffer, pts)
  }
}

private func vtCallback(
  decompressionOutputRefCon: UnsafeMutableRawPointer?,
  sourceFrameRefCon: UnsafeMutableRawPointer?,
  status: OSStatus,
  infoFlags: VTDecodeInfoFlags,
  imageBuffer: CVImageBuffer?,
  presentationTimeStamp: CMTime,
  presentationDuration: CMTime
) {
  guard status == noErr, let imageBuffer, let ref = decompressionOutputRefCon else { return }
  let decoder = Unmanaged<VTDecoder>.fromOpaque(ref).takeUnretainedValue()
  decoder.deliver(imageBuffer, pts: presentationTimeStamp)
}
