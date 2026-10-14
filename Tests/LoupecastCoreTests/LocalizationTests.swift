import Foundation
import XCTest

/// Every UI string in the sources has its Korean line: a missing key shows English to Korean users.
final class LocalizationTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Calls whose first string literal is looked up in Localizable.strings (SwiftUI's LocalizedStringKey,
    /// String.LocalizationValue, and this app's helpers that take one).
    static let calls = try! NSRegularExpression(pattern: #"(String\(localized:\s*|LoupecastError\(|\bText\(|\bButton\(|\bToggle\(|\bPicker\(|\bMenu\(|\bLabel\(|\bTextField\(|\bLink\(|\.help\(|\.accessibilityLabel\(|\.accessibilityValue\(|\bedit\(|\bendDrag\(|\bhint\(|\brow\(|\btitle:\s*|\bdetail:\s*)""#)

    func testEveryUIStringHasAKoreanLine() throws {
        let strings = try String(contentsOf: Self.root.appendingPathComponent("Resources/ko.lproj/Localizable.strings"), encoding: .utf8)
        let korean = Set(strings.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("\""), let end = line.range(of: "\" = ") else { return nil }
            return String(line[line.index(after: line.startIndex)..<end.lowerBound])
        })
        var missing: [String] = []
        let sources = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        for case let url as URL in sources where url.pathExtension == "swift" && url.lastPathComponent != "Debug.swift" {
            for key in Self.keys(in: try String(contentsOf: url, encoding: .utf8)) where !korean.contains(key) {
                missing.append("\(url.lastPathComponent): \(key)")
            }
        }
        XCTAssertEqual(missing, [], "add these keys to Resources/ko.lproj/Localizable.strings")
    }

    /// The lookup keys in `source`: `\(…)` becomes %lld for an integer (`Int(…)`, `.count`, `.version`), %@ otherwise.
    /// Text concatenations (`Text("\(Text(…))…")`) and strings without letters are skipped.
    static func keys(in source: String) -> [String] {
        let s = Array(source.unicodeScalars), ns = source as NSString
        var out: [String] = []
        for m in calls.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            // NSRange counts UTF-16 units; map the opening quote to a scalar index
            let quote = ns.substring(to: m.range.location + m.range.length - 1).unicodeScalars.count
            guard let (text, parts, _) = literal(s, quote), !parts.contains(where: { $0.contains("Text(") }) else { continue }
            var key = text
            for p in parts {
                let p = p.trimmingCharacters(in: .whitespaces)
                let spec = p.hasPrefix("Int(") || p.hasSuffix(".count") || p.hasSuffix(".version") ? "%lld" : "%@"
                key = key.replacingOccurrences(of: "\u{0}", with: spec, options: [], range: key.range(of: "\u{0}"))
            }
            if key.replacingOccurrences(of: "%lld", with: "").replacingOccurrences(of: "%@", with: "").contains(where: \.isLetter) { out.append(key) }
        }
        return out
    }

    /// The string literal opening at `s[i]` with each interpolation as U+0000, the interpolated expressions, and the
    /// index after its closing quote. Interpolations may hold string literals of their own.
    static func literal(_ s: [Unicode.Scalar], _ i: Int) -> (String, [String], Int)? {
        var j = i + 1, text = "", parts: [String] = []
        while j < s.count {
            if s[j] == "\\", j + 1 < s.count, s[j + 1] == "(" {
                var depth = 1, k = j + 2
                let start = k
                while depth > 0, k < s.count {
                    if s[k] == "\"" { guard let (_, _, next) = literal(s, k) else { return nil }; k = next; continue }
                    if s[k] == "(" { depth += 1 } else if s[k] == ")" { depth -= 1 }
                    k += 1
                }
                parts.append(String(String.UnicodeScalarView(s[start..<(k - 1)])))
                text += "\u{0}"
                j = k
            } else if s[j] == "\\", j + 1 < s.count {
                text.unicodeScalars.append(contentsOf: s[j...(j + 1)]); j += 2
            } else if s[j] == "\"" {
                return (text, parts, j + 1)
            } else {
                text.unicodeScalars.append(s[j]); j += 1
            }
        }
        return nil
    }

    func testKeyExtraction() {
        let src = #"""
        Text("Cut \(timecode(removed))").help(String(localized: "Plays at \(Int(speed))× speed"))
        Text("\(Text(timecode(a)))\(Text(" / \(timecode(b))"))"); Text("\(Int(p * 100))%"); Text(verbatim: "x")
        Picker("Size", selection: x) { Text(name) }
        """#
        XCTAssertEqual(Self.keys(in: src), ["Cut %@", "Plays at %lld× speed", "Size"])
    }
}
