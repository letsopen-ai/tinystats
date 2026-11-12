import CoreFoundation
import CryptoKit
import Foundation

public enum UpdateError: Error, LocalizedError, Equatable, Sendable {
  case invalid(String)
  case rateLimited(Date)
  public var errorDescription: String? {
    switch self {
    case .invalid(let reason): reason
    case .rateLimited(let date): "GitHub has limited requests. Try again after \(date.formatted())."
    }
  }
}

public struct UpdateVersion: Comparable, Sendable {
  public let components: [Int]
  public init(_ text: String) throws {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, text.utf8.count <= 40 else {
      throw UpdateError.invalid("Invalid release version.")
    }
    components = try parts.map {
      guard !$0.isEmpty, $0.utf8.allSatisfy({ (48...57).contains($0) }),
        $0 == "0" || !$0.hasPrefix("0"), let number = Int($0)
      else { throw UpdateError.invalid("Invalid release version.") }
      return number
    }
  }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.components.lexicographicallyPrecedes(rhs.components)
  }
}

public enum UpdatePolicy {
  public static let bundleID = "com.niechen.tinystats"
  public static let teamID = "CVQJTDR4LG"
  public static let latestURL = URL(
    string: "https://api.github.com/repos/letsopen-ai/tinystats/releases/latest")!
  public static let releasesURL = URL(string: "https://github.com/letsopen-ai/tinystats/releases")!
  public static let jsonLimit = 1_048_576
  public static let archiveLimit = 64 * 1_048_576
  public static let hosts: Set<String> = [
    "api.github.com", "github.com", "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
  ]
  public static func allows(_ url: URL) -> Bool {
    url.scheme == "https" && hosts.contains(url.host ?? "") && (url.port ?? 443) == 443
      && url.user == nil && url.password == nil && url.fragment == nil
  }
  public static func releasePage(_ url: URL) -> Bool {
    allows(url) && url.host == "github.com" && url.query == nil
      && url.path.hasPrefix("/letsopen-ai/tinystats/releases/")
      && !url.path.contains("..")
  }
  public static func userAgent(version: String) -> String {
    "TinyStats/\((try? UpdateVersion(version)) == nil ? "unknown" : version) (https://github.com/letsopen-ai/tinystats)"
  }
  public static func build(_ value: String) throws -> Int {
    guard !value.isEmpty, value.utf8.count <= 18,
      value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), number > 0,
      String(number) == value
    else { throw UpdateError.invalid("Invalid release build.") }
    return number
  }
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func verifyArchive(_ data: Data, manifest: UpdateManifest, sums: Data?) throws {
    guard !data.isEmpty, data.count <= archiveLimit, digest(data) == manifest.sha256 else {
      throw UpdateError.invalid("The update archive checksum does not match.")
    }
    if let sums {
      guard sums.count <= jsonLimit, let text = String(data: sums, encoding: .utf8) else {
        throw UpdateError.invalid("Invalid SHA256SUMS.txt.")
      }
      let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[1].drop(while: { $0 == "*" }) == manifest.file else {
          return nil
        }
        return String(parts[0]).lowercased()
      }
      guard matches == [manifest.sha256] else {
        throw UpdateError.invalid("SHA256SUMS.txt disagrees with release.json.")
      }
    }
  }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
  public let version: String
  public let build: String
  public let sha256: String
  public let file: String
  public init(version: String, build: String, sha256: String, file: String) {
    self.version = version
    self.build = build
    self.sha256 = sha256
    self.file = file
  }
  public func validate() throws {
    _ = try UpdateVersion(version)
    _ = try UpdatePolicy.build(build)
    guard file == "TinyStats-\(version)-macOS-universal.zip", sha256.utf8.count == 64,
      sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw UpdateError.invalid("Invalid release filename or checksum.") }
  }
}

