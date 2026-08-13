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

/// When a transition resolves open review conversations. `.ask` is the one that only offers the choice
/// when there is something to resolve.
///
/// Deliberately not `Codable`: the two `Bool`s behind it are what persist, so a settings file can never
/// carry an unknown case.
enum PRResolveThreadsMode: Hashable {
    case never
    case always
    case ask
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
    /// Marks this field required even when Jira's transition screen does not.
    ///
    /// **Not** a fallback for metadata we failed to fetch — see `requiredFieldIds`. A rule enforced
    /// by a workflow validator (a Jira Expression, ScriptRunner, JMWE) is invisible to the
    /// transition screen's `required` flag: the flag reads `false` while the transition is rejected
    /// with a message like "Testers are required before moving into QA.". Verified against a live
    /// instance — transition "Ready for QA" reports its Testers multiuserpicker as
    /// `required: false`, while a genuinely screen-required field (`resolution` on a Force Close)
    /// reports `required: true`. So this flag is the only way to express such a rule locally.
    /// Do not "simplify" it away by trusting Jira's flag.
    var userFieldRequired: Bool = false

    /// Optional free-text custom field. Empty `textFieldId` disables this section.
    var textFieldId: String = ""
    /// Label rendered above the text field.
    var textFieldLabel: String = "Notes"
    /// Renders a multi-line editor instead of a single-line text field.
    var textFieldMultiline: Bool = true
    /// Marks this field required even when Jira's transition screen does not. See `userFieldRequired`.
    var textFieldRequired: Bool = false

    /// Optional select-dropdown field. Empty `selectFieldId` disables this section.
    /// Works for system fields like `resolution` and custom select fields. Sent as `{fieldId: {id: value}}`.
    var selectFieldId: String = ""
    /// Label rendered above the picker.
    var selectFieldLabel: String = "Select…"
    /// Options the user can choose from. Each option's `value` is what the API receives.
    var selectOptions: [TransitionSelectOption] = []
    /// Marks this field required even when Jira's transition screen does not. See `userFieldRequired`.
    var selectFieldRequired: Bool = false

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

    /// Backing store for `prResolveThreads == .always`. Read `prResolveThreads` instead.
    var enablePRResolveThreads: Bool = false

    /// Backing store for `prResolveThreads == .ask`. Read `prResolveThreads` instead.
    var enablePRAskResolveThreads: Bool = false

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

