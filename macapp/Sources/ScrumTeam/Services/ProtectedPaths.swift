import Foundation

/// Framework sources the user should not edit casually. The file tree hides
/// edit affordances for these unless Advanced mode is unlocked.
///
/// These are the top-level dirs/files deployed into a target project plus the
/// framework's own source trees, matched relative to the project root.
enum ProtectedPaths {
    /// Path prefixes (relative to project root) considered framework-owned.
    static let prefixes: [String] = [
        ".claude/agents",
        ".claude/skills",
        ".claude/hooks",
        ".claude/rules",
        // Entire runtime-state tree: SSOT JSON + wrapper scripts. Users must
        // not hand-edit .scrum/ (writes go through .scrum/scripts/*.sh wrappers,
        // enforced by hooks); the agents still edit it freely on the filesystem.
        ".scrum",
        // Framework-repo layout (when the opened project IS the framework):
        "agents",
        "skills",
        "rules",
        "hooks",
        "scripts",
        "dashboard",
    ]

    /// True if `relativePath` (POSIX, project-root-relative, no leading "./")
    /// falls under a protected tree.
    static func isProtected(_ relativePath: String) -> Bool {
        let p = relativePath.hasPrefix("./") ? String(relativePath.dropFirst(2)) : relativePath
        return prefixes.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
}
