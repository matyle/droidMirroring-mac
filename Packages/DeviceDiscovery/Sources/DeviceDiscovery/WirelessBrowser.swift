import Foundation
import Network
import Combine
import SharedModels

/// One mDNS-advertised wireless ADB endpoint.
/// Android 11+ devices in "Wireless debugging" mode publish two service types:
///   `_adb-tls-connect._tcp`  — already-paired, ready to `adb connect`
///   `_adb-tls-pairing._tcp`  — momentary, while "Pair with code" screen is open
/// Older Android 9-10 with `adb tcpip` publishes `_adb._tcp`.
public struct WirelessEndpoint: Identifiable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    case adb              // _adb._tcp (legacy)
    case tlsConnect       // _adb-tls-connect._tcp (already paired)
    case tlsPairing       // _adb-tls-pairing._tcp (showing pair code)
  }

  public let id: String              // "<kind>:<service-name>"
  public let kind: Kind
  public let serviceName: String     // e.g. "adb-RFCY71LT3MA-abcd"
  public let host: String            // resolved IPv4/IPv6 literal
  public let port: Int

  public var displayName: String { serviceName }
}

/// Wraps three concurrent `NWBrowser`s — one per service type — and exposes a
/// unified, deduplicated list of live endpoints via `@Published`.
@MainActor
public final class WirelessBrowser: ObservableObject {
  @Published public private(set) var endpoints: [WirelessEndpoint] = []
  @Published public private(set) var lastError: String?

  private var browsers: [NWBrowser] = []
  private var cache: [String: WirelessEndpoint] = [:]   // id -> endpoint

  public init() {}

  public func start() {
    guard browsers.isEmpty else { return }
    spin("_adb._tcp", kind: .adb)
    spin("_adb-tls-connect._tcp", kind: .tlsConnect)
    spin("_adb-tls-pairing._tcp", kind: .tlsPairing)
  }

  public func stop() {
    for b in browsers { b.cancel() }
    browsers.removeAll()
    cache.removeAll()
    endpoints.removeAll()
  }

  /// Filter helpers for the pairing UI.
  public var pairingCandidates: [WirelessEndpoint] {
    endpoints.filter { $0.kind == .tlsPairing }
  }

  public var connectableDevices: [WirelessEndpoint] {
    endpoints.filter { $0.kind == .tlsConnect || $0.kind == .adb }
  }

  // MARK: internals

  private func spin(_ serviceType: String, kind: WirelessEndpoint.Kind) {
    print("[wireless] starting NWBrowser for \(serviceType)")
    let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
    let params = NWParameters()
    params.includePeerToPeer = false
    let browser = NWBrowser(for: descriptor, using: params)

    browser.stateUpdateHandler = { [weak self] state in
      print("[wireless] \(serviceType) browser state: \(state)")
      if case .failed(let err) = state {
        Task { @MainActor in self?.lastError = "\(serviceType): \(err)" }
      }
    }

    browser.browseResultsChangedHandler = { [weak self] results, _ in
      print("[wireless] \(serviceType) callback: \(results.count) result(s)")
      for r in results { print("[wireless]   - \(r.endpoint)") }
      guard let self else { return }
      Task { @MainActor in self.apply(results: results, kind: kind) }
    }

    browser.start(queue: .main)
    browsers.append(browser)
  }

  private func apply(results: Set<NWBrowser.Result>, kind: WirelessEndpoint.Kind) {
    // Drop existing entries of this kind — Bonjour gives us the full set each callback.
    cache = cache.filter { $0.value.kind != kind }

    for result in results {
      guard case .service(let name, _, _, _) = result.endpoint else { continue }
      Task { @MainActor in
        if let resolved = await self.resolve(result: result) {
          print("[wireless] resolved \(name) -> \(resolved.host):\(resolved.port)")
          let endpoint = WirelessEndpoint(
            id: "\(kind.rawValue):\(name)",
            kind: kind,
            serviceName: name,
            host: resolved.host,
            port: resolved.port
          )
          self.cache[endpoint.id] = endpoint
          self.endpoints = Array(self.cache.values).sorted { $0.id < $1.id }
        } else {
          print("[wireless] resolve FAILED for \(name)")
        }
      }
    }
    endpoints = Array(cache.values).sorted { $0.id < $1.id }
  }

  /// Resolve a Bonjour service to host+port by opening a transient NWConnection.
  /// Returns nil if resolution times out or fails.
  private func resolve(result: NWBrowser.Result) async -> (host: String, port: Int)? {
    final class Latch: @unchecked Sendable { var fired = false; let q = DispatchQueue(label: "resolve.latch") }
    let latch = Latch()
    return await withCheckedContinuation { (cont: CheckedContinuation<(host: String, port: Int)?, Never>) in
      let conn = NWConnection(to: result.endpoint, using: .tcp)
      let finish: @Sendable ((host: String, port: Int)?) -> Void = { value in
        var shouldFire = false
        latch.q.sync { if !latch.fired { latch.fired = true; shouldFire = true } }
        guard shouldFire else { return }
        conn.cancel()
        cont.resume(returning: value)
      }
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if case .hostPort(let h, let p) = conn.currentPath?.remoteEndpoint,
             let hostStr = Self.format(host: h) {
            finish((hostStr, Int(p.rawValue)))
          } else {
            finish(nil)
          }
        case .failed, .cancelled:
          finish(nil)
        default: break
        }
      }
      conn.start(queue: .global(qos: .utility))
      DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { finish(nil) }
    }
  }

  nonisolated private static func format(host: NWEndpoint.Host) -> String? {
    switch host {
    case .name(let n, _): return n
    case .ipv4(let a):    return a.debugDescription.components(separatedBy: "%").first ?? "\(a)"
    case .ipv6:           return nil  // adb pair/connect doesn't support IPv6
    @unknown default:     return nil
    }
  }
}
