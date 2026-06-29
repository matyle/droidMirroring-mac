import Foundation
import Network
import os
import ADBKit
import SharedModels

private let log = Logger(subsystem: "com.droidmirroring.app", category: "scrcpy")

/// scrcpy-server protocol version this client targets.
/// Must match the bundled `scrcpy-server-v<X>.jar` in App/Resources/.
public enum ScrcpyServerVersion {
  public static let current = "3.1"
}

public struct ScrcpyOptions: Sendable {
  public var videoBitRate: Int        // bps
  public var maxFps: Int
  public var videoCodec: String       // "h264" | "h265" | "av1"
  public var audioCodec: String       // "aac" | "opus" | "raw"
  public var audioEnabled: Bool
  public var controlEnabled: Bool
  public var maxSize: Int             // 0 = native
  public var displayId: Int           // 0 = default; foldables: pick the active panel
  public var newDisplay: String?      // "1920x1080/180" for Fusion freeform

  public init(
    videoBitRate: Int = 4_000_000,
    maxFps: Int = 30,
    videoCodec: String = "h265",
    audioCodec: String = "opus",
    audioEnabled: Bool = true,
    controlEnabled: Bool = true,
    maxSize: Int = 0,
    displayId: Int = 0,
    newDisplay: String? = nil
  ) {
    self.videoBitRate = videoBitRate
    self.maxFps = maxFps
    self.videoCodec = videoCodec
    self.audioCodec = audioCodec
    self.audioEnabled = audioEnabled
    self.controlEnabled = controlEnabled
    self.maxSize = maxSize
    self.displayId = displayId
    self.newDisplay = newDisplay
  }

  func serverArgs(scid: String) -> [String] {
    var args: [String] = [
      "scid=\(scid)",
      "log_level=info",
      "video_codec=\(videoCodec)",
      "video_bit_rate=\(videoBitRate)",
      "max_fps=\(maxFps)",
      "audio=\(audioEnabled ? "true" : "false")",
      "audio_codec=\(audioCodec)",
      "control=\(controlEnabled ? "true" : "false")",
      "display_id=\(displayId)",
      "tunnel_forward=false",
      "cleanup=true",
      "raw_stream=false",
    ]
    if maxSize > 0 { args.append("max_size=\(maxSize)") }
    if let nd = newDisplay { args.append("new_display=\(nd)") }
    return args
  }
}

