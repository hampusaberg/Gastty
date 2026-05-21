import Foundation

/// One workspace — its own connection list, its own open tabs.
/// Identified by a stable UUID so renames / icon changes don't break
/// per-workspace storage paths.
struct Workspace: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// SF Symbol name (e.g. `"house.fill"`). Stored as a string so the
    /// list of available icons can evolve without breaking persistence.
    var iconSymbol: String
}

/// The curated set of icons the "new / edit workspace" picker offers.
/// All SF Symbols — Apple ships these, no licensing required, scalable
/// and tintable. The list is deliberately short so the picker fits in
/// a clean grid; users who need something exotic can edit
/// `workspaces.json` directly.
enum WorkspaceIconCatalog {

    /// Default icon for the bootstrap "Default" workspace.
    static let defaultIcon = "house.fill"

    /// All choosable icons, in the order they appear in the picker grid.
    /// Grouped loosely (personal / work / dev / generic) but rendered
    /// as one flat 6×4 grid.
    static let all: [String] = [
        // Personal & lifestyle
        "house.fill",
        "person.fill",
        "heart.fill",
        "gamecontroller.fill",
        "book.fill",
        "music.note",

        // Work
        "briefcase.fill",
        "building.2.fill",
        "chart.bar.fill",
        "pencil.tip",
        "envelope.fill",
        "doc.text.fill",

        // Tech / dev
        "terminal.fill",
        "server.rack",
        "cloud.fill",
        "network",
        "bolt.fill",
        "wrench.and.screwdriver.fill",

        // Generic markers
        "star.fill",
        "flag.fill",
        "key.fill",
        "lock.fill",
        "shield.fill",
        "globe",
    ]
}
