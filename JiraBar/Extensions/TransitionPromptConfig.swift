import Foundation
import Defaults

/// Per-transition prompt configuration. Generic by design — users define which transition names
/// open a prompt and which custom fields to expose. Nothing in this struct is specific to any
/// particular Jira workflow or instance.
struct TransitionPromptConfig: Codable, Defaults.Serializable, Identifiable, Hashable {
    var id: UUID = UUID()

    /// Transition display name to match (case-insensitive, trimmed).
    var transitionName: String = ""

    /// Show a comment box and post the value as a comment alongside the transition.
    var includeComment: Bool = true

    /// Optional user-picker custom field. Empty `userFieldId` disables this section.
    var userFieldId: String = ""
    /// Label rendered above the user picker.
    var userFieldLabel: String = "Users"
    /// `true` posts the field as a JSON array (multi-user picker); `false` posts a single object.
    var userFieldAllowsMultiple: Bool = true
    /// Pre-selects the authenticated Jira user when the dialog opens.
    /// Useful for transitions like "Start Progress" where the assignee defaults to whoever's acting.
    var userFieldDefaultsToCurrentUser: Bool = false

    /// Optional free-text custom field. Empty `textFieldId` disables this section.
    var textFieldId: String = ""
    /// Label rendered above the text field.
    var textFieldLabel: String = "Notes"
    /// Renders a multi-line editor instead of a single-line text field.
    var textFieldMultiline: Bool = true

    /// Optional select-dropdown field. Empty `selectFieldId` disables this section.
    /// Works for system fields like `resolution` and custom select fields. Sent as `{fieldId: {id: value}}`.
    var selectFieldId: String = ""
    /// Label rendered above the picker.
    var selectFieldLabel: String = "Select…"
    /// Options the user can choose from. Each option's `value` is what the API receives.
    var selectOptions: [TransitionSelectOption] = []

    func matches(transitionName incoming: String) -> Bool {
        let a = incoming.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = transitionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !b.isEmpty && a == b
    }

    var hasUserField: Bool { !userFieldId.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasTextField: Bool { !textFieldId.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasSelectField: Bool {
        !selectFieldId.trimmingCharacters(in: .whitespaces).isEmpty && !selectOptions.isEmpty
    }

    /// Tolerant of older saved values that pre-date newer fields. Missing keys fall back to defaults
    /// instead of failing decode (which would wipe the entire array via Defaults' fallback path).
    init() {}

    enum CodingKeys: String, CodingKey {
        case id, transitionName, includeComment
        case userFieldId, userFieldLabel, userFieldAllowsMultiple, userFieldDefaultsToCurrentUser
        case textFieldId, textFieldLabel, textFieldMultiline
        case selectFieldId, selectFieldLabel, selectOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.transitionName = try c.decodeIfPresent(String.self, forKey: .transitionName) ?? ""
        self.includeComment = try c.decodeIfPresent(Bool.self, forKey: .includeComment) ?? true
        self.userFieldId = try c.decodeIfPresent(String.self, forKey: .userFieldId) ?? ""
        self.userFieldLabel = try c.decodeIfPresent(String.self, forKey: .userFieldLabel) ?? "Users"
        self.userFieldAllowsMultiple = try c.decodeIfPresent(Bool.self, forKey: .userFieldAllowsMultiple) ?? true
        self.userFieldDefaultsToCurrentUser = try c.decodeIfPresent(Bool.self, forKey: .userFieldDefaultsToCurrentUser) ?? false
        self.textFieldId = try c.decodeIfPresent(String.self, forKey: .textFieldId) ?? ""
        self.textFieldLabel = try c.decodeIfPresent(String.self, forKey: .textFieldLabel) ?? "Notes"
        self.textFieldMultiline = try c.decodeIfPresent(Bool.self, forKey: .textFieldMultiline) ?? true
        self.selectFieldId = try c.decodeIfPresent(String.self, forKey: .selectFieldId) ?? ""
        self.selectFieldLabel = try c.decodeIfPresent(String.self, forKey: .selectFieldLabel) ?? "Select…"
        self.selectOptions = try c.decodeIfPresent([TransitionSelectOption].self, forKey: .selectOptions) ?? []
    }
}

/// One (label, value) entry in a `TransitionPromptConfig.selectOptions` list.
struct TransitionSelectOption: Codable, Defaults.Serializable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Displayed in the picker.
    var label: String = ""
    /// What the Jira API receives, e.g. "10000" for the Done resolution.
    var value: String = ""
}

extension Defaults.Keys {
    /// User-defined prompts keyed by transition name. Empty by default — opt-in feature.
    static let transitionPrompts = Key<[TransitionPromptConfig]>("transitionPrompts", default: [])
}
