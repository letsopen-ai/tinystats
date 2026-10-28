import Darwin
import Foundation

public enum HTTPSCheckState: Int, Sendable, Equatable {
  case expected = 1
  case unexpected = 2
  case failed = 0
  public var title: String {
    switch self {
    case .expected: "Expected response"
    case .unexpected: "Unexpected response"
    case .failed: "Request failed"
    }
  }
}
public struct HTTPSCheckReading: Sendable, Equatable {
  public var state: HTTPSCheckState
  public var milliseconds: Double?
  public var checkedAt: Double
  public var reason: String
  public init(state: HTTPSCheckState, milliseconds: Double?, checkedAt: Double, reason: String) {
    self.state = state
    self.milliseconds = milliseconds
    self.checkedAt = checkedAt
    self.reason = reason
  }
}
public struct PublicIPReading: Sendable, Equatable {
  public var address: String?
  public var checkedAt: Double
  public var reason: String
  /// An observed transition between two successful provider responses, never the first baseline.
  public var changeID: String?
  public init(address: String?, checkedAt: Double, reason: String, changeID: String? = nil) {
    self.address = address
    self.checkedAt = checkedAt
    self.reason = reason
    self.changeID = changeID
  }
}
public struct InternetChecksSnapshot: Sendable, Equatable {
  public var connectivityEnabled = false, publicIPEnabled = false
  public var httpsCheck = HTTPSCheckConfiguration()
  public var pingCheck = ICMPCheckConfiguration()
  public var ping: ICMPCheckReading?
  public var pingChecking = false
  public var connectivity: HTTPSCheckReading?
  public var ipv4: PublicIPReading?, ipv6: PublicIPReading?
  public var revision = ""
  public var checking = false
  public init() {}
  public func filtered(
    connectivity: Bool, publicIP: Bool, revision: String, suspended: Bool = false,
    httpsCheck: HTTPSCheckConfiguration = .init(), pingCheck: ICMPCheckConfiguration = .init()
  ) -> Self {
    guard !suspended, self.revision == revision else { return .init() }
    var result = self
    result.connectivityEnabled =
      connectivity && connectivityEnabled && self.httpsCheck == httpsCheck
    result.publicIPEnabled = publicIP && publicIPEnabled
    if !pingCheck.enabled || self.pingCheck != pingCheck {
      result.ping = nil
      result.pingChecking = false
    }
    if !result.connectivityEnabled { result.connectivity = nil }
    if !result.publicIPEnabled {
      result.ipv4 = nil
      result.ipv6 = nil
    }
    if !result.connectivityEnabled && !result.publicIPEnabled { result.checking = false }
    return result
  }
}

enum InternetEndpoint: Int, CaseIterable, Sendable {
  case connectivity, ipv4, ipv6
  var url: URL {
    let value =
      switch self {
      case .connectivity: "https://www.apple.com/library/test/success.html"
      case .ipv4: "https://api.ipify.org"
      case .ipv6: "https://api6.ipify.org"
      }
    return URL(string: value)!
  }
  func accepts(_ responseURL: URL?) -> Bool {
    guard let responseURL, responseURL.scheme == "https", responseURL.host == url.host,
      (responseURL.port ?? 443) == 443, responseURL.user == nil, responseURL.password == nil,
      responseURL.query == nil, responseURL.fragment == nil
    else { return false }
    // URLSession canonicalizes a bare origin to a root-slash response URL.
    return (responseURL.path.isEmpty ? "/" : responseURL.path)
      == (url.path.isEmpty ? "/" : url.path)
  }
  var interval: Double { self == .connectivity ? 60 : 300 }
  var bodyLimit: Int { self == .connectivity ? 1024 : 128 }
}
enum HTTPProbeFailure: String, Sendable {
  case timeout = "Timed out"
  case dns = "DNS failed"
  case connection = "Connection failed"
  case tls = "TLS validation failed"
  case cancelled = "Canceled"
  case redirect = "Redirect rejected"
  case oversized = "Response too large"
  case invalid = "Invalid response"
  case other = "Request failed"
}
struct HTTPProbeReply: Sendable {
  var status: Int?, data = Data(), failure: HTTPProbeFailure?
}
protocol HTTPProbeTransport: AnyObject, Sendable {
  func start(
    _ endpoint: InternetEndpoint, check: HTTPSCheckConfiguration,
    completion: @escaping @Sendable (HTTPProbeReply) -> Void)
  func cancel()
  func shutdown()
}

