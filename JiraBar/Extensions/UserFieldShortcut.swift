import Foundation
import Defaults

/// One "Change <user field>" entry that appears in the per-issue submenu under Add Comment.
/// Generic by design — user supplies the field id (e.g. `assignee` or `customfield_10100`)
/// and the label they want to see.
struct UserFieldShortcut: Codable, Defaults.Serializable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Menu label, e.g. "Change Assignee" or "Change Reviewer".
    var label: String = ""
    /// Jira field id (system or custom), e.g. `assignee` or `customfield_10100`.
    var fieldId: String = ""
    /// `true` posts the field as a JSON array; `false` as a single object (or null when empty).
    var allowsMultiple: Bool = false
    /// Optional: name of a status whose color (from Status Order & Colors) tints this
    /// shortcut's assigned-user lines regardless of the ticket's actual status. Handy for
    /// "role"-style fields — e.g. show Reviewer users in the Review status color on every
    /// ticket, so a glance identifies which lane they belong to. Empty = fall back to the
    /// ticket's own status color.
    var colorFromStatus: String = ""

    init() {}

    init(label: String, fieldId: String, allowsMultiple: Bool, colorFromStatus: String = "") {
        self.label = label
        self.fieldId = fieldId
        self.allowsMultiple = allowsMultiple
        self.colorFromStatus = colorFromStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, label, fieldId, allowsMultiple, colorFromStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.fieldId = try c.decodeIfPresent(String.self, forKey: .fieldId) ?? ""
        self.allowsMultiple = try c.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
        self.colorFromStatus = try c.decodeIfPresent(String.self, forKey: .colorFromStatus) ?? ""
    }
}

extension Defaults.Keys {
    /// User-defined menu shortcuts for editing user-picker fields on the active issue.
    static let userFieldShortcuts = Key<[UserFieldShortcut]>("userFieldShortcuts", default: [])
}
