import Foundation

/// URLSession delegates run serially; the lock also covers start/cancel from the sampler.
/// Framework buffers may exceed our retained cap; application-owned body storage does not.
final class NativeWeatherTransport: NSObject, WeatherTransport, URLSessionDataDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let injectedConfiguration: URLSessionConfiguration?
  init(configuration: URLSessionConfiguration? = nil) {
    injectedConfiguration = configuration
    super.init()
  }
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var requestURL: URL?
  private var redirects = 0
  private var reply = WeatherReply()
  private var completion: (@Sendable (WeatherReply) -> Void)?
  private func makeSession() -> URLSession {
    let configuration = (injectedConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 25
    configuration.waitsForConnectivity = false
    configuration.httpMaximumConnectionsPerHost = 1
    let queue = OperationQueue()
    queue.name = "app.tinystats.weather-delegate"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }
  static func url(for location: WeatherLocation) -> URL? {
    guard let location = location.validated else { return nil }
    var parts = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")!
    let coordinates = location.requestKey.split(separator: ",").map(String.init)
    parts.queryItems = [
      URLQueryItem(name: "lat", value: coordinates[0]),
      URLQueryItem(name: "lon", value: coordinates[1]),
    ]
    return parts.url
  }
  func start(
    location: WeatherLocation, lastModified: String?,
    completion: @escaping @Sendable (WeatherReply) -> Void
  ) {
    guard let url = Self.url(for: location) else {
      completion(.init(failure: .invalid))
      return
    }
    lock.lock()
    if session == nil { session = makeSession() }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(
      UpdatePolicy.userAgent(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "unknown"), forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let lastModified, lastModified.utf8.count <= 128, Self.httpDate(lastModified) != nil {
      request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
    }
    let previous = task
    let next = session!.dataTask(with: request)
    task = next
    requestURL = url
    redirects = 0
    reply = .init()
    self.completion = completion
    lock.unlock()
    previous?.cancel()
    next.resume()
  }
  private static func httpDate(_ text: String) -> Date? {
    guard text.utf8.count <= 128 else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: text)
  }
  static func allowsRedirect(_ url: URL?, from original: URL?) -> Bool {
    guard let url, let original else { return false }
    return url.scheme == "https" && url.host == "api.met.no" && (url.port ?? 443) == 443
      && url.user == nil && url.password == nil && url.fragment == nil
      && url.path.hasPrefix("/weatherapi/locationforecast/") && url.query == original.query
  }
  private func accepts(_ url: URL?) -> Bool {
    guard let url, let requestURL else { return false }
    return url.scheme == "https" && url.host == "api.met.no" && (url.port ?? 443) == 443
      && url.user == nil && url.password == nil && url.fragment == nil
      && url.path == requestURL.path && url.query == requestURL.query
  }
  func cancel() {
    shutdown()
  }
  func shutdown() {
    lock.lock()
    let current = session
    session = nil
    task = nil
    requestURL = nil
    completion = nil
    reply = .init()
    lock.unlock()
    current?.invalidateAndCancel()
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    guard self.session === session, task === dataTask, requestURL != nil else {
      lock.unlock()
      completionHandler(.cancel)
      return
    }
    let response = response as? HTTPURLResponse
    reply.status = response?.statusCode
    let failure: HTTPProbeFailure? =
      !accepts(response?.url)
      ? .invalid
      : response!.expectedContentLength > Int64(WeatherDecoder.bodyLimit) ? .oversized : nil
    if let response {
      if let text = response.value(forHTTPHeaderField: "Expires") {
        reply.expires = Self.httpDate(text)
      }
      if let cache = response.value(forHTTPHeaderField: "Cache-Control"), cache.utf8.count <= 1024 {
        for directive in cache.lowercased().split(separator: ",") {
          let pair = directive.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
          }
          if pair.count == 2, pair[0] == "max-age",
            let seconds = Double(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
            seconds.isFinite, seconds >= 0
          {
            let age = Double(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0
            let date = Date().addingTimeInterval(max(0, seconds - (age.isFinite ? max(0, age) : 0)))
            if reply.expires == nil || date > reply.expires! { reply.expires = date }
          }
        }
      }
      if let text = response.value(forHTTPHeaderField: "Last-Modified"), Self.httpDate(text) != nil
      {
        reply.lastModified = text
      }
      if let text = response.value(forHTTPHeaderField: "Retry-After"), text.utf8.count <= 128 {
        if let seconds = Double(text), seconds.isFinite, seconds >= 0 {
          reply.retryAfter = seconds
        } else if let date = Self.httpDate(text) {
          reply.retryAfter = max(0, date.timeIntervalSinceNow)
        }
      }
    }
    if let failure { reply.failure = failure }
    lock.unlock()
    completionHandler(failure == nil ? .allow : .cancel)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard self.session === session, task === dataTask, requestURL != nil else {
      lock.unlock()
      return
    }
    let oversized = data.count > WeatherDecoder.bodyLimit - reply.data.count
    if oversized {
      reply.failure = .oversized
      reply.data = Data()
    } else if reply.failure == nil {
      reply.data.append(data)
    }
    lock.unlock()
    if oversized { dataTask.cancel() }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    lock.lock()
    let allowed =
      self.session === session && self.task === task && redirects < 3
      && Self.allowsRedirect(request.url, from: requestURL)
    if allowed {
      redirects += 1
    } else if self.session === session, self.task === task {
      reply.failure = .redirect
    }
    lock.unlock()
    completionHandler(allowed ? request : nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    lock.lock()
    guard self.session === session, self.task === task else {
      lock.unlock()
      return
    }
    if reply.failure == nil, let error {
      let code = (error as? URLError)?.code
      reply.failure =
        switch code {
        case .timedOut: .timeout
        case .cannotFindHost, .dnsLookupFailed: .dns
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost: .connection
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
          .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
          .clientCertificateRejected,
          .clientCertificateRequired:
          .tls
        case .cancelled: .cancelled
        default: .other
        }
    }
    let callback = completion
    let result = reply
    completion = nil
    self.task = nil
    self.session = nil
    requestURL = nil
    reply = .init()
    lock.unlock()
    // Forecasts refresh no more often than every 30 minutes per location. Keep only
    // the bounded forecast/validator state between requests, not a session/delegate cycle.
    session.finishTasksAndInvalidate()
    callback?(result)
  }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // Preserve normal system certificate validation; never supply account/proxy credentials.
    completionHandler(
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    completionHandler(
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    willCacheResponse proposedResponse: CachedURLResponse,
    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
  ) {
    completionHandler(nil)
  }
}
