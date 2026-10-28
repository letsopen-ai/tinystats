import Foundation
import Security

public enum TrafficServiceSigning {
  public static let appIdentifier = "com.niechen.tinystats"
  public static let serviceIdentifier = "com.niechen.tinystats.traffic-service"
  public static func requirement(identifier: String, team: String) -> String? {
    guard [appIdentifier, serviceIdentifier].contains(identifier), team.utf8.count == 10,
      team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) })
    else { return nil }
    let text =
      "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\" and !(entitlement [\"com.apple.security.get-task-allow\"] exists)"
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
      return nil
    }
    return text
  }
  /// Team identity comes from a validated signature, never a client argument, path or plist.
  /// Hosting requires a hardened runtime signature. Peer requirements pin the signed app
  /// and reject debug-task access; release validation must also check client runtime flags.
  public static func currentTeam(identifier: String) -> String? {
    var own: SecCode?
    var fixed: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
      SecCodeCopyStaticCode(own, [], &fixed) == errSecSuccess, let fixed,
      SecCodeCopySigningInformation(
        fixed, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let info = information as? [String: Any],
      let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
      let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
      flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0,
      flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0,
      let text = requirement(identifier: identifier, team: team)
    else { return nil }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      SecCodeCheckValidity(own, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        == errSecSuccess
    else { return nil }
    return team
  }
}
