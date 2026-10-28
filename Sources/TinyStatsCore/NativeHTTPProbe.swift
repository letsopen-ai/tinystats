import Foundation

/// URLSession delegates run serially; the lock also covers start/cancel from the sampler.
/// Framework buffers may exceed our retained cap; application-owned body storage does not.
final class NativeHTTPProbe: NSObject, HTTPProbeTransport, URLSessionDataDelegate,
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
  private var endpoint: InternetEndpoint?
  private var check = HTTPSCheckConfiguration()
  private var reply = HTTPProbeReply()
  private var completion: (@Sendable (HTTPProbeReply) -> Void)?
  private func makeSession() -> URLSession {
    let configuration = (injectedConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 10
    configuration.waitsForConnectivity = false
    configuration.httpMaximumConnectionsPerHost = 1
    let queue = OperationQueue()
    queue.name = "app.tinystats.internet-delegate"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }
  func start(
    _ endpoint: InternetEndpoint, check: HTTPSCheckConfiguration = .init(),
    completion: @escaping @Sendable (HTTPProbeReply) -> Void
  ) {
    guard let url = endpoint == .connectivity ? check.url : endpoint.url else {
      completion(.init(failure: .invalid))
      return
    }
    lock.lock()
    if session == nil { session = makeSession() }
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("TinyStats/1", forHTTPHeaderField: "User-Agent")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("text/plain, text/html;q=0.9", forHTTPHeaderField: "Accept")
    let previous = task
    let next = session!.dataTask(with: request)
    task = next
    self.endpoint = endpoint
    self.check = check
    reply = .init()
    self.completion = completion
    lock.unlock()
    previous?.cancel()
    next.resume()
  }
  func cancel() {
    lock.lock()
    let current = task
    task = nil
    endpoint = nil
    completion = nil
    reply = .init()
    lock.unlock()
    current?.cancel()
  }
  func shutdown() {
    lock.lock()
    let current = session
    session = nil
    task = nil
    endpoint = nil
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
    guard self.session === session, task === dataTask, let endpoint else {
      lock.unlock()
      completionHandler(.cancel)
      return
    }
    let response = response as? HTTPURLResponse
    reply.status = response?.statusCode
    let failure: HTTPProbeFailure? =
      !(endpoint == .connectivity ? check.accepts(response?.url) : endpoint.accepts(response?.url))
      ? .invalid
      : response!.expectedContentLength > Int64(endpoint.bodyLimit) ? .oversized : nil
    if let failure { reply.failure = failure }
    lock.unlock()
    completionHandler(failure == nil ? .allow : .cancel)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard self.session === session, task === dataTask, let endpoint else {
      lock.unlock()
      return
    }
    let oversized = data.count > endpoint.bodyLimit - reply.data.count
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
    if self.session === session, self.task === task {
      reply.status = response.statusCode
      reply.failure = .redirect
    }
    lock.unlock()
    completionHandler(nil)
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
    endpoint = nil
    reply = .init()
    lock.unlock()
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
