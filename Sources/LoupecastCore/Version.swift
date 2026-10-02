import Foundation

public enum Version {
    /// "v0.10.0" vs "0.9.1": numeric per component, an optional leading "v" ignored.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        String(a.trimmingPrefix("v")).compare(String(b.trimmingPrefix("v")), options: .numeric) == .orderedDescending
    }
}
