import AppKit
import Foundation

/// Reads ghostty's bundled theme files (`Resources/ghostty/themes/`)
/// — 512 of them as of writing — and parses out the colors needed to
/// draw a preview swatch (background, foreground, cursor, plus
/// `palette = 4` as an accent stand-in).
///
/// Parsing is lazy and cached: the first `colors(for:)` call for a given
/// theme reads the file and stores the result; subsequent calls reuse
/// the in-memory copy. Enumeration is eager but cheap (one directory
/// listing) so the browser can present the list immediately.
enum ThemeRepository {

    struct Colors {
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor?
        /// Pulled from `palette = 4` (the "blue" slot in the standard
        /// 16-colour palette). Used purely for preview swatches —
        /// gives every theme a visual accent without making us pick a
        /// favourite among the eight palette colours.
        let accent: NSColor?

        static let fallback = Colors(background: .black,
                                     foreground: .white,
                                     cursor: nil,
                                     accent: nil)
    }

    /// All theme names available in the bundle, sorted case-insensitive.
    /// Empty if the bundle is missing the themes folder (shouldn't
    /// happen in shipped builds).
    static func allThemes() -> [String] {
        guard let dir = themesDirectoryPath else { return [] }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func colors(for theme: String) -> Colors {
        if let cached = cache[theme] { return cached }
        guard let dir = themesDirectoryPath else { return .fallback }
        let path = (dir as NSString).appendingPathComponent(theme)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            cache[theme] = .fallback
            return .fallback
        }

        var bg: NSColor?
        var fg: NSColor?
        var cursor: NSColor?
        var accent: NSColor?

        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "background":
                bg = parseHex(value)
            case "foreground":
                fg = parseHex(value)
            case "cursor-color":
                cursor = parseHex(value)
            case "palette":
                // Format: `palette = 4=#7aa2f7`. We only care about slot 4.
                if let split = value.firstIndex(of: "="),
                   value[..<split].trimmingCharacters(in: .whitespaces) == "4" {
                    let colorPart = value[value.index(after: split)...]
                        .trimmingCharacters(in: .whitespaces)
                    accent = parseHex(colorPart)
                }
            default:
                break
            }
        }

        let result = Colors(
            background: bg ?? .black,
            foreground: fg ?? .white,
            cursor: cursor,
            accent: accent
        )
        cache[theme] = result
        return result
    }

    // MARK: - Internal

    private static var cache: [String: Colors] = [:]

    private static let themesDirectoryPath: String? = {
        guard let resPath = Bundle.main.resourcePath else { return nil }
        return (resPath as NSString).appendingPathComponent("ghostty/themes")
    }()

    private static func parseHex(_ raw: String) -> NSColor? {
        var hex = raw
        if hex.hasPrefix("#") { hex.removeFirst() }
        // Some theme files use `0x` prefix.
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