public struct UpdateAsset: Decodable, Sendable {
  enum CodingKeys: String, CodingKey {
    case name, size
    case downloadURL = "browser_download_url"
  }
  public let name: String
  public let downloadURL: URL
  public let size: Int
}
public struct UpdateRelease: Decodable, Sendable {
  enum CodingKeys: String, CodingKey {
    case draft, prerelease, assets
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
  public let tagName: String
  public let draft: Bool
  public let prerelease: Bool
  public let htmlURL: URL
  public let assets: [UpdateAsset]
  public static func parse(_ data: Data) throws -> Self {
    guard data.count <= UpdatePolicy.jsonLimit else {
      throw UpdateError.invalid("Release JSON is too large.")
    }
    let release = try JSONDecoder().decode(Self.self, from: data)
    guard !release.draft, !release.prerelease, release.tagName.hasPrefix("v"),
      UpdatePolicy.releasePage(release.htmlURL), release.assets.count <= 100,
      Set(release.assets.map(\.name)).count == release.assets.count
    else { throw UpdateError.invalid("Invalid or unpublished release.") }
    _ = try UpdateVersion(String(release.tagName.dropFirst()))
    return release
  }
  public func asset(_ name: String, limit: Int) throws -> UpdateAsset {
    guard let asset = assets.first(where: { $0.name == name }), asset.size > 0,
      asset.size <= limit, UpdatePolicy.allows(asset.downloadURL),
      asset.downloadURL.host == "github.com",
      asset.downloadURL.path
        == "/letsopen-ai/tinystats/releases/download/\(tagName)/\(name)",
      asset.downloadURL.query == nil
    else { throw UpdateError.invalid("Missing or invalid release asset: \(name)") }
    return asset
  }
  public func candidate(manifest data: Data, runningVersion: String, runningBuild: String) throws
    -> UpdateCandidate?
  {
    guard data.count <= UpdatePolicy.jsonLimit else {
      throw UpdateError.invalid("Manifest is too large.")
    }
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
    try manifest.validate()
    guard manifest.version == String(tagName.dropFirst()) else {
      throw UpdateError.invalid("The tag and release manifest disagree.")
    }
    let archive = try asset(manifest.file, limit: UpdatePolicy.archiveLimit)
    guard try UpdatePolicy.build(manifest.build) > UpdatePolicy.build(runningBuild),
      try UpdateVersion(manifest.version) > UpdateVersion(runningVersion)
    else { return nil }
    let sums =
      assets.contains(where: { $0.name == "SHA256SUMS.txt" })
      ? try asset("SHA256SUMS.txt", limit: UpdatePolicy.jsonLimit).downloadURL : nil
    return .init(
      manifest: manifest, archiveURL: archive.downloadURL, sumsURL: sums,
      releaseURL: htmlURL)
  }
}
public struct UpdateCandidate: Sendable {
  public let manifest: UpdateManifest
  public let archiveURL: URL
  public let sumsURL: URL?
  public let releaseURL: URL
  public init(manifest: UpdateManifest, archiveURL: URL, sumsURL: URL?, releaseURL: URL) {
    self.manifest = manifest
    self.archiveURL = archiveURL
    self.sumsURL = sumsURL
    self.releaseURL = releaseURL
  }
}

public struct UpdateEligibility: Sendable {
  public var bundleID: String?
  public var teamID: String?
  public var developerID: Bool
  public var translocated: Bool
  public var readOnly: Bool
  public init(
    bundleID: String?, teamID: String?, developerID: Bool, translocated: Bool, readOnly: Bool
  ) {
    self.bundleID = bundleID
    self.teamID = teamID
    self.developerID = developerID
    self.translocated = translocated
    self.readOnly = readOnly
  }
  public var eligible: Bool {
    bundleID == UpdatePolicy.bundleID && teamID == UpdatePolicy.teamID && developerID
      && !translocated && !readOnly
  }
}

public struct UpdatePreferences: Equatable, Sendable {
  public var automaticallyCheck = true
  public var automaticallyDownload = true
  public var lastCheck: Date?
  public var retryAfter: Date?
  public init() {}
  public init(defaults: UserDefaults) {
    func flag(_ key: String) -> Bool {
      guard let value = defaults.object(forKey: key) else { return true }
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return false
      }
      return number.boolValue
    }
    automaticallyCheck = flag("updates.automaticallyCheck")
    automaticallyDownload = flag("updates.automaticallyDownload")
    lastCheck = defaults.object(forKey: "updates.lastCheck") as? Date
    retryAfter = defaults.object(forKey: "updates.retryAfter") as? Date
  }
  public func save(to defaults: UserDefaults) {
    defaults.set(automaticallyCheck, forKey: "updates.automaticallyCheck")
    defaults.set(automaticallyDownload, forKey: "updates.automaticallyDownload")
    defaults.set(lastCheck, forKey: "updates.lastCheck")
    defaults.set(retryAfter, forKey: "updates.retryAfter")
  }
  public func due(now: Date, launch: Date, delay: TimeInterval, welcomeVisible: Bool) -> Bool {
    automaticallyCheck && !welcomeVisible && now.timeIntervalSince(launch) >= delay
      && (lastCheck.map { now.timeIntervalSince($0) >= 86_400 } ?? true)
      && (retryAfter.map { now >= $0 } ?? true)
  }
}
