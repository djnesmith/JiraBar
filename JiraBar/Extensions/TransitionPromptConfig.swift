import Foundation
import Defaults

/// Which review a transition submits on each linked open PR. One choice, so approving and
/// requesting changes can't both be asked for.
///
/// Deliberately not `Codable`: the two `Bool`s below are what persist, so a settings file can
/// never carry an unknown case whose decode would fail and take the whole prompt array with it.
enum PRReviewAction: Hashable {
    case none
    case approve
    case requestChanges

    /// `event` value for the GitHub reviews API; nil when no review is submitted.
    var githubEvent: String? {
        switch self {
        case .none:           return nil
        case .approve:        return "APPROVE"
        case .requestChanges: return "REQUEST_CHANGES"
        }
    }

    /// Whether the review can't be submitted without a comment. GitHub's reviews API documents
    /// `body` as "Required when using REQUEST_CHANGES or COMMENT for the event parameter" —
    /// APPROVE is the one that accepts a bodyless review.
    var requiresComment: Bool { self == .requestChanges }
}

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

    /// Backing store for `prReviewAction == .approve`. Read `prReviewAction` instead — the
    /// Preferences picker can't set this and `enablePRRequestChanges` together, but a hand-edited
    /// settings file can, and the getter is what resolves that pair.
    var enablePRApprove: Bool = false

    /// Backing store for `prReviewAction == .requestChanges`. Read `prReviewAction` instead.
    var enablePRRequestChanges: Bool = false

    /// When true, the dialog exposes a "Merge linked PRs" checkbox (default on) and a merge
    /// method picker (see `prMergeMethod`). PRs whose repos disallow the chosen method are
    /// skipped with a summary notification. Requires a GitHub token.
    var enablePRMerge: Bool = false

    /// Default merge method for the picker: "merge", "squash", or "rebase". Only meaningful
    /// when `enablePRMerge` is true.
    var prMergeMethod: String = "rebase"

    /// When true, on submit JiraBar adds the ticket's Jira Assignee (mapped via the Jira →
    /// GitHub file) as the PR assignee — only when the PR has no assignee yet.
    var enablePRAssigneeSync: Bool = false

    /// The review this transition submits, over the two stored flags. The setter writes them
    /// exclusively, so the Preferences picker can't produce a contradictory pair.
    ///
    /// Settings edited by hand still can, and there the getter resolves to `.requestChanges`:
    /// wrongly approving someone's PR is a wrong review, while an unintended request for changes
    /// can be dismissed.
    var prReviewAction: PRReviewAction {
        get {
            if enablePRRequestChanges { return .requestChanges }
            return enablePRApprove ? .approve : .none
        }
        set {
            enablePRApprove = (newValue == .approve)
            enablePRRequestChanges = (newValue == .requestChanges)
        }
    }

    /// Merging a PR you just asked for changes on is nonsense, so request-changes mode withdraws
    /// the merge action outright. Computed rather than validated on save so it holds for every
    /// input path, including a hand-edited settings file.
    var allowsPRMerge: Bool {
        enablePRMerge && prReviewAction != .requestChanges
    }

    /// True when this transition has any PR action to run — what gates the dialog's PR section
    /// and the status enrichment that feeds it.
    var hasPRActions: Bool {
        prReviewAction != .none || allowsPRMerge || enablePRAssigneeSync
    }

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

    /// Builds the transition field updates this config prescribes from a dialog's collected
    /// values. Shared by the single-transition and bulk-move submit paths so the empty/trim
    /// rules can't drift apart.
    func fieldUpdates(users: [JiraUser], freeText: String, selectValue: String) -> [JiraClient.TransitionFieldUpdate] {
        var updates: [JiraClient.TransitionFieldUpdate] = []
        if hasUserField, !users.isEmpty {
            updates.append(.users(
                fieldId: userFieldId.trimmingCharacters(in: .whitespaces),
                users: users,
                multi: userFieldAllowsMultiple
            ))
        }
        if hasTextField, !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updates.append(.text(
                fieldId: textFieldId.trimmingCharacters(in: .whitespaces),
                value: freeText
            ))
        }
        if hasSelectField, !selectValue.trimmingCharacters(in: .whitespaces).isEmpty {
            updates.append(.select(
                fieldId: selectFieldId.trimmingCharacters(in: .whitespaces),
                value: selectValue
            ))
        }
        return updates
    }

    /// Tolerant of older saved values that pre-date newer fields. Missing keys fall back to defaults
    /// instead of failing decode (which would wipe the entire array via Defaults' fallback path).
    init() {}

    enum CodingKeys: String, CodingKey {
        case id, transitionName, includeComment
        case userFieldId, userFieldLabel, userFieldAllowsMultiple, userFieldDefaultsToCurrentUser
        case textFieldId, textFieldLabel, textFieldMultiline
        case selectFieldId, selectFieldLabel, selectOptions
        case enablePRApprove, enablePRRequestChanges, enablePRMerge, prMergeMethod, enablePRAssigneeSync
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
        self.enablePRApprove = try c.decodeIfPresent(Bool.self, forKey: .enablePRApprove) ?? false
        self.enablePRRequestChanges = try c.decodeIfPresent(Bool.self, forKey: .enablePRRequestChanges) ?? false
        self.enablePRMerge = try c.decodeIfPresent(Bool.self, forKey: .enablePRMerge) ?? false
        self.prMergeMethod = try c.decodeIfPresent(String.self, forKey: .prMergeMethod) ?? "rebase"
        self.enablePRAssigneeSync = try c.decodeIfPresent(Bool.self, forKey: .enablePRAssigneeSync) ?? false
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