public actor ScrcpyServerLauncher {
  public struct Sockets: Sendable {
    public let video: NWConnection
    public let audio: NWConnection?
    public let control: NWConnection?
    public let deviceName: String
    public let videoWidth: UInt32
    public let videoHeight: UInt32

    public init(
      video: NWConnection,
      audio: NWConnection?,
      control: NWConnection?,
      deviceName: String,
      videoWidth: UInt32,
      videoHeight: UInt32
    ) {
      self.video = video
      self.audio = audio
      self.control = control
      self.deviceName = deviceName
      self.videoWidth = videoWidth
      self.videoHeight = videoHeight
    }
  }

  public struct Resources: Sendable {
    public let serverJar: URL          // path to scrcpy-server-vX.jar
    public let adbBinary: URL?         // bundled `adb` used for `push` fallback

    public init(serverJar: URL, adbBinary: URL?) {
      self.serverJar = serverJar
      self.adbBinary = adbBinary
    }
  }

  private let adb: ADBClient
  private let serial: String
  private let resources: Resources
  private let sessionId: String
  private var acceptor: SocketAcceptor?
  private var shellConnection: ADBConnection?
  private var localAbstractName: String { "scrcpy_\(sessionId)" }
  private var remoteJarPath: String { "/data/local/tmp/scrcpy-server-\(sessionId).jar" }

  public init(adb: ADBClient, serial: String, resources: Resources) {
    self.adb = adb
    self.serial = serial
    self.resources = resources
    // scid is parsed by scrcpy-server with Java `Integer.parseInt(s, 16)`,
    // so the high bit must stay clear (max value 0x7fffffff).
    self.sessionId = String(format: "%08x", UInt32.random(in: 0..<0x7FFF_FFFF))
  }

  public func launch(_ options: ScrcpyOptions) async throws -> Sockets {
    // 1. push the server jar to /data/local/tmp/
    try await pushServerJar()

    // 2. listen locally for the reverse-forwarded sockets
    let socketCount = 1 + (options.audioEnabled ? 1 : 0) + (options.controlEnabled ? 1 : 0)
    let acceptor = try SocketAcceptor(expected: socketCount)
    let localPort = try await acceptor.start()
    self.acceptor = acceptor

    // 3. ask the device to forward `localabstract:<name>` → `tcp:<localPort>`
    try await adb.reverse(remoteUnixSocket: localAbstractName, localPort: Int(localPort), serial: serial)

    // 4. spawn `app_process` on the device. The shell connection stays open;
    //    we drain its stdout in the background so we don't deadlock on its pipe.
    let conn = ADBConnection(host: "127.0.0.1", port: 5037)
    try await conn.open()
    try await conn.sendCommand("host:transport:\(serial)")
    let cmd = buildAppProcessCommand(options: options)
    try await conn.sendCommand("shell:\(cmd)")
    self.shellConnection = conn
    drainShellOutput(conn)

    // 5. accept sockets in order: video → audio → control
    let videoConn = try await acceptor.next()
    let videoMeta = try await readVideoMetadata(videoConn)

    var audioConn: NWConnection?
    if options.audioEnabled {
      do {
        audioConn = try await acceptor.next()
      } catch {
        // Audio socket failed (timeout / device has no audio HAL).
        // Translate to a specific error so the caller can retry without audio.
        log.warning("audio socket failed — device may lack audio support: \(error)")
        throw DroidMirroringError.audioUnavailable(
          "Audio socket did not connect within timeout. " +
          "The device may lack an audio HAL (e.g. ZTE F50). " +
          "Original error: \(error.localizedDescription)"
        )
      }
    }

    var controlConn: NWConnection?
    if options.controlEnabled {
      controlConn = try await acceptor.next()
    }

    return Sockets(
      video: videoConn,
      audio: audioConn,
      control: controlConn,
      deviceName: videoMeta.deviceName,
      videoWidth: videoMeta.width,
      videoHeight: videoMeta.height
    )
  }

  public func stop() async {
    if let shell = shellConnection { await shell.close() }
    shellConnection = nil
    await acceptor?.stop()
    acceptor = nil
    try? await adb.removeReverse(remoteUnixSocket: localAbstractName, serial: serial)
    // NOTE: previous versions ran `adb shell ime reset` here to fix a Samsung
    // Android 16 quirk where IME focus stays pinned to the dead mirror
    // surface. But `ime reset` on Samsung is destructive — it resets the full
    // enabled-IMEs list, sometimes disabling third-party keyboards the user
    // installed. We removed it. If users hit the "no keyboard after mirror"
    // bug, the cheap workaround is tapping any text field once on the device.
  }

  // MARK: push

  /// scrcpy-server.jar push. M2: shell out to the bundled `adb` binary.
  /// M3 will replace this with a native SyncSession.send().
  private func pushServerJar() async throws {
    guard let adbBinary = resources.adbBinary else {
      throw DroidMirroringError.scrcpyProtocol("bundled adb binary missing; run scripts/fetch-adb.sh")
    }
    let process = Process()
    process.executableURL = adbBinary
    process.arguments = ["-s", serial, "push", resources.serverJar.path, remoteJarPath]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      throw DroidMirroringError.scrcpyProtocol("adb push failed: \(String(data: data, encoding: .utf8) ?? "")")
    }
  }

  // MARK: app_process

  private func buildAppProcessCommand(options: ScrcpyOptions) -> String {
    let args = options.serverArgs(scid: sessionId).joined(separator: " ")
    return "CLASSPATH=\(remoteJarPath) app_process / com.genymobile.scrcpy.Server \(ScrcpyServerVersion.current) \(args)"
  }

  private func drainShellOutput(_ conn: ADBConnection) {
    Task.detached {
      while !Task.isCancelled {
        let chunk = (try? await conn.readAvailable(maxLength: 4096)) ?? Data()
        if chunk.isEmpty { break }
        if let line = String(data: chunk, encoding: .utf8) {
          // M5: forward to a structured logger
          log.notice("scrcpy-server: \(line)")
        }
      }
    }
  }

  // MARK: video metadata

  /// scrcpy 3.x video socket starts with:
  ///   64 bytes: device name (null-padded UTF-8)
  ///   4 bytes:  codec id (FourCC, big-endian, e.g. "h264")
  ///   4 bytes:  width (big-endian u32)
  ///   4 bytes:  height (big-endian u32)
  /// No dummy byte (that was a scrcpy 2.x relic).
  private struct VideoMetadata {
    let deviceName: String
    let codecId: UInt32
    let width: UInt32
    let height: UInt32
  }

  private func readVideoMetadata(_ conn: NWConnection) async throws -> VideoMetadata {
    let header = try await readExact(conn, count: 64 + 4 + 4 + 4)
    let name = String(data: header[0..<64], encoding: .utf8)?
      .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    let codecId = header.subdata(in: 64..<68).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
    let width = header.subdata(in: 68..<72).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
    let height = header.subdata(in: 72..<76).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
    return VideoMetadata(deviceName: name, codecId: codecId, width: width, height: height)
  }

  private func readExact(_ conn: NWConnection, count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
        if let error { cont.resume(throwing: error); return }
        guard let data, data.count == count else {
          cont.resume(throwing: DroidMirroringError.scrcpyProtocol("short read on video socket"))
          return
        }
        cont.resume(returning: data)
      }
    }
  }
}
