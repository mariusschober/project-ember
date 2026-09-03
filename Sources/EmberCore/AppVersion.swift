import Foundation

/// Single source of version truth for 0.4.0.
/// All artifact names, Info.plist values, and fallback UI derive from here.
public enum AppVersion {
  public static let marketing = "0.4.0"
  public static let build = "4"
  public static let schemaVersion = 2
  /// Highest recovery schema this build understands. Future versions reject.
  public static let maxSupportedSchemaVersion = 2

  public static var displayString: String { "v\(marketing)" }
}
