import Foundation

/// Pure lexical resolution: no filesystem access, symlink/case normalization or attribution guesses.
public enum ExecutableBundle {
  public struct Bundle: Equatable { public var path: String, name: String }
  public static func bundle(for path: String) -> Bundle? {
    guard path.utf8.count < 4096, path.hasPrefix("/"), !path.hasSuffix("/"),
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
      return nil
    }
    for i in 1..<max(1, parts.count - 2) {
      let part = parts[i]
      if part.hasSuffix(".app"), part.count > 4, parts[i + 1] == "Contents" {
        return Bundle(path: parts[0...i].joined(separator: "/"), name: String(part.dropLast(4)))
      }
    }
    return nil
  }
}
