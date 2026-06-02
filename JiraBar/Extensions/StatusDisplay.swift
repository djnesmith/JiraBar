import Foundation
import Defaults
import AppKit
import SwiftUI

/// Display config for one status group in the menu — drives both order and color.
/// Generic by design: names are user-supplied so nothing workflow-specific lives in source.
struct StatusDisplay: Codable, Defaults.Serializable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Matched case-insensitively against Jira's `status.name`.
    var name: String = ""
    /// `#RRGGBB` hex (uppercase). Empty string = no color override.
    var colorHex: String = ""

    init() {}

    init(name: String, colorHex: String = "") {
        self.name = name
        self.colorHex = colorHex
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
    }

    /// Returns an `NSColor` for the menu header, or nil if no override is configured.
    var nsColor: NSColor? {
        guard StatusDisplay.isValidHex(colorHex) else { return nil }
        return NSColor(hex: colorHex)
    }

    /// `NSColor(hex:)` in this codebase returns gray for invalid strings, so we validate before calling.
    static func isValidHex(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        return s.count == 6 && UInt32(s, radix: 16) != nil
    }
}

extension Defaults.Keys {
    /// Ordered list of status groups with optional per-status color overrides.
    /// Supersedes the legacy [String] `statusOrder` key; a one-time migration runs at launch.
    static let statusDisplay = Key<[StatusDisplay]>("statusDisplay", default: [])
}

// MARK: - Color helpers

extension NSColor {
    /// `#RRGGBB` representation in sRGB space. Empty string if the color can't be
    /// converted (alpha is ignored).
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension Color {
    init?(statusHex hex: String) {
        guard StatusDisplay.isValidHex(hex) else { return nil }
        self.init(nsColor: NSColor(hex: hex))
    }

    /// Round-trips a SwiftUI Color through NSColor to produce a `#RRGGBB` string.
    var statusHex: String { NSColor(self).hexString }
}
