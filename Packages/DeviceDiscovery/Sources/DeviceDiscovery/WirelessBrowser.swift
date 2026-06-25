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
  public let host: String            // resolved IPv4 address
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

  /// Resolve a Bonjour service to an IPv4 host+port.
  ///
  /// Uses `DNSServiceResolve` to get the service's hostname and port,
  /// then `getaddrinfo(AF_INET)` to force an IPv4 address lookup.
  /// This avoids the NWConnection IPv6-first issue that blocks discovery
  /// when macOS has IPv6 enabled (Android ADB wireless only supports IPv4).
  private func resolve(result: NWBrowser.Result) async -> (host: String, port: Int)? {
    guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }

    return await withCheckedContinuation { continuation in
      let resolver = ServiceResolver(name: name, type: type, domain: domain)
      resolver.resolve { host, port in
        continuation.resume(returning: host.map { ($0, port) })
      }
    }
  }
}

// MARK: - Service Resolver (IPv4-only DNS-SD)

/// Resolves an mDNS service to an IPv4 address using the C DNS-SD API.
private final class ServiceResolver: @unchecked Sendable {
  private let name: String
  private let type: String
  private let domain: String
  private var sdRef: DNSServiceRef?

  init(name: String, type: String, domain: String) {
    self.name = name
    self.type = type
    self.domain = domain
  }

  func resolve(completion: @escaping @Sendable (String?, Int) -> Void) {
    var sdRef: DNSServiceRef?
    let context = Unmanaged.passUnretained(self).toOpaque()

    let status = name.withCString { namePtr in
      type.withCString { typePtr in
        domain.withCString { domainPtr in
          DNSServiceResolve(
            &sdRef, 0, 0, namePtr, typePtr, domainPtr,
            ServiceResolver.resolveCallback, context
          )
        }
      }
    }

    guard status == kDNSServiceErr_NoError, let ref = sdRef else {
      completion(nil, 0)
      return
    }
    self.sdRef = ref

    // Run DNSServiceProcessResult on a background thread (blocking call)
    DispatchQueue.global(qos: .utility).async { [resolver = self] in
      let refToUse = resolver.sdRef

      // Timeout: deallocate after 2 seconds
      DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
        if let ref = refToUse {
          DNSServiceRefDeallocate(ref)
          resolver.sdRef = nil
        }
      }

      // Process results — this blocks until the reply arrives or the ref is deallocated
      if let ref = refToUse {
        DNSServiceProcessResult(ref)
      }
    }

    // Store the completion for use in the callback
    self.completion = completion
  }

  fileprivate var completion: (@Sendable (String?, Int) -> Void)?

  fileprivate func finish(host: String?, port: Int) {
    if let ref = sdRef {
      DNSServiceRefDeallocate(ref)
      sdRef = nil
    }
    completion?(host, port)
    completion = nil
  }

  /// C callback for DNSServiceResolve — must be a static function.
  static let resolveCallback: DNSServiceResolveReply = {
    sdRef, _, _, _, _, hosttarget, port, _, _, context in
    guard let context, let hosttarget else { return }
    let resolver = Unmanaged<ServiceResolver>.fromOpaque(context).takeUnretainedValue()

    var hostStr = String(cString: hosttarget)
    if hostStr.hasSuffix(".") { hostStr.removeLast() }
    let portNum = Int(UInt16(bigEndian: port))

    // Resolve hostname to IPv4 address using getaddrinfo (AF_INET only)
    var hints = addrinfo()
    hints.ai_family = AF_INET        // IPv4 only — ADB wireless doesn't support IPv6
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>?
    if getaddrinfo(hostStr, nil, &hints, &result) == 0, let ai = result {
      let ipv4 = ai.pointee.ai_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &ptr.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
      }
      freeaddrinfo(result)
      resolver.finish(host: ipv4, port: portNum)
    } else {
      // Fallback: return hostname directly (adb might resolve it)
      resolver.finish(host: hostStr, port: portNum)
    }
  }
}
