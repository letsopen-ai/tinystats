import Foundation

/// One explicitly configured destination. The Apple preset also checks its known body.
public struct HTTPSCheckConfiguration: Codable, Equatable, Sendable {
  public var customURL: String
  public var expectedStatus: Int
  public init(customURL: String = "", expectedStatus: Int = 200) {
    self.customURL = customURL
    self.expectedStatus = expectedStatus
  }
  public var isCustom: Bool { !customURL.isEmpty }
  public var validationError: String? {
    guard (200...299).contains(expectedStatus) else { return "Expected status must be 200–299." }
    guard isCustom else {
      return expectedStatus == 200 ? nil : "The Apple preset expects HTTP 200."
    }
    guard customURL.utf8.count <= 512,
      customURL.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
      let parts = URLComponents(string: customURL), parts.scheme == "https",
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil, parts.port == nil || parts.port == 443,
      let url = parts.url, url.host != nil
    else {
      return
        "Use HTTPS (max 512 ASCII bytes), port 443, without credentials, query or fragment."
    }
    guard
      !parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { segment in
          let decoded = String(segment).removingPercentEncoding
          return decoded == "." || decoded == ".."
        })
    else { return "Use the final URL path without . or .. segments." }
    return nil
  }
  public var url: URL? {
    guard validationError == nil else { return nil }
    return URL(string: isCustom ? customURL : "https://www.apple.com/library/test/success.html")
  }
  public var title: String { isCustom ? "Custom HTTPS response" : "Apple HTTPS response" }
  func accepts(_ candidate: URL?) -> Bool {
    guard let candidate, let url,
      candidate.scheme == "https", candidate.host?.lowercased() == url.host?.lowercased(),
      (candidate.port ?? 443) == 443, candidate.user == nil, candidate.password == nil,
      candidate.query == nil, candidate.fragment == nil
    else { return false }
    // Compare encoded paths: decoded slash/query characters must not widen the destination.
    let lhs = URLComponents(url: candidate, resolvingAgainstBaseURL: false)?.percentEncodedPath
    let rhs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    return (lhs == "" ? "/" : lhs) == (rhs == "" ? "/" : rhs)
  }
}
