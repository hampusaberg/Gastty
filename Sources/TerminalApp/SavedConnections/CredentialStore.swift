import Foundation
import Security

/// A reusable set of SSH auth details: username and optional identity file.
/// The SSH password (if any) is kept in the macOS Keychain — never in JSON.
struct SavedCredential: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var user: String
    var identityFile: String?
}

/// Process-wide store for saved credentials.
///
/// Non-sensitive fields (`name`, `user`, `identityFile`) are persisted as
/// JSON alongside the connections file. Passwords live in Keychain under
/// `kSecClassGenericPassword` with the bundle ID as the service name and
/// `credential:<uuid>` as the account key.
final class CredentialStore {
    static let shared = CredentialStore()
    static let changedNotification = Notification.Name("TerminalCredentialsDidChange")

    private(set) var credentials: [SavedCredential] = []

    private static let keychainService =
        Bundle.main.bundleIdentifier ?? "com.hampusaberg.Gastty"

    private init() { load() }

    // MARK: - CRUD

    func add(_ credential: SavedCredential) {
        credentials.append(credential)
        save()
        notify()
    }

    func update(_ credential: SavedCredential) {
        guard let idx = credentials.firstIndex(where: { $0.id == credential.id }) else { return }
        credentials[idx] = credential
        save()
        notify()
    }

    func remove(_ credential: SavedCredential) {
        deletePassword(for: credential.id)
        credentials.removeAll { $0.id == credential.id }
        save()
        notify()
    }

    func credential(id: UUID) -> SavedCredential? {
        credentials.first { $0.id == id }
    }

    // MARK: - Keychain

    private static func account(for id: UUID) -> String { "credential:\(id.uuidString)" }

    func setPassword(_ password: String, for id: UUID) {
        guard !password.isEmpty else { deletePassword(for: id); return }
        let data = Data(password.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.account(for: id),
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func password(for id: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.account(for: id),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword(for id: UUID) -> Bool { password(for: id) != nil }

    func deletePassword(for id: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.account(for: id),
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Persistence

    private struct File: Codable {
        var version: Int
        var credentials: [SavedCredential]
    }

    private func fileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hampusaberg.Gastty"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }

    private func load() {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        credentials = file.credentials
    }

    private func save() {
        guard let url = fileURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(File(version: 1, credentials: credentials)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    // MARK: - SSH_ASKPASS password injection

    /// Wraps `command` with `SSH_ASKPASS` infrastructure if any of the
    /// credentials involved in the connection have a stored password.
    ///
    /// OpenSSH 8.4+ honours `SSH_ASKPASS_REQUIRE=force` even inside a PTY,
    /// so SSH calls our tiny shell script instead of prompting the user.
    /// The script maps the prompt string (e.g. `(user@host) Password:`) to
    /// the right password from Keychain.
    ///
    /// A UUID-named script is written to the user's temp directory with mode
    /// 700 and scheduled for deletion after 60 seconds — long enough for
    /// interactive auth to complete.
    static func applyPasswordInjection(to command: String,
                                       connection: SavedConnection) -> String {
        var passwordMap: [(host: String, password: String)] = []

        // Jump host — prefer the saved jumphost connection's own credential;
        // fall back to assuming the same credential as the target.
        if let jcID = connection.jumphostConnectionID,
           let jc = ConnectionStore.shared.allConnections.first(where: { $0.id == jcID }),
           let jCredID = jc.credentialID,
           let pwd = shared.password(for: jCredID) {
            passwordMap.append((host: jc.host, password: pwd))
        } else if let jh = connection.jumpHost, !jh.isEmpty,
                  let credID = connection.credentialID,
                  let pwd = shared.password(for: credID) {
            passwordMap.append((host: jh, password: pwd))
        }

        // Target host
        if let credID = connection.credentialID,
           let pwd = shared.password(for: credID) {
            passwordMap.append((host: connection.host, password: pwd))
        }

        guard !passwordMap.isEmpty else { return command }

        return wrapWithAskpass(command, passwordMap: passwordMap)
    }

    private static func wrapWithAskpass(_ command: String,
                                        passwordMap: [(host: String, password: String)]) -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("gastty-askpass-\(UUID().uuidString).sh")

        // Build a shell case statement: match the prompt string SSH passes as $1.
        // The prompt format is `(user@host) Password:` so we match on the host.
        var script = "#!/bin/sh\ncase \"$1\" in\n"
        for (host, pwd) in passwordMap {
            script += "  *\"\(host)\"*) printf '%s\\n' \(shellQuote(pwd)) ;;\n"
        }
        // Fallback — covers the target host if its prompt didn't match above.
        if let (_, fallback) = passwordMap.last {
            script += "  *) printf '%s\\n' \(shellQuote(fallback)) ;;\n"
        }
        script += "esac\n"

        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: path)

        // Schedule cleanup — long enough to survive slow auth roundtrips.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            try? FileManager.default.removeItem(atPath: path)
        }

        return "env SSH_ASKPASS=\(shellQuote(path)) SSH_ASKPASS_REQUIRE=force \(command)"
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
