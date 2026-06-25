import Foundation
import AudioToolbox
import AVFoundation
import CoreMedia
import ScrcpyClient
import SharedModels

/// Decodes compressed audio packets (Opus / AAC / FLAC / raw) from scrcpy-server
/// and plays them through `AVAudioEngine`. Output is **interleaved** Float32
/// stereo at 48 kHz — one buffer per AudioBufferList, which removes the variable-
/// length-struct minefield around non-interleaved layouts.
///
/// Thread model: `feed(packet:isConfig:pts:)` is called from the MirrorSession
/// receive task. Internally serialised via a single AudioConverterRef + a
/// dedicated AVAudioPlayerNode; AVAudioEngine handles its own playout thread.
public final class AudioRenderer: @unchecked Sendable {
  private let codec: ScrcpyClient.AudioCodec
  private let sampleRate: Double = 48000
  private let channels: UInt32 = 2

  private var converter: AudioConverterRef?
  private var inAsbd: AudioStreamBasicDescription
  private var outAsbd: AudioStreamBasicDescription
  private var magicCookie: Data?

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let outputFormat: AVAudioFormat
  private var engineStarted = false

  // Per-call state for the AudioConverter input callback.
  private var pendingPacket: Data?
  private var pendingPacketConsumed = false
  private var scratch: UnsafeMutableRawBufferPointer?
  private var packetDesc = AudioStreamPacketDescription()