    /// When a transition resolves the open review conversations on its linked PRs.
    ///
    /// Over two stored flags for the same reason `prReviewAction` is: a settings file can never carry an
    /// unknown case whose decode would fail and take the whole prompt array with it. A hand-edited file
    /// can set both, and `.ask` wins — resolving only what was ticked is the harmless failure.
    var prResolveThreads: PRResolveThreadsMode {
        get {
            if enablePRAskResolveThreads { return .ask }
            return enablePRResolveThreads ? .always : .never
        }
        set {
            enablePRResolveThreads = (newValue == .always)
            enablePRAskResolveThreads = (newValue == .ask)
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
        prReviewAction != .none || allowsPRMerge || enablePRAssigneeSync || prResolveThreads != .never
    }

    /// True when this prompt has at least one field that could be required. A comment-only prompt has
    /// nothing to gate, so unknown requiredness must not block it.
    ///
    /// Uses id-only for the select field, matching `missingRequirements` rather than `hasSelectField`
    /// — a configured-but-optionless select can still be required, and that is precisely the case
    /// that needs saying out loud, so it must not skip the metadata read.
    var hasGatableField: Bool {
        hasUserField || hasTextField || !selectFieldId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether `fieldId` must be filled, from either source: Jira's own transition-screen flag, or
    /// this config's manual override. OR, not fallback — the two express different things and
    /// neither subsumes the other.
    /// Trimmed before comparing, matching `fieldUpdates` — these ids are typed or pasted by hand, and
    /// a stored trailing space would otherwise render the field while never matching Jira's flag for
    /// it. Case is deliberately *not* folded: `resolution` and `Resolution` are different fields to
    /// Jira, so lowercasing would invent matches.
    func fieldIsRequired(_ fieldId: String, manualFlag: Bool, jiraRequiredFieldIds: Set<String>) -> Bool {
        manualFlag || jiraRequiredFieldIds.contains(fieldId.trimmingCharacters(in: .whitespaces))
    }

    /// Every required field that is still empty, phrased for the user. **All** of them, so fixing
    /// one doesn't reveal the next.
    ///
    /// `selectedUserCount` rather than a bool: "at least one tester" is a count. A multiuserpicker
    /// with an empty array satisfies presence and fails the rule, which is the whole point.
    func missingRequirements(
        selectedUserCount: Int,
        textValue: String,
        selectValue: String,
        jiraRequiredFieldIds: Set<String>
    ) -> [String] {
        var missing: [String] = []
        if hasUserField,
           fieldIsRequired(userFieldId, manualFlag: userFieldRequired, jiraRequiredFieldIds: jiraRequiredFieldIds),
           selectedUserCount < 1 {
            // Not "at least one \(label.lowercased())": these labels are plural by nature
            // ("Reviewers", "Testers", the default "Users"), and singularizing them reads wrong.
            missing.append("\(userFieldLabel) is required — select at least one.")
        }
        if hasTextField,
           fieldIsRequired(textFieldId, manualFlag: textFieldRequired, jiraRequiredFieldIds: jiraRequiredFieldIds),
           textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("Fill in \(textFieldLabel) — it is required.")
        }
        let selectConfigured = !selectFieldId.trimmingCharacters(in: .whitespaces).isEmpty
        let selectIsRequired = selectConfigured
            && fieldIsRequired(selectFieldId, manualFlag: selectFieldRequired, jiraRequiredFieldIds: jiraRequiredFieldIds)
        if selectIsRequired {
            if !hasSelectField {
                // Configured but optionless, so the dialog renders no picker and there is nothing
                // here to satisfy it with. Blocking with a pointer beats submitting into a refusal.
                missing.append("\(selectFieldLabel) is required but has no options configured — add them in Preferences, or set the field in Jira first.")
            } else if selectValue.trimmingCharacters(in: .whitespaces).isEmpty {
                missing.append("Choose a \(selectFieldLabel) — it is required.")
            }
        }
        return missing
    }

    /// A warning for Preferences when this prompt's `transitionName` looks like a near-miss for a
    /// transition JiraBar has actually seen — or nil, which is the usual answer.
    ///
    /// `matches` is plain string equality, so a name that is close but wrong opens no dialog and
    /// reports nothing. The easiest way to get there is to type the *status* the transition moves to,
    /// which is what Jira shows on the ticket: the transition is "Reopen", the status is "Reopened".
    ///
    /// **This deliberately says nothing when it merely fails to recognise a name.** `seenNames` is not
    /// the workflow's transition list and cannot be: Jira's per-issue transitions endpoint returns only
    /// what is reachable from each issue's *current* status, over however many issues the user's JQL
    /// returns. A correctly-spelled prompt for a transition out of a status none of the current tickets
    /// sit in would therefore be unrecognised forever — and "Reopen" is exactly that shape, since it is
    /// reached from a closed status a working JQL usually excludes. Warning on absence of evidence would
    /// tell users their correct configuration is wrong, and keep doing it after they fixed it.
    ///
    /// So a warning requires *positive* evidence: a seen name that the configured name extends. That is
    /// the status-for-transition mistake and little else.
    func unknownTransitionNameWarning(seenNames: [String]) -> String? {
        let configured = transitionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return nil }

        let needle = configured.lowercased()
        let seen = seenNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { (original: $0, folded: $0.lowercased()) }

        guard !seen.contains(where: { $0.folded == needle }) else { return nil }

        // Only this direction: a seen name that the configured name extends ("Reopen" → "Reopened").
        // The reverse — configured being a prefix of a seen name — fires on every half-typed name and
        // turns a correct "Close" into "did you mean Close Sprint?", so it is not evidence of anything.
        // Closest by length, because the stored list is sorted and `first` would otherwise pick
        // alphabetically among several relatives.
        let suggestion = seen
            .filter { needle.hasPrefix($0.folded) }
            .min { ($0.folded.count, $0.original) > ($1.folded.count, $1.original) }?
            .original
        guard let suggestion else { return nil }

        return "No transition named \"\(configured)\" has been seen on your tickets — did you mean "
            + "\"\(suggestion)\"? This must be the transition's name, not the status it moves to."
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
        case userFieldRequired, textFieldRequired, selectFieldRequired
        case enablePRApprove, enablePRRequestChanges, enablePRMerge, prMergeMethod, enablePRAssigneeSync
        case enablePRResolveThreads, enablePRAskResolveThreads
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
        self.userFieldRequired = try c.decodeIfPresent(Bool.self, forKey: .userFieldRequired) ?? false
        self.textFieldRequired = try c.decodeIfPresent(Bool.self, forKey: .textFieldRequired) ?? false
        self.selectFieldRequired = try c.decodeIfPresent(Bool.self, forKey: .selectFieldRequired) ?? false
        self.enablePRApprove = try c.decodeIfPresent(Bool.self, forKey: .enablePRApprove) ?? false
        self.enablePRRequestChanges = try c.decodeIfPresent(Bool.self, forKey: .enablePRRequestChanges) ?? false
        self.enablePRMerge = try c.decodeIfPresent(Bool.self, forKey: .enablePRMerge) ?? false
        self.prMergeMethod = try c.decodeIfPresent(String.self, forKey: .prMergeMethod) ?? "rebase"
        self.enablePRAssigneeSync = try c.decodeIfPresent(Bool.self, forKey: .enablePRAssigneeSync) ?? false
        self.enablePRResolveThreads = try c.decodeIfPresent(Bool.self, forKey: .enablePRResolveThreads) ?? false
        self.enablePRAskResolveThreads = try c.decodeIfPresent(Bool.self, forKey: .enablePRAskResolveThreads) ?? false
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
