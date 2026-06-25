import Foundation
import ADBKit
import ScrcpyClient
import SharedModels

@main
struct ScrcpySmoke {
  static func main() async {
    setvbuf(stdout, nil, _IONBF, 0)        // unbuffered: live progress under pipes
    do {
      try await run()
      print("\nSMOKE TEST PASSED")
    } catch {
      print("\nSMOKE TEST FAILED: \(error)")
      exit(1)
    }
  }

  static func run() async throws {
    let args = ProcessInfo.processInfo.arguments
    guard args.count >= 3 else {
      print("usage: scrcpy-smoke <path-to-scrcpy-server.jar> <path-to-adb> [serial]")
      exit(2)
    }
    let jar = URL(fileURLWithPath: args[1])
    let adbBin = URL(fileURLWithPath: args[2])
    let explicitSerial = args.count >= 4 ? args[3] : nil

    print("==> Bundled scrcpy-server: \(jar.path)")
    print("==> Bundled adb:           \(adbBin.path)")

    let adb = ADBClient()
    let version = try await adb.serverVersion()
    print("==> adb server protocol version: 0x\(String(version, radix: 16))")

    let devices = try await adb.listDevices()
    guard let device = (explicitSerial.flatMap { sn in devices.first { $0.id == sn } }) ?? devices.first(where: { $0.state == .online }) else {
      throw DroidMirroringError.deviceNotFound("no online devices (have: \(devices.map(\.id)))")
    }
    print("==> Using device: \(device.id) (\(device.model)) over \(device.transport.rawValue)")

    let sdkRaw = try await adb.shell("getprop ro.build.version.sdk", serial: device.id)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let mfg = try await adb.shell("getprop ro.product.manufacturer", serial: device.id)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    print("==> manufacturer=\(mfg) sdk=\(sdkRaw)")

    let resources = ScrcpyServerLauncher.Resources(serverJar: jar, adbBinary: adbBin)
    let launcher = ScrcpyServerLauncher(adb: adb, serial: device.id, resources: resources)

    print("==> Launching scrcpy-server …")
    let sockets = try await launcher.launch(ScrcpyOptions(
      videoBitRate: 4_000_000,
      maxFps: 30,
      videoCodec: "h264",
      audioEnabled: false,
      controlEnabled: false
    ))
    print("==> Sockets established")
    print("    device name : \(sockets.deviceName)")
    print("    video size  : \(sockets.videoWidth) x \(sockets.videoHeight)")

    let stream = VideoStream(connection: sockets.video)
    print("==> Reading first 5 frames …")
    var frameCount = 0
    var configReceived = false
    let deadline = Date().addingTimeInterval(10)
    while frameCount < 5, Date() < deadline {
      let frame = try await stream.nextFrame()
      frameCount += 1
      let kind = frame.isConfig ? "CONFIG" : (frame.isKeyframe ? "KEY" : "P")
      print("    [\(frameCount)] \(kind)  pts=\(frame.pts)  size=\(frame.payload.count)")
      if frame.isConfig { configReceived = true }
    }

    if !configReceived {
      throw DroidMirroringError.scrcpyProtocol("no config (SPS/PPS) packet received in first 5 frames")
    }
    if frameCount < 5 {
      throw DroidMirroringError.scrcpyProtocol("only read \(frameCount) frames in 10s")
    }

    await launcher.stop()
    print("==> launcher stopped")
  }
}
