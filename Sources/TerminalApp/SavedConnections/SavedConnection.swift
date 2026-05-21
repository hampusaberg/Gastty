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
    /// Legacy field, still decoded from old per-workspace v2 files so
    /// migration can read it. New code stores folder placement in
    /// per-workspace `WorkspaceConnectionRef.folderID` instead — the
    /// same connection can live in different folders in different
    /// workspaces. Always `nil` on freshly written records.
    var folderID: UUID?

    /// Optional SSH ProxyJump (`-J`) configuration — when set, ssh hops
    /// through this bastion to reach the target. Only `jumpHost` is used as
    /// the "is this enabled" signal; `jumpUser` should be present too when
    /// `jumpHost` is, and `jumpPort` defaults to 22 when nil.
    var jumpHost: String?
    var jumpUser: String?
    var jumpPort: Int?

    /// What we show in the Quick Connect palette and tab title.
    var displayName: String {
        name.isEmpty ? "\(user)@\(host)" : name
    }

    /// Argv-style command to spawn this session. Built so libghostty's PTY
    /// runs `ssh` directly without going through a login shell.
    ///
    /// The leading `env` is load-bearing: libghostty wraps our command as
    /// `/bin/bash -c "exec -l <cmd>"`, and bash's `exec -l` prepends a `-`
    /// to argv[0]. OpenSSH then reuses argv[0] verbatim when building the
    /// implicit ProxyCommand for `-J` — so a `-ssh` argv[0] becomes a
    /// `-ssh -l ...` ProxyCommand that `/bin/sh` parses as flag-bundle
    /// `-s -s -h`, blowing up with "unknown exec flag -s" and killing the
    /// jumphost tunnel. Prefixing with `env` puts argv[0] back to `ssh`.
    var sshCommand: String {
        var parts: [String] = ["env", "ssh"]
        if port != 22 { parts += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty {
            parts += ["-i", expandedIdentity(identityFile)]
        }
        // ProxyJump (`-J`) — OpenSSH 7.3+ syntax. Port is encoded inside
        // the spec (`user@host:port`) so it doesn't conflict with `-p`,
        // which targets the final host.
        if let jumpHost, !jumpHost.isEmpty,
           let jumpUser, !jumpUser.isEmpty {
            var spec = "\(jumpUser)@\(jumpHost)"
            if let jumpPort, jumpPort != 22 {
                spec += ":\(jumpPort)"
            }
            parts += ["-J", spec]
        }
        parts.append("\(user)@\(host)")
        return parts.joined(separator: " ")
    }

    private func expandedIdentity(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

/// A named grouping that connections can opt into. Order within
/// `ConnectionStore.folders` defines the order folders appear in.
struct ConnectionFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
}

/// Per-workspace placement record for one connection. A connection that
/// appears in multiple workspaces has one `WorkspaceConnectionRef` per
/// workspace, each with its own `folderID` so folder organisation can
/// differ across workspaces. The order of refs within a workspace's
/// `connections.json` defines display order for that workspace.
struct WorkspaceConnectionRef: Codable, Hashable {
    var connectionID: UUID
    var folderID: UUID?
}
