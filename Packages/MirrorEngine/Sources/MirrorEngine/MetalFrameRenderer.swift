import Foundation
import Metal
import MetalKit
import CoreVideo
import CoreMedia
import QuartzCore
import SharedModels

/// Renders incoming `CVPixelBuffer`s (NV12 from VideoToolbox) to a `CAMetalLayer`
/// via IOSurface-backed Metal textures — zero copy on the GPU path.
public final class MetalFrameRenderer: @unchecked Sendable {
  public let layer: CAMetalLayer
  /// Fires on the main thread whenever the incoming pixel-buffer dimensions change.
  /// Used by mirror windows to track rotation / foldable unfold / resolution swaps.
  public var onDimensionsChanged: (@Sendable (CGSize) -> Void)?
  /// Fires once per decoded frame on the renderer's queue. Used by screen recording
  /// to tap the same buffer the renderer just drew without doing a second decode.
  public var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
  public private(set) var lastDimensions: CGSize = .zero
  /// Most recent decoded frame — kept around as a CGImage cache slot for the
  /// "Screenshot" action. Updated on each render call.
  public private(set) var lastPixelBuffer: CVPixelBuffer?

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache?
  private let pipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState

  public init() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw DroidMirroringError.decoder("no Metal device")
    }
    self.device = device
    guard let queue = device.makeCommandQueue() else {
      throw DroidMirroringError.decoder("no Metal command queue")
    }
    self.commandQueue = queue

    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = true
    layer.isOpaque = true
    self.layer = layer

    CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

    let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = lib.makeFunction(name: "vs_fullscreen")
    desc.fragmentFunction = lib.makeFunction(name: "fs_nv12_bt709")
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm
    pipeline = try device.makeRenderPipelineState(descriptor: desc)

    let samplerDesc = MTLSamplerDescriptor()
    samplerDesc.minFilter = .linear
    samplerDesc.magFilter = .linear
    guard let s = device.makeSamplerState(descriptor: samplerDesc) else {
      throw DroidMirroringError.decoder("no Metal sampler")
    }
    sampler = s
  }

  public func render(pixelBuffer: CVPixelBuffer) {
    guard let cache = textureCache else { return }
    lastPixelBuffer = pixelBuffer
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let size = CGSize(width: width, height: height)
    if layer.drawableSize != size {
      layer.drawableSize = size
    }
    if lastDimensions != size {
      lastDimensions = size
      if let cb = onDimensionsChanged {
        DispatchQueue.main.async { cb(size) }
      }
    }
    if let onFrame {
      let pts = CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: 1_000_000_000)
      onFrame(pixelBuffer, pts)
    }
    guard
      let yTex = makeTexture(cache: cache, pixelBuffer: pixelBuffer, plane: 0, format: .r8Unorm),
      let cbcrTex = makeTexture(cache: cache, pixelBuffer: pixelBuffer, plane: 1, format: .rg8Unorm),
      let drawable = layer.nextDrawable(),
      let cmd = commandQueue.makeCommandBuffer()
    else { return }

    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = drawable.texture
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(yTex, index: 0)
    enc.setFragmentTexture(cbcrTex, index: 1)
    enc.setFragmentSamplerState(sampler, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cmd.present(drawable)
    cmd.commit()
  }

  private func makeTexture(
    cache: CVMetalTextureCache,
    pixelBuffer: CVPixelBuffer,
    plane: Int,
    format: MTLPixelFormat
  ) -> MTLTexture? {
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
    var ref: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pixelBuffer, nil, format, width, height, plane, &ref
    )
    guard status == kCVReturnSuccess, let ref else { return nil }
    return CVMetalTextureGetTexture(ref)
  }

  // Full-screen triangle + NV12 → BGRA in BT.709.
  private static let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct VOut { float4 pos [[position]]; float2 uv; };

  vertex VOut vs_fullscreen(uint vid [[vertex_id]]) {
    float2 pts[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 uvs[3] = { float2(0, 1),   float2(2, 1),  float2(0, -1) };
    VOut o;
    o.pos = float4(pts[vid], 0, 1);
    o.uv = uvs[vid];
    return o;
  }

  // BT.709 limited-range NV12 → RGB. Full-range works too; matrix tweak is small enough.
  fragment float4 fs_nv12_bt709(VOut in [[stage_in]],
                                texture2d<float> yTex   [[texture(0)]],
                                texture2d<float> cbcrTex[[texture(1)]],
                                sampler samp [[sampler(0)]]) {
    float y  = yTex.sample(samp, in.uv).r;
    float2 c = cbcrTex.sample(samp, in.uv).rg - float2(0.5, 0.5);
    float r = y + 1.5748 * c.y;
    float g = y - 0.1873 * c.x - 0.4681 * c.y;
    float b = y + 1.8556 * c.x;
    return float4(r, g, b, 1.0);
  }
  """
}
