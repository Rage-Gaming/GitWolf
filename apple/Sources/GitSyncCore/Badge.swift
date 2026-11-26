import Foundation

/// Text for an app-icon badge showing how many files have uncommitted changes.
public enum BadgeLabel {
    /// `nil` (no badge) for zero, the number up to 99, then "99+".
    public static func text(forChanges count: Int) -> String? {
        if count <= 0 { return nil }
        return count > 99 ? "99+" : String(count)
    }
}