struct InternetCheckLedger {
  private(set) var snapshot = InternetChecksSnapshot()
  private(set) var generation: UInt64 = 0
  private var path: [String]?
  private var lastRequests: [InternetEndpoint: Double] = [:]
  private var invalidated = Set<InternetEndpoint>()
  private var baseline: [InternetEndpoint: String] = [:]
  private var sequence: UInt64 = 0
  private let epoch = UUID().uuidString
  private(set) var active: (endpoint: InternetEndpoint, token: UInt64, started: Double)?
  @discardableResult mutating func configure(
    connectivity: Bool, publicIP: Bool, revision: String = "",
    httpsCheck: HTTPSCheckConfiguration = .init(), pingCheck: ICMPCheckConfiguration = .init()
  ) -> Bool {
    guard
      connectivity != snapshot.connectivityEnabled || publicIP != snapshot.publicIPEnabled
        || revision != snapshot.revision || httpsCheck != snapshot.httpsCheck
        || pingCheck != snapshot.pingCheck
    else {
      return false
    }
    generation &+= 1
    active = nil
    snapshot.checking = false
    if !connectivity || revision != snapshot.revision || httpsCheck != snapshot.httpsCheck {
      snapshot.connectivity = nil
    }
    if !publicIP || revision != snapshot.revision {
      snapshot.ipv4 = nil
      snapshot.ipv6 = nil
      baseline = [:]
    }
    snapshot.revision = revision
    snapshot.httpsCheck = httpsCheck
    snapshot.pingCheck = pingCheck
    snapshot.connectivityEnabled = connectivity && httpsCheck.validationError == nil
    snapshot.publicIPEnabled = publicIP
    invalidated = Set(InternetEndpoint.allCases.filter(isEnabled))
    return true
  }
  func isEnabled(_ endpoint: InternetEndpoint) -> Bool {
    endpoint == .connectivity ? snapshot.connectivityEnabled : snapshot.publicIPEnabled
  }
  mutating func reset() {
    generation &+= 1
    active = nil
    path = nil
    baseline = [:]
    snapshot.connectivity = nil
    snapshot.ipv4 = nil
    snapshot.ipv6 = nil
    snapshot.checking = false
    invalidated = Set(InternetEndpoint.allCases.filter(isEnabled))
  }
  /// Rate limits survive disable/resume. A route-change storm cannot request every tick.
  mutating func next(at time: Double, path nextPath: [String]) -> InternetEndpoint? {
    guard time.isFinite else { return nil }
    if path != nextPath {
      generation &+= 1
      active = nil
      path = nextPath
      snapshot.connectivity = nil
      snapshot.ipv4 = nil
      snapshot.ipv6 = nil
      snapshot.checking = false
      invalidated = Set(InternetEndpoint.allCases.filter(isEnabled))
    }
    guard active == nil else { return nil }
    let due = InternetEndpoint.allCases.filter { endpoint in
      guard isEnabled(endpoint) else { return false }
      let elapsed = time - (lastRequests[endpoint] ?? -Double.infinity)
      return elapsed >= (invalidated.contains(endpoint) ? 10 : endpoint.interval)
    }
    // Oldest request first prevents a frequently invalidated probe starving either IP family.
    guard
      let endpoint = due.min(by: {
        let lhs = lastRequests[$0] ?? -Double.infinity
        let rhs = lastRequests[$1] ?? -Double.infinity
        return lhs == rhs ? $0.rawValue < $1.rawValue : lhs < rhs
      })
    else { return nil }
    lastRequests[endpoint] = time
    invalidated.remove(endpoint)
    generation &+= 1
    active = (endpoint, generation, time)
    snapshot.checking = true
    return endpoint
  }
  mutating func finish(_ reply: HTTPProbeReply, token: UInt64, at time: Double) {
    guard let request = active, request.token == token, generation == token,
      time.isFinite, time >= request.started
    else { return }
    active = nil
    snapshot.checking = false
    let endpoint = request.endpoint
    guard isEnabled(endpoint) else { return }
    if endpoint == .connectivity {
      let state: HTTPSCheckState
      let reason: String
      if let failure = reply.failure {
        state =
          failure == .redirect || failure == .oversized || failure == .invalid
          ? .unexpected : .failed
        reason = failure.rawValue
      } else if reply.status
        == (snapshot.httpsCheck.isCustom ? snapshot.httpsCheck.expectedStatus : 200)
        && reply.data.count <= InternetEndpoint.connectivity.bodyLimit
        && (snapshot.httpsCheck.isCustom || Self.validAppleResponse(reply.data))
      {
        state = .expected
        reason =
          snapshot.httpsCheck.isCustom
          ? "HTTP \(snapshot.httpsCheck.expectedStatus) matched" : "Apple HTTPS test"
      } else {
        state = .unexpected
        reason =
          reply.status.map { "HTTP \($0) · unexpected status or content" } ?? "Invalid response"
      }
      snapshot.connectivity = .init(
        state: state, milliseconds: state == .expected ? (time - request.started) * 1000 : nil,
        checkedAt: time, reason: reason)
    } else {
      let address =
        reply.failure == nil && reply.status == 200
        ? Self.address(reply.data, family: endpoint == .ipv4 ? AF_INET : AF_INET6) : nil
      var changeID: String?
      if let address {
        if let previous = baseline[endpoint], previous != address {
          sequence &+= 1
          changeID = "\(epoch):\(sequence)"
        }
        baseline[endpoint] = address
      }
      let reading = PublicIPReading(
        address: address, checkedAt: time,
        reason: address != nil
          ? "ipify · OS-selected route" : reply.failure?.rawValue ?? "Invalid provider response",
        changeID: changeID)
      if endpoint == .ipv4 { snapshot.ipv4 = reading } else { snapshot.ipv6 = reading }
    }
  }
  static func validAppleResponse(_ data: Data) -> Bool {
    guard data.count <= 1024, let text = String(data: data, encoding: .utf8) else { return false }
    let compact = text.filter { !$0.isWhitespace }.lowercased()
    return compact == "<html><head><title>success</title></head><body>success</body></html>"
  }
  static func address(_ data: Data, family: Int32) -> String? {
    guard data.count <= 128, let raw = String(data: data, encoding: .utf8) else { return nil }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%"), !text.utf8.contains(0) else {
      return nil
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    guard text.withCString({ inet_pton(family, $0, &bytes) }) == 1 else { return nil }
    var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(family, bytes, &output, socklen_t(output.count)) != nil else { return nil }
    return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// Sampler calls and asynchronous completions share only this small locked ledger.
/// HTTP work never blocks the sampler; at most one logical request is active.
final class InternetChecksReader: @unchecked Sendable {
  private let lock = NSLock()
  private let transport: any HTTPProbeTransport
  private let clock: @Sendable () -> Double
  private var ledger = InternetCheckLedger()
  private var ping: ICMPChecksReader?
  init(
    transport: any HTTPProbeTransport = NativeHTTPProbe(), ping: ICMPChecksReader? = nil,
    clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.transport = transport
    self.ping = ping
    self.clock = clock
  }
  deinit { transport.shutdown() }
  func configure(
    connectivity: Bool, publicIP: Bool, revision: String = "",
    httpsCheck: HTTPSCheckConfiguration = .init(), pingCheck: ICMPCheckConfiguration = .init()
  ) {
    lock.lock()
    let changed = ledger.configure(
      connectivity: connectivity, publicIP: publicIP, revision: revision, httpsCheck: httpsCheck,
      pingCheck: pingCheck)
    if ping == nil && pingCheck.enabled && pingCheck.validationError == nil {
      ping = ICMPChecksReader(clock: clock)
    }
    let ping = self.ping
    lock.unlock()
    ping?.configure(pingCheck, revision: revision)
    if changed {
      transport.cancel()
      if !connectivity && !publicIP { transport.shutdown() }
    }
  }
  func reset() {
    lock.lock()
    ledger.reset()
    let ping = self.ping
    lock.unlock()
    ping?.reset()
    transport.shutdown()
  }
  func read(path: [String]) -> InternetChecksSnapshot {
    let time = clock()
    lock.lock()
    let oldGeneration = ledger.generation
    let oldActive = ledger.active
    let timedOut = ledger.active.map { time - $0.started >= 12 } ?? false
    if let request = ledger.active, timedOut {
      ledger.finish(.init(failure: .timeout), token: request.token, at: time)
    }
    let endpoint = ledger.next(at: time, path: path)
    let token = ledger.generation
    var snapshot = ledger.snapshot
    let ping = self.ping
    lock.unlock()
    if let ping { (snapshot.ping, snapshot.pingChecking) = ping.read(path: path) }
    if timedOut || oldGeneration != token || (oldActive != nil && endpoint != nil) {
      transport.cancel()
    }
    if let endpoint {
      transport.start(endpoint, check: snapshot.httpsCheck) { [weak self] reply in
        guard let self else { return }
        let now = self.clock()
        self.lock.lock()
        self.ledger.finish(reply, token: token, at: now)
        self.lock.unlock()
      }
    }
    return snapshot
  }
}
