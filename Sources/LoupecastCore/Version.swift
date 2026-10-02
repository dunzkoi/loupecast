import Foundation

public enum Version {
    /// "v0.10.0" vs "0.9.1": numeric per component, an optional leading "v" ignored.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func strip(_ s: String) -> String { s.hasPrefix("v") ? String(s.dropFirst()) : s }
        return strip(a).compare(strip(b), options: .numeric) == .orderedDescending
    }
}
