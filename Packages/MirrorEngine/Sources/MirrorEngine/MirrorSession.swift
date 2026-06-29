import Foundation
import CoreMedia
import CoreVideo
import os
import ScrcpyClient
import SharedModels

private let log = Logger(subsystem: "com.droidmirroring.app", category: "mirror")

/// One mirror session = one scrcpy server + one VideoStream + one VTDecoder + one renderer host.
/// Owns the receive loop; the caller binds a `FrameSink` to draw frames into a window.
public final class MirrorSession: @unchecked Sendable {
  public enum State: Sendable, Equatable {
    case idle
    case starting
    case streaming
    case stopping
    case stopped
    case failed(String)
  }

  public typealias FrameSink = @Sendable (CVPixelBuffer, CMTime) -> Void

  public private(set) var state: State = .idle
  public private(set) var deviceName: String = ""
  public private(set) var dimensions: (width: UInt32, height: UInt32) = (0, 0)
  public private(set) var control: ControlSocketWriter?
  public private(set) var deviceMessageReader: DeviceMessageReader?
  public private(set) var audioEnabled: Bool = false

  /// Pause audio playback on the Mac side.  scrcpy still streams audio packets;
  /// they are silently dropped until `resumeAudio()` is called.
  public func pauseAudio() {
    audioRenderer?.pause()
  }

  /// Resume audio playback on the Mac side after `pauseAudio()`.
  public func resumeAudio() {
    audioRenderer?.resume()
  }

  private let frameSink: FrameSink
  private var launcher: ScrcpyServerLauncher?
  private var stream: VideoStream?
  private var decoder: VTDecoder?
  private var receiveTask: Task<Void, Never>?
  private var audioStream: AudioStream?
  private var audioRenderer: AudioRenderer?
  private var audioTask: Task<Void, Never>?

  public init(frameSink: @escaping FrameSink) {
    self.frameSink = frameSink
  }

  public func start(launcher: ScrcpyServerLauncher, options: ScrcpyOptions) async throws {
    state = .starting
    self.launcher = launcher           // store BEFORE launch so stop() can clean up on failure
    let sockets = try await launcher.launch(options)
    self.deviceName = sockets.deviceName
    self.dimensions = (sockets.videoWidth, sockets.videoHeight)
    if let controlConn = sockets.control {
      // The control socket is duplex: writer pushes ControlMessages, reader
      // consumes DeviceMessages (clipboard, ack, uhid). NWConnection supports
      // concurrent send/receive on the same instance, so we hand it to both.
      self.control = ControlSocketWriter(connection: controlConn)
      self.deviceMessageReader = DeviceMessageReader(connection: controlConn)
    }

    let codec: VTDecoder.Codec = options.videoCodec == "h264" ? .h264 : .h265
    let sink = frameSink
    let decoder = VTDecoder(codec: codec) { pixelBuffer, pts in
      sink(pixelBuffer, pts)
    }
    self.decoder = decoder

    let stream = VideoStream(connection: sockets.video)
    self.stream = stream

    state = .streaming
    receiveTask = Task.detached { [weak self] in
      await self?.runReceiveLoop(stream: stream, decoder: decoder)
    }

    if let audioConn = sockets.audio {
      let aStream = AudioStream(connection: audioConn)
      self.audioStream = aStream
      audioTask = Task.detached { [weak self] in
        await self?.runAudioLoop(stream: aStream)
      }
      audioEnabled = true
    }
  }

  public func stop() async {
    state = .stopping
    receiveTask?.cancel()
    receiveTask = nil
    audioTask?.cancel()
    audioTask = nil
    await stream?.close()
    await audioStream?.close()
    audioStream = nil
    audioRenderer?.stop()
    audioRenderer = nil
    audioEnabled = false
    await control?.close()
    await deviceMessageReader?.close()
    control = nil
    deviceMessageReader = nil
    decoder?.reset()
    decoder = nil
    if let launcher { await launcher.stop() }
    launcher = nil
    state = .stopped
  }

  private func runAudioLoop(stream: AudioStream) async {
    let codec: AudioCodec
    do {
      codec = try await stream.readCodecHeader()
    } catch {
      log.error("audio codec header failed: \(error)")
      return
    }
    let renderer: AudioRenderer
    do {
      renderer = try AudioRenderer(codec: codec)
    } catch {
      log.error("AudioRenderer init failed: \(error)")
      return
    }
    self.audioRenderer = renderer
    renderer.start()
    while !Task.isCancelled {
      do {
        let frame = try await stream.nextFrame()
        let pts = CMTime(value: CMTimeValue(frame.pts), timescale: 1_000_000)
        try renderer.feed(packet: frame.payload, isConfig: frame.isConfig, pts: pts)
      } catch is CancellationError {
        return
      } catch {
        log.error("audio loop error: \(error)")
        return
      }
    }
  }

  private func runReceiveLoop(stream: VideoStream, decoder: VTDecoder) async {
    while !Task.isCancelled {
      do {
        let frame = try await stream.nextFrame()
        let pts = CMTime(value: CMTimeValue(frame.pts), timescale: 1_000_000)
        try decoder.feed(packet: frame.payload, pts: pts, isConfig: frame.isConfig)
      } catch is CancellationError {
        return
      } catch {
        state = .failed("\(error)")
        return
      }
    }
  }
}
