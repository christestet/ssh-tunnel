import Foundation

/// A minimal Semantic Versioning value type for comparing the running app
/// version against the latest GitHub release tag.
///
/// Parsing is deliberately lenient about the things release tags vary on — a
/// leading `v`/`V` (e.g. `v2.2.4`) and any pre-release/build metadata suffix
/// (`-beta.1`, `+build.7`) are tolerated — while still requiring a
/// `MAJOR.MINOR.PATCH` numeric core. Comparison ignores the suffix and orders
/// purely on the numeric triple, which is all the update check needs.
struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `"2.2.4"`, `"v2.2.4"`, or `"2.2.4-beta.1"`. Returns `nil` for
    /// anything without a valid `MAJOR.MINOR.PATCH` core.
    init?(_ raw: String?) {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        if let first = trimmed.first, first == "v" || first == "V" {
            trimmed.removeFirst()
        }

        // Drop any pre-release (`-…`) or build-metadata (`+…`) suffix; we only
        // order on the numeric core.
        let core = trimmed.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }

        self.init(major: major, minor: minor, patch: patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
