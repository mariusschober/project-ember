import Foundation

/// Single source of version truth for 0.5.0.
///
/// The marketing and build numbers are written down **only** here. The build
/// scripts parse this file through `scripts/version.sh`, stamp the assembled
/// `Info.plist` from it, and CI fails if `Resources/Info.plist` or a shipped
/// bundle disagrees (`scripts/version.sh --check`). Never duplicate these
/// strings in a script, a plist, or a workflow: bump the version here, rebuild,
/// and the artifact follows.
public enum AppVersion {
  public static let marketing = "0.5.0"
  public static let build = "5"
  public static let schemaVersion = 2
  /// Highest recovery schema this build understands. Future versions reject.
  public static let maxSupportedSchemaVersion = 2

  public static var displayString: String { "v\(marketing)" }
}
