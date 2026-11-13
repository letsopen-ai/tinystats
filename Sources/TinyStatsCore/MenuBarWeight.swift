/// One shared weight for menu-bar text, symbols and graphic strokes.
public enum MenuBarWeight: String, Codable, CaseIterable, Sendable {
  case regular, medium, semibold

  public var title: String {
    switch self {
    case .regular: "Regular"
    case .medium: "Medium"
    case .semibold: "Semibold"
    }
  }
}