  public init(codec: ScrcpyClient.AudioCodec) throws {
    self.codec = codec
    self.inAsbd = Self.makeInputASBD(codec: codec, sampleRate: 48000, channels: 2)
    self.outAsbd = Self.makeOutputASBD(sampleRate: 48000, channels: 2)
    // AVAudioEngine.mainMixerNode only accepts non-interleaved Float32 — its
    // bus rejects interleaved with error -10868. So we decode straight into
    // the player's preferred deinterleaved layout: one buffer per channel.
    guard let fmt = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48000,
      channels: 2,
      interleaved: false
    ) else {
      throw DroidMirroringError.decoder("AVAudioFormat init failed")
    }
    self.outputFormat = fmt
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
  }

  deinit {
    if let c = converter { AudioConverterDispose(c) }
    scratch?.deallocate()
  }

  public func start() {
    guard !engineStarted else { return }
    do {
      try engine.start()
      player.play()
      engineStarted = true
    } catch {
      print("[audio] engine start failed: \(error)")
    }
  }

  public func stop() {
    if engineStarted {
      player.stop()
      engine.stop()
      engineStarted = false
    }
    if let c = converter {
      AudioConverterDispose(c)
      converter = nil
    }
    scratch?.deallocate()
    scratch = nil
  }

  /// Feed one packet from scrcpy. Config packets carry codec extradata.
  public func feed(packet: Data, isConfig: Bool, pts: CMTime) throws {
    if isConfig {
      magicCookie = packet
      if let c = converter {
        AudioConverterDispose(c)
        converter = nil
      }
      return
    }
    if converter == nil {
      try makeConverter()
    }
    guard let conv = converter else { return }
    try decodeAndEnqueue(conv: conv, packet: packet, pts: pts)
  }

  // MARK: converter

  private func makeConverter() throws {
    var conv: AudioConverterRef?
    let status = AudioConverterNew(&inAsbd, &outAsbd, &conv)
    guard status == noErr, let c = conv else {
      throw DroidMirroringError.decoder("AudioConverterNew status=\(status)")
    }
    if let cookie = magicCookie, !cookie.isEmpty {
      _ = cookie.withUnsafeBytes { buf -> OSStatus in
        AudioConverterSetProperty(
          c, kAudioConverterDecompressionMagicCookie,
          UInt32(cookie.count), buf.baseAddress!)
      }
    }
    converter = c
  }

  // MARK: decode

  private func decodeAndEnqueue(conv: AudioConverterRef, packet: Data, pts: CMTime) throws {
    pendingPacket = packet
    pendingPacketConsumed = false

    // Opus @ 48 k can emit up to 120 ms = 5760 frames per packet.
    let maxFramesPerPacket: UInt32 = 5760
    guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: maxFramesPerPacket) else {
      throw DroidMirroringError.decoder("AVAudioPCMBuffer alloc failed")
    }
    pcm.frameLength = 0
    guard let channelData = pcm.floatChannelData else {
      throw DroidMirroringError.decoder("PCM channel data missing")
    }

    // Non-interleaved stereo → one AudioBuffer per channel. Stack-allocating
    // an `AudioBufferList { mNumberBuffers: 2, ... }` from Swift undercounts the
    // struct's tail (Swift only sees `mBuffers: AudioBuffer`, sized for 1), so
    // we go through the platform allocator instead.
    let bytesPerChannel = maxFramesPerPacket * UInt32(MemoryLayout<Float32>.size)
    let ablPtr = AudioBufferList.allocate(maximumBuffers: Int(channels))
    defer { free(ablPtr.unsafeMutablePointer) }
    for ch in 0..<Int(channels) {
      ablPtr[ch] = AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: bytesPerChannel,
        mData: UnsafeMutableRawPointer(channelData[ch])
      )
    }

    var ioOutputDataPackets: UInt32 = maxFramesPerPacket
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    let status = AudioConverterFillComplexBuffer(
      conv, audioInputCallback, ctx,
      &ioOutputDataPackets,
      ablPtr.unsafeMutablePointer,
      nil
    )
    if status != noErr {
      print("[audio] AudioConverterFillComplexBuffer status=\(status)")
      return
    }
    if ioOutputDataPackets == 0 { return }
    pcm.frameLength = ioOutputDataPackets

    if !engineStarted { start() }
    player.scheduleBuffer(pcm, completionHandler: nil)
  }

  fileprivate func provideInputPacket(
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
  ) -> OSStatus {
    guard !pendingPacketConsumed, let packet = pendingPacket else {
      ioNumberDataPackets.pointee = 0
      return noErr
    }
    let count = packet.count

    // Back the compressed payload with an allocation the converter can hold across
    // the call. Freed on next call / stop / deinit.
    scratch?.deallocate()
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
    packet.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: count)
    scratch = .init(start: bytes, count: count)

    // Safe access to ioData via the Swift wrapper — handles the alignment
    // padding between mNumberBuffers and mBuffers correctly on every arch.
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    abl.unsafeMutablePointer.pointee.mNumberBuffers = 1
    abl[0] = AudioBuffer(
      mNumberChannels: channels,
      mDataByteSize: UInt32(count),
      mData: bytes
    )
    ioNumberDataPackets.pointee = 1

    if let outDesc = outDataPacketDescription {
      packetDesc.mStartOffset = 0
      packetDesc.mVariableFramesInPacket = 0
      packetDesc.mDataByteSize = UInt32(count)
      withUnsafeMutablePointer(to: &packetDesc) { p in
        outDesc.pointee = p
      }
    }

    pendingPacketConsumed = true
    return noErr
  }

  // MARK: ASBD builders

  private static func makeInputASBD(codec: ScrcpyClient.AudioCodec, sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = sampleRate
    asbd.mChannelsPerFrame = channels
    asbd.mFramesPerPacket = 0
    asbd.mBytesPerPacket = 0
    asbd.mBytesPerFrame = 0
    asbd.mBitsPerChannel = 0
    asbd.mFormatFlags = 0
    switch codec {
    case .opus:
      asbd.mFormatID = kAudioFormatOpus
      asbd.mFramesPerPacket = 960
    case .aac:
      asbd.mFormatID = kAudioFormatMPEG4AAC
      asbd.mFramesPerPacket = 1024
    case .flac:
      asbd.mFormatID = kAudioFormatFLAC
    case .raw:
      asbd.mFormatID = kAudioFormatLinearPCM
      asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
      asbd.mFramesPerPacket = 1
      asbd.mBitsPerChannel = 16
      asbd.mBytesPerFrame = 2 * channels
      asbd.mBytesPerPacket = asbd.mBytesPerFrame
    }
    return asbd
  }

  /// Non-interleaved Float32, one buffer per channel — matches AVAudioEngine's
  /// preferred bus format. Per Apple's docs, the ASBD for non-interleaved
  /// describes a single channel: bytes-per-frame == 4, channels-per-frame keeps
  /// the channel count, and the kAudioFormatFlagIsNonInterleaved flag tells the
  /// converter how to lay out the AudioBufferList.
  private static func makeOutputASBD(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
    var asbd = AudioStreamBasicDescription()
    asbd.mSampleRate = sampleRate
    asbd.mFormatID = kAudioFormatLinearPCM
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
    asbd.mFramesPerPacket = 1
    asbd.mChannelsPerFrame = channels
    asbd.mBitsPerChannel = 32
    asbd.mBytesPerFrame = 4         // single channel byte stride
    asbd.mBytesPerPacket = 4
    return asbd
  }
}

private func audioInputCallback(
  inAudioConverter: AudioConverterRef,
  ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
  ioData: UnsafeMutablePointer<AudioBufferList>,
  outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
  inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let inUserData else {
    ioNumberDataPackets.pointee = 0
    return noErr
  }
  let renderer = Unmanaged<AudioRenderer>.fromOpaque(inUserData).takeUnretainedValue()
  return renderer.provideInputPacket(
    ioNumberDataPackets: ioNumberDataPackets,
    ioData: ioData,
    outDataPacketDescription: outDataPacketDescription
  )
}
