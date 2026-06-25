import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SharedModels

/// Writes decoded mirror frames to an .mp4 on disk via `AVAssetWriter`.
///
/// Lifecycle: `start(outputURL:size:)` → repeatedly `append(pixelBuffer:pts:)`
/// from MetalFrameRenderer's `onFrame` hook → `stop()` to flush and close.
public final class ScreenRecorder: @unchecked Sendable {
  public private(set) var isRecording = false
  public private(set) var outputURL: URL?

  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var startPTS: CMTime?

  public init() {}

  public func start(outputURL: URL, size: CGSize) throws {
    guard !isRecording else { return }
    try? FileManager.default.removeItem(at: outputURL)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 8_000_000,
        AVVideoMaxKeyFrameIntervalKey: 60,
      ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
      ]
    )
    guard writer.canAdd(input) else {
      throw DroidMirroringError.decoder("AVAssetWriter rejected video input")
    }
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    self.writer = writer
    self.input = input
    self.adaptor = adaptor
    self.outputURL = outputURL
    self.startPTS = nil
    self.isRecording = true
  }

  public func append(pixelBuffer: CVPixelBuffer, pts: CMTime) {
    guard isRecording, let input, let adaptor, input.isReadyForMoreMediaData else { return }
    if startPTS == nil { startPTS = pts }
    let relative = CMTimeSubtract(pts, startPTS ?? .zero)
    adaptor.append(pixelBuffer, withPresentationTime: relative)
  }

  /// Finish writing. Calls `completion` once the file is sealed and safe to open.
  public func stop(completion: @escaping @Sendable (URL?) -> Void) {
    guard isRecording else { completion(nil); return }
    isRecording = false
    let writer = self.writer
    let url = self.outputURL
    input?.markAsFinished()
    writer?.finishWriting { [weak self] in
      self?.writer = nil
      self?.input = nil
      self?.adaptor = nil
      self?.startPTS = nil
      completion(writer?.status == .completed ? url : nil)
    }
  }
}

/// One-shot helper to write the latest CVPixelBuffer to a PNG on disk.
public enum Screenshotter {
  public static func savePNG(pixelBuffer: CVPixelBuffer, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(ciImage, from: ciImage.extent) else {
      throw DroidMirroringError.decoder("CIContext could not produce CGImage")
    }
    guard let dest = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil
    ) else {
      throw DroidMirroringError.decoder("CGImageDestination init failed for \(url.path)")
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw DroidMirroringError.decoder("CGImageDestination finalize failed")
    }
  }
}
