import Foundation

/// A user-saved connection (an SSH target plus a friendly name).
struct SavedConnection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var user: String
    var port: Int = 22
    /// Path to an SSH private key, e.g. `~/.ssh/id_ed25519`. Optional.
    var identityFile: String?

    /// What we show in the Quick Connect palette and tab title.
    var displayName: String {
        name.isEmpty ? "\(user)@\(host)" : name
    }

    /// Argv-style command to spawn this session. Built so libghostty's PTY
    /// runs `ssh` directly without going through a login shell.
    var sshCommand: String {
        var parts: [String] = ["ssh"]
        if port != 22 { parts += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty {
            parts += ["-i", expandedIdentity(identityFile)]
        }
        parts.append("\(user)@\(host)")
        return parts.joined(separator: " ")
    }

    private func expandedIdentity(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
