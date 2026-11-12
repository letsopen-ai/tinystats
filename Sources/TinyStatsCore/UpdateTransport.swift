import Foundation

public protocol UpdateTransport: Sendable {
  func get(_ url: URL, limit: Int) async throws -> Data
}

/// Each request owns an ephemeral session. Its serial delegate caps retained bytes before append.
public struct NativeUpdateTransport: UpdateTransport {
  public let version: String
  private let configuration: @Sendable () -> URLSessionConfiguration
  public init(
    version: String,
    configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
  ) {
    self.version = version
    self.configuration = configuration
  }
  public func get(_ url: URL, limit: Int) async throws -> Data {
    guard UpdatePolicy.allows(url), limit > 0, limit <= UpdatePolicy.archiveLimit else {
      throw UpdateError.invalid("The update destination is not allowed.")
    }
    let request = UpdateRequest()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        request.start(
          url: url, version: version, limit: limit, configuration: configuration(),
          continuation: continuation)
      }
    } onCancel: {
      request.cancel()
    }
  }
}

final class UpdateRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var session: URLSession?
  private var continuation: CheckedContinuation<Data, any Error>?
  private var body = Data()
  private var failure: (any Error)?
  var responseFailure: (any Error)? { lock.withLock { failure } }
  private var limit = 0
  private var redirects = 0
  private var cancelled = false
  func cancel() {
    lock.withLock {
      cancelled = true
      session?.invalidateAndCancel()
    }
  }
  func start(
    url: URL, version: String, limit: Int, configuration: URLSessionConfiguration,
    continuation: CheckedContinuation<Data, any Error>
  ) {
    lock.withLock {
      if cancelled {
        continuation.resume(throwing: CancellationError())
        return
      }
      self.continuation = continuation
      self.limit = limit
      let config = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
      config.urlCache = nil
      config.urlCredentialStorage = nil
      config.httpCookieStorage = nil
      config.httpShouldSetCookies = false
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      config.timeoutIntervalForRequest = 30
      config.timeoutIntervalForResource = 180
      config.waitsForConnectivity = false
      config.httpMaximumConnectionsPerHost = 1
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      queue.qualityOfService = .utility
      let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
      self.session = session
      var request = URLRequest(url: url)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue(UpdatePolicy.userAgent(version: version), forHTTPHeaderField: "User-Agent")
      request.setValue("en", forHTTPHeaderField: "Accept-Language")
      request.httpShouldHandleCookies = false
      session.dataTask(with: request).resume()
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    lock.withLock {
      redirects += 1
      guard let url = request.url, UpdatePolicy.allows(url), redirects <= 5 else {
        failure = UpdateError.invalid("GitHub redirected to a destination that is not allowed.")
        completionHandler(nil)
        task.cancel()
        return
      }
      var next = URLRequest(url: url)
      next.setValue(
        task.originalRequest?.value(forHTTPHeaderField: "User-Agent"),
        forHTTPHeaderField: "User-Agent")
      next.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      next.setValue("en", forHTTPHeaderField: "Accept-Language")
      next.httpShouldHandleCookies = false
      completionHandler(next)
    }
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    lock.withLock {
      // A rejected redirect may still deliver its 302 response. Keep the original
      // security failure instead of replacing it with the less useful HTTP error.
      guard failure == nil else {
        completionHandler(.cancel)
        return
      }
      guard let http = response as? HTTPURLResponse, let url = http.url, UpdatePolicy.allows(url)
      else {
        failure = UpdateError.invalid("Invalid update response.")
        completionHandler(.cancel)
        return
      }
      let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
        result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
      }
      failure = UpdateHTTPPolicy.failure(
        status: http.statusCode, url: url, headers: headers,
        length: response.expectedContentLength, limit: limit, now: Date())
      completionHandler(failure == nil ? .allow : .cancel)
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.withLock {
      guard failure == nil else {
        dataTask.cancel()
        return
      }
      guard data.count <= limit - body.count else {
        failure = UpdateError.invalid("The update response is too large.")
        dataTask.cancel()
        return
      }
      body.append(data)
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    lock.withLock {
      if let failure = failure ?? error {
        continuation?.resume(throwing: failure)
      } else {
        continuation?.resume(returning: body)
      }
      continuation = nil
      body = Data()
      self.session = nil
    }
    session.finishTasksAndInvalidate()
  }
  static func retryDate(headers: [AnyHashable: Any], now: Date) -> Date {
    UpdateRateLimit.retryDate(
      headers: headers.reduce(into: [:]) { result, pair in
        result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
      }, now: now)
  }
}

public enum UpdateHTTPPolicy {
  public static func failure(
    status: Int, url: URL, headers: [String: String], length: Int64,
    limit: Int, now: Date
  ) -> UpdateError? {
    guard UpdatePolicy.allows(url) else { return .invalid("Invalid update response.") }
    if status == 429
      || (status == 403 && url.host == "api.github.com"
        && (headers["x-ratelimit-remaining"] == "0" || headers["retry-after"] != nil))
    {
      return .rateLimited(UpdateRateLimit.retryDate(headers: headers, now: now))
    }
    guard status == 200 else { return .invalid("GitHub returned HTTP \(status).") }
    guard length <= Int64(limit) else { return .invalid("The update response is too large.") }
    return nil
  }
}

public enum UpdateRateLimit {
  public static func retryDate(headers: [String: String], now: Date) -> Date {
    var dates = [now.addingTimeInterval(3600)]
    if let value = headers["retry-after"], value.utf8.count <= 128 {
      if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
        dates.append(now.addingTimeInterval(seconds))
      } else {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = format.date(from: value) { dates.append(date) }
      }
    }
    if let value = headers["x-ratelimit-reset"], let epoch = Double(value), epoch.isFinite {
      dates.append(Date(timeIntervalSince1970: epoch))
    }
    return min(dates.max()!, now.addingTimeInterval(86_400))
  }
}

public struct UpdateClient: Sendable {
  public let transport: any UpdateTransport
  public init(transport: any UpdateTransport) { self.transport = transport }
  public func check(version: String, build: String) async throws -> UpdateCandidate? {
    let data = try await transport.get(UpdatePolicy.latestURL, limit: UpdatePolicy.jsonLimit)
    let release = try UpdateRelease.parse(data)
    let asset = try release.asset("release.json", limit: UpdatePolicy.jsonLimit)
    let manifest = try await transport.get(
      asset.downloadURL, limit: UpdatePolicy.jsonLimit)
    return try release.candidate(manifest: manifest, runningVersion: version, runningBuild: build)
  }
  public func download(_ candidate: UpdateCandidate) async throws -> Data {
    let archive = try await transport.get(candidate.archiveURL, limit: UpdatePolicy.archiveLimit)
    let sums: Data?
    if let url = candidate.sumsURL {
      sums = try await transport.get(url, limit: UpdatePolicy.jsonLimit)
    } else {
      sums = nil
    }
    try UpdatePolicy.verifyArchive(archive, manifest: candidate.manifest, sums: sums)
    return archive
  }
}
