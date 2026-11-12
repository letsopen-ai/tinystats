import Foundation
import Testing

@testable import TinyStatsCore

private final class UpdateHeaderBox: @unchecked Sendable {
  let lock = NSLock()
  private var stored: URLRequest?
  var request: URLRequest? { lock.withLock { stored } }
  func set(_ request: URLRequest?) { lock.withLock { stored = request } }
}
private final class UpdateOfflineURLProtocol: URLProtocol, @unchecked Sendable {
  static let captured = UpdateHeaderBox()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.captured.set(request)
    let data = Data("bounded reply".utf8)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Length": String(data.count)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Test func updateNativeTransportUsesFixedLanguageAndBoundedOfflineResponses() async throws {
  let transport = NativeUpdateTransport(
    version: "0.37.5",
    configuration: {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [UpdateOfflineURLProtocol.self]
      return configuration
    })
  let data = try await transport.get(UpdatePolicy.latestURL, limit: 100)
  #expect(data == Data("bounded reply".utf8))
  let request = try #require(UpdateOfflineURLProtocol.captured.request)
  #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
  #expect(
    request.value(forHTTPHeaderField: "User-Agent") == UpdatePolicy.userAgent(version: "0.37.5"))
  #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
  #expect(
    request.value(forHTTPHeaderField: "Cookie") == nil
      && request.value(forHTTPHeaderField: "Authorization") == nil)
  await #expect(throws: (any Error).self) {
    try await transport.get(UpdatePolicy.latestURL, limit: 4)
  }
}

@Test func updateNativeRedirectDelegateRejectsUnsafeHostsAndPreservesFixedHeaders() throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [UpdateOfflineURLProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  var original = URLRequest(url: UpdatePolicy.latestURL)
  original.setValue(UpdatePolicy.userAgent(version: "0.37.5"), forHTTPHeaderField: "User-Agent")
  // Never resumed; every call below drives the delegate directly.
  let task = session.dataTask(with: original)
  let response = HTTPURLResponse(
    url: UpdatePolicy.latestURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
  for text in [
    "https://release-assets.githubusercontent.com/asset", "http://github.com/asset",
    "https://evil.invalid/asset",
  ] {
    let box = UpdateHeaderBox()
    let delegate = UpdateRequest()
    delegate.urlSession(
      session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: URL(string: text)!)
    ) { box.set($0) }
    if text.hasPrefix("https://release-assets") {
      let next = try #require(box.request)
      #expect(next.value(forHTTPHeaderField: "Accept-Language") == "en")
      #expect(
        next.value(forHTTPHeaderField: "User-Agent")
          == original.value(forHTTPHeaderField: "User-Agent"))
    } else {
      #expect(box.request == nil)
    }
  }
}
