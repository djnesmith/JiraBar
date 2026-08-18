import SwiftUI

/// Choices the user made in the PR-actions section of a transition dialog. Bundled into one
/// struct so `onSubmit` doesn't grow every time we add a knob.
struct PRActionChoices {
    var review: PRReviewAction
    var reviewComment: String
    var merge: Bool
    var mergeMethod: String
    var syncAssignee: Bool
    var resolveThreads: Bool = false
    /// Empty means `review` applies to every PR. The dialog seeds an entry per PR, so an empty map is
    /// what a caller with no PR list produces — not the everyday path.
    var reviewByPRURL: [String: PRReviewAction] = [:]

    static let disabled = PRActionChoices(
        review: .none, reviewComment: "", merge: false, mergeMethod: "rebase", syncAssignee: false
    )

    func review(forPRAt url: String) -> PRReviewAction {
        reviewByPRURL[url] ?? review
    }

    /// Whitespace-only is empty — it satisfies neither the user's intent nor GitHub's
    /// body requirement.
    var trimmedReviewComment: String {
        reviewComment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `event` to POST to the reviews API, or nil when no review should go out — including
    /// when the mode's comment is mandatory (`PRReviewAction.requiresComment`) and blank, which
    /// resolves to nil rather than to a review GitHub would reject.
    var reviewEvent: String? { reviewEvent(for: review) }

    func reviewEvent(for action: PRReviewAction) -> String? {
        guard let event = action.githubEvent else { return nil }
        if action.requiresComment, trimmedReviewComment.isEmpty { return nil }
        return event
    }

    /// A review was asked for and withheld only because its mandatory comment is blank. The
    /// summary notification has to name that, rather than report it as a failed review.
    var reviewBlockedForEmptyComment: Bool {
        guard trimmedReviewComment.isEmpty else { return false }
        return review.requiresComment || reviewByPRURL.values.contains { $0.requiresComment }
    }

    /// True when at least one PR action would be attempted.
    var hasWork: Bool {
        review != .none || merge || syncAssignee || resolveThreads
            || reviewByPRURL.values.contains { $0 != .none }
    }

}

/// How a submit attempt ended. The dialog reacts differently to each, so this is deliberately not
/// a `Bool` — "Jira refused" and "Jira applied it but GitHub didn't follow" need opposite handling:
/// the first is retryable in place, the second must not offer to transition again.
enum TransitionSubmitOutcome {
    /// Jira refused the transition, or couldn't be reached. The dialog stays open with the server's
    /// own message so the input can be fixed and retried. `fieldsWritten` distinguishes a refusal
    /// that changed nothing from one where the field values were already persisted by the PUT that
    /// precedes the transition — saying "nothing was changed" in the second case would be a lie.
    case jiraRefused(message: String, fieldsWritten: Bool)
    /// Everything asked for landed. The dialog can close.
    case applied
    /// The transition was applied but the PR-action batch never started — no token, no open linked
    /// PRs. Reported, because silently closing after being asked for a review is the disappearing
    /// window all over again, but not as a failure: nothing was attempted.
    case prActionsDidNotRun(reason: String)
    /// The Jira transition was applied, but some PR actions did not land. The ticket has moved and
    /// GitHub has not followed, so the dialog stays open naming each one; retrying the transition
    /// is not the remedy.
    case prActionsIncomplete(lines: [String])
}

/// The transition window's own framing for each `TransitionSubmitOutcome`. The detail lines it wraps
/// come from `PRActionTally.failureLines` and from Jira itself.
///
/// Outside the view because this wording is the contract: it is the only place a failure is reported
/// where the user will see it, so it has to be assertable rather than merely readable.
enum TransitionOutcomeText {
    /// `fieldsWritten` because the field values go out as a PUT *before* the transition POST, so a
    /// refusal can leave them persisted — "nothing was changed" would then be false.
    static func jiraRefused(fieldsWritten: Bool) -> String {
        fieldsWritten
            ? "Jira saved the field values but refused the transition — the status did not change."
            : "Jira refused the transition — nothing was changed."
    }

    static func prActionsIncomplete(count: Int) -> String {
        "The Jira transition WAS applied, but \(count) PR action\(count == 1 ? "" : "s") did not:"
    }

    static let prActionsIncompleteFootnote = "Do it on the PR directly — retrying the transition won't fix it."

    /// Says only what the window can vouch for; the reason rendered beneath it comes from
    /// `PRActionTally.blockedReason` and already ends in "…so no PR action ran."
    static let prActionsDidNotRun = "The Jira transition was applied."
}

/// Warns that a merge will be refused for unresolved conversations, before the button is pressed.
///
/// Keyed on `mergeStateStatus == "BLOCKED"` together with unresolved threads, rather than on the repo's
/// `required_conversation_resolution` setting. Both were available — his token can read branch protection
/// on the repos that have it on — and the verdict beats the rule:
///
/// - Reading protection needs admin, so it 403s for most tokens this app will ever hold, and a repo whose
///   settings cannot be read is not a repo that requires resolution. The fallback would be this anyway.
/// - It costs nothing: `mergeStateStatus` and `unresolvedThreads` both already ride the per-PR enrichment.
/// - The setting says what the rule is; `BLOCKED` says GitHub is refusing this PR now, which is the thing
///   worth warning about. A repo with the rule on and every thread resolved is not `BLOCKED`.
///
/// Anything other than `BLOCKED` — including `UNKNOWN`, which is GitHub still computing — produces no
/// warning. Unknown must not warn falsely.
enum MergeBlockWarning {

    /// The line to show, or nil when there is nothing to warn about.
    ///
    /// Silent when no merge is requested, and silent when the resolve action is already going to run: the
    /// threads are about to be resolved, so the merge is not the one that fails.
    static func label(
        prs: [PRActionsStatus.LinkedPR],
        mergeRequested: Bool,
        resolveRequested: Bool
    ) -> String? {
        guard mergeRequested, !resolveRequested else { return nil }
        let blocked = prs.filter { pr in
            guard !pr.isMerged, let unresolved = pr.unresolvedThreads, unresolved > 0 else { return false }
            return pr.mergeStateStatus?.uppercased() == "BLOCKED"
        }
        guard !blocked.isEmpty else { return nil }

        let total = blocked.reduce(0) { $0 + ($1.unresolvedThreads ?? 0) }
        let conversations = "\(total) unresolved conversation\(total == 1 ? "" : "s")"
        let where_ = blocked.count == 1
            ? blocked[0].prLabelForWarning
            : "\(blocked.count) PRs"
        return "GitHub will refuse the merge on \(where_): \(conversations). "
            + "Turn on \"Resolve open review conversations\" for this transition, or resolve them on the PR."
    }
}

/// Whether to offer resolving open review conversations, and what the offer says. One implementation for
/// both dialogs, so the single-issue and bulk wording cannot drift.
enum PRResolveOffer {
    /// One PR's unresolved conversations. `authors` may be empty while the names are still loading, or if
    /// that read failed — the offer stands either way, since the count is what it is about.
    struct Candidate: Equatable {
        let prLabel: String
        let unresolved: Int
        var authors: [String] = []
    }

    /// Only PRs with something to resolve. A PR whose enrichment failed has a nil count and is excluded:
    /// unknown is not "has conversations", and it must not conjure a checkbox.
    static func candidates(from prs: [PRActionsStatus.LinkedPR]) -> [Candidate] {
        prs.compactMap { pr in
            guard let unresolved = pr.unresolvedThreads, unresolved > 0, !pr.isMerged else { return nil }
            return Candidate(prLabel: pr.label, unresolved: unresolved)
        }
    }

    /// The checkbox label, or nil when there is nothing to offer — which is what keeps a clean PR free of
    /// a control that would always be there and usually mean nothing.
    ///
    /// One PR names whose conversations they are; several report the spread instead, because a list of
    /// names across a dozen PRs neither fits nor helps.
    static func label(for candidates: [Candidate]) -> String? {
        let total = candidates.reduce(0) { $0 + $1.unresolved }
        guard total > 0 else { return nil }
        let conversations = "\(total) open conversation\(total == 1 ? "" : "s")"
        guard candidates.count == 1 else {
            return "Resolve \(conversations) across \(candidates.count) PRs"
        }
        let authors = Array(Set(candidates[0].authors)).sorted()
        guard !authors.isEmpty else { return "Resolve \(conversations)" }
        return "Resolve \(conversations) (\(authors.joined(separator: ", ")))"
    }
}

/// The reasons a dialog's submit button is disabled, rendered the one way. Shared because the
/// transition and bulk-move dialogs both gate on the same `missingRequirements`, and because a second
/// hand-rolled copy is how the styling drifts.
///
/// On the colour: orange across this app means "needs your attention before this does what you want" —
/// used both for blockers like these and for non-blocking advisories (the current-user prefill notice
/// below, the near-miss transition name in Preferences, `UserFieldDialog`'s warning). It is
/// deliberately not red, which is reserved for something that already failed. Stated here because this
/// is the most-read use of it.
struct ValidationHints: View {
    let problems: [String]

    var body: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(problems, id: \.self) { problem in
                    Text(problem)
                        .font(.footnote).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Which fields Jira itself says the transition requires, filled in asynchronously after the dialog
/// opens (same pattern as `PRActionsStatus`).
final class TransitionFieldRequirements: ObservableObject {
    @Published var loading: Bool = true
    @Published var requiredFieldIds: Set<String> = []
    /// True when the metadata read failed. Requiredness is then *unknown*, not empty — the dialog
    /// fails closed rather than letting a submit through that Jira would refuse.
    @Published var fetchFailed: Bool = false

    /// Marks the fetch finished. `ids == nil` means the read failed.
    func finish(_ ids: Set<String>?) {
        requiredFieldIds = ids ?? []
        fetchFailed = (ids == nil)
        loading = false
    }
}

/// Live view-model for the transition dialog's PR-actions section. AppDelegate populates it
/// asynchronously (after enriching each linked open PR via GitHub GraphQL) so the dialog
/// can show status indicators — "you've approved 2/3", etc. — without blocking on open.
final class PRActionsStatus: ObservableObject {
    struct LinkedPR: Identifiable {
        var id: String { url }
        let url: String
        let label: String
        let isMerged: Bool
        let viewerApproved: Bool
        let viewerRequestedChanges: Bool
        let isDraft: Bool
        /// Unresolved review threads on this PR, or nil when the enrichment failed — unknown, which must
        /// not read as "nothing to resolve".
        let unresolvedThreads: Int?
        /// GitHub's own mergeability verdict, or nil when the enrichment failed.
        let mergeStateStatus: String?

        var prLabelForWarning: String { label }
        /// False when the GitHub enrichment for this PR failed. Every other flag is then a default,
        /// not an observation — so nothing may be decided from them.
        let statesKnown: Bool
        let assignees: [String]
        let mergeCommitAllowed: Bool
        let squashMergeAllowed: Bool
        let rebaseMergeAllowed: Bool
    }
    @Published var loading: Bool = true
    @Published var openPRs: [LinkedPR] = []
    /// True when the linked-PR lookup itself failed, so `openPRs` being empty means "we don't know"
    /// rather than "there are none".
    @Published var lookupFailed: Bool = false
    /// Whether the Jira ticket's assignee is the currently-authenticated user.
    @Published var jiraAssignedToMe: Bool = false
    /// Display name of the Jira ticket's assignee (nil when unassigned).
    @Published var jiraAssigneeName: String? = nil

    func allowsMergeMethod(_ method: String, on pr: LinkedPR) -> Bool {
        switch method {
        case "merge":  return pr.mergeCommitAllowed
        case "squash": return pr.squashMergeAllowed
        case "rebase": return pr.rebaseMergeAllowed
        default:       return false
        }
    }

    /// Whether the viewer's latest review on `pr` is already `action`. Drives the status line.
    func viewerSubmitted(_ action: PRReviewAction, on pr: LinkedPR) -> Bool {
        switch action {
        case .none:           return false
        case .approve:        return pr.viewerApproved
        case .requestChanges: return pr.viewerRequestedChanges
        }
    }

    /// Whether submitting `action` again would add nothing, so the PR can be skipped.
    ///
    /// Only approvals: a second APPROVE on a PR you've already approved carries no information.
    /// A second REQUEST_CHANGES does — its comment is the entire payload, and the case that
    /// produces one is precisely when the viewer's latest review is already CHANGES_REQUESTED
    /// (the ticket has come back a second time, GitHub doesn't clear the old review state, and
    /// the endpoint accepts the repeat).
    func resubmissionIsRedundant(_ action: PRReviewAction, on pr: LinkedPR) -> Bool {
        action == .approve && pr.viewerApproved
    }

    /// The action each PR starts with when the dialog opens.
    ///
    /// Two PRs get `.none` rather than `blanket`: one whose enrichment failed, because every flag on it
    /// is a default rather than an observation; and one already approved when the blanket action is
    /// request-changes, which is the agreed default. Neither is dropped from the list — the row shows
    /// why and can be overridden.
    static func seedActions(blanket: PRReviewAction, prs: [LinkedPR]) -> [String: PRReviewAction] {
        var seeded: [String: PRReviewAction] = [:]
        for pr in prs {
            // Written as `PRReviewAction.none`, never `.none`: in a dictionary subscript that shorthand
            // resolves to `Optional.none` and REMOVES the key, which silently returns the PR to the
            // blanket action — exactly the supersede this seeding exists to prevent.
            if !pr.statesKnown || pr.isMerged {
                seeded[pr.url] = PRReviewAction.none
            } else if blanket == .requestChanges && pr.viewerApproved {
                seeded[pr.url] = PRReviewAction.none
            } else {
                seeded[pr.url] = blanket
            }
        }
        return seeded
    }

    /// Why a row is not doing what the blanket action says, or what it will override if switched on.
    ///
    /// Takes both actions because the interesting case is the default one, where `resolved` has already
    /// been reduced to Skip and only `blanket` still says what was asked for.
    static func rowCaveat(blanket: PRReviewAction, resolved: PRReviewAction, on pr: LinkedPR) -> String? {
        if !pr.statesKnown { return "Couldn't read this PR's review state — skipped unless you say otherwise." }
        if pr.isMerged { return "Already merged." }
        if pr.viewerApproved && (blanket == .requestChanges || resolved == .requestChanges) {
            return "You approved this earlier — requesting changes will supersede that approval."
        }
        return nil
    }

    /// One PR and the review event it will receive.
    struct PlannedReview {
        let pr: LinkedPR
        let event: String
    }

    /// What the batch is actually going to do, decided once so the run and the summary cannot disagree.
    /// Every candidate lands in exactly one bucket.
    struct ReviewPlan {
        var submit: [PlannedReview] = []
        /// Asked for, refused as adding nothing: a second approve, or the agreed skip of a PR you
        /// approved when the blanket action is request-changes.
        var alreadyApproved: [LinkedPR] = []
        /// Not attempted because the PR's review state could not be read.
        var stateUnknown: [LinkedPR] = []
        var skippedByChoice: [LinkedPR] = []
        /// Asked for, withheld because its mandatory comment is blank. Never silent.
        var withheldForBlankComment: [LinkedPR] = []

        /// One clause per verb, so a mixed batch is not reported under a single one.
        var submittedEvents: [String] { Array(Set(submit.map(\.event))).sorted() }
        func submitCount(for event: String) -> Int { submit.filter { $0.event == event }.count }
    }

    static func reviewPlan(candidates: [LinkedPR], actions: PRActionChoices) -> ReviewPlan {
        var plan = ReviewPlan()
        for pr in candidates {
            let resolved = actions.review(forPRAt: pr.url)
            switch resolved {
            case .none:
                if !pr.statesKnown { plan.stateUnknown.append(pr) }
                else if pr.viewerApproved && actions.review == .requestChanges { plan.alreadyApproved.append(pr) }
                else if actions.review != .none { plan.skippedByChoice.append(pr) }
            case .approve where pr.viewerApproved:
                plan.alreadyApproved.append(pr)
            case .approve, .requestChanges:
                if let event = actions.reviewEvent(for: resolved) {
                    plan.submit.append(PlannedReview(pr: pr, event: event))
                } else {
                    plan.withheldForBlankComment.append(pr)
                }
            }
        }
        return plan
    }

    static func rowState(_ pr: LinkedPR) -> String {
        if !pr.statesKnown { return "state unknown" }
        var parts: [String] = [pr.isMerged ? "merged" : "open"]
        if pr.isDraft { parts.append("draft") }
        if pr.viewerApproved { parts.append("you approved") }
        else if pr.viewerRequestedChanges { parts.append("you requested changes") }
        else { parts.append("no review from you") }
        return parts.joined(separator: " · ")
    }
}

/// Sheet shown before a transition is submitted. Renders only the fields that the configured
/// prompt enables — comment, a user multi-picker, a free-text field, or any combination.
struct TransitionDialog: View {
    let issueKey: String
    let transitionName: String
    let config: TransitionPromptConfig
    /// When true, a "Also update GitHub PR" checkbox is shown alongside the user picker; its
    /// state is passed through to `onSubmit`. Only meaningful when `config.hasUserField`.
    let showGithubMirrorCheckbox: Bool
    /// Optional live status feed for the PR-actions section. Nil when the transition's
    /// prompt config has no PR actions enabled.
    @ObservedObject var prStatus: PRActionsStatus
    /// Jira's own required-field metadata for this transition, filled in after open.
    @ObservedObject var requirements: TransitionFieldRequirements
    let onSubmit: (String, [JiraUser], String, String, Bool, PRActionChoices, @escaping (TransitionSubmitOutcome) -> Void) -> Void
    /// Supplies the logins behind a PR's unresolved conversations. Injected so the view never holds the
    /// GitHub token.
    let resolveThreadAuthors: (String, @escaping ([String]) -> Void) -> Void
    let onCancel: () -> Void

    @State private var comment: String = ""
    @State private var freeText: String = ""
    @State private var selectedUsers: Set<JiraUser> = []
    @State private var availableUsers: [JiraUser] = []
    @State private var userFilter: String = ""
    @State private var usersLoading: Bool = false
    @State private var loadError: String?
    @State private var selectedOptionValue: String = ""
    @State private var submitting: Bool = false
    @State private var updateGithub: Bool = true
    @State private var prReview: Bool = true
    @State private var prReviewComment: String = ""
    @State private var prMerge: Bool = true
    @State private var prMergeMethod: String = "rebase"
    @State private var prSyncAssignee: Bool = true
    @State private var prResolveThreads: Bool = true
    /// Unchecked on purpose: ticking it claims he addressed the feedback, so he has to say so.
    @State private var resolveAsked: Bool = false
    /// Thread authors per PR url, filled in after the counts land. Absent names never withhold the offer.
    @State private var resolveAuthors: [String: [String]] = [:]
    /// Runtime only: a choice about one PR today has no meaning next time, so none of this is persisted.
    @State private var perPRActions: [String: PRReviewAction] = [:]
    @State private var touchedPRs: Set<String> = []
    /// Jira's own rejection message from the last attempt — e.g. "Testers are required before
    /// moving into QA." Kept in the window because the notification is missable and the console
    /// line is invisible.
    @State private var submitError: String?
    /// One line per PR action that didn't land, shown while the window stays open.
    @State private var prFailureLines: [String] = []
    /// Why the PR-action batch never started. Reported, but not as a failure.
    @State private var prNote: String?
    /// True when the refusal came after the field values had already been written.
    @State private var submitErrorAfterFieldsWritten: Bool = false
    /// True while the user picker still holds exactly what was prefilled and nothing was touched.
    /// Only interesting for a required field: a prefill satisfies the gate without a decision being
    /// made, so it gets said out loud rather than passing silently.
    @State private var userSelectionIsUntouchedPrefill: Bool = false
    /// Whether that prefill came from `userFieldDefaultsToCurrentUser` rather than the ticket.
    @State private var prefillWasCurrentUser: Bool = false
    /// True once Jira has accepted the transition. The window may still be open — waiting on PR
    /// actions, or reporting that some failed — but re-submitting is no longer the right offer.
    @State private var transitionApplied: Bool = false

    private var filteredUsers: [JiraUser] {
        let q = userFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return availableUsers }
        return availableUsers.filter { user in
            if user.displayName.lowercased().contains(q) { return true }
            if let email = user.emailAddress?.lowercased(), email.contains(q) { return true }
            if let name = user.name?.lowercased(), name.contains(q) { return true }
            return false
        }
    }

    private let client = JiraClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if config.hasUserField {
                userPickerSection
            }

            if config.hasSelectField {
                selectFieldSection
            }

            if config.hasTextField {
                textFieldSection
            }

            if config.includeComment {
                commentSection
            }

            if config.hasPRActions {
                prActionsSection
            }

            Spacer(minLength: 0)

            validationSection
            outcomeSection

            footer
        }
        .padding(16)
        // minHeight, not height: the reported errors carry server text of unknown length, and
        // dialogHeight()'s per-section constants are an estimate. A fixed height would clip the
        // footer — and the Close button with it — the moment an estimate came in low.
        .frame(width: 520)
        .frame(minHeight: dialogHeight())
        .onAppear {
            // Defer to the next runloop tick so the @State mutation in loadUsers() doesn't
            // land inside the window's first layout/CA commit — quiets the "open a new
            // transaction during CA commit" console warning.
            if config.hasUserField {
                DispatchQueue.main.async {
                    loadUsers()
                }
            }
            // Seed the merge-method picker from the config-level default.
            prMergeMethod = config.prMergeMethod
            seedPerPRActions()
        }
        .onChange(of: prStatus.openPRs.map(\.url)) { _ in
            seedPerPRActions()
            loadResolveAuthors()
        }
        .onChange(of: prReview) { _ in seedPerPRActions() }
    }

    private var reviewToggleLabel: String {
        config.prReviewAction == .requestChanges
            ? "Request changes on linked open PRs"
            : "Approve linked open PRs"
    }

    /// Says "required" in request-changes mode, where GitHub won't take a bodyless review.
    private var reviewCommentPlaceholder: String {
        config.prReviewAction.requiresComment
            ? "Review comment (required)"
            : "Approval comment (optional)"
    }

    /// The PR-action choices as the dialog currently stands. Built here, not only in `submit()`, so
    /// the submit gate and the inline hint test the same value the batch will actually run on.
    /// nil when there is nothing to resolve, which is what keeps the checkbox off a clean PR.
    private var resolveOfferLabel: String? {
        let candidates = PRResolveOffer.candidates(from: prStatus.openPRs).map { candidate in
            var withAuthors = candidate
            withAuthors.authors = resolveAuthors[
                prStatus.openPRs.first { $0.label == candidate.prLabel }?.url ?? ""
            ] ?? []
            return withAuthors
        }
        return PRResolveOffer.label(for: candidates)
    }

    /// Advisory rather than a gate: the transition is the point and the merge is one of its side effects,
    /// so this says what will happen instead of refusing to proceed.
    private var mergeBlockWarning: String? {
        MergeBlockWarning.label(
            prs: prStatus.openPRs,
            mergeRequested: currentPRChoices.merge,
            resolveRequested: resolveThreadsRequested
        )
    }

    private var blanketAction: PRReviewAction {
        prReview ? config.prReviewAction : .none
    }

    /// Whether the per-PR list is offered at all. One PR renders exactly as it did before this existed —
    /// the everyday flow does not pay for the multi-PR case.
    /// The two triggers meet here and cannot double-fire: a prompt is either always-resolve or ask, never
    /// both, so only one of these can be true.
    private var resolveThreadsRequested: Bool {
        switch config.prResolveThreads {
        case .never:  return false
        case .always: return prResolveThreads
        case .ask:    return resolveAsked && resolveOfferLabel != nil
        }
    }

    private var currentPRChoices: PRActionChoices {
        guard config.hasPRActions else { return .disabled }
        return PRActionChoices(
            review: blanketAction,
            reviewComment: prReviewComment,
            merge: config.allowsPRMerge && prMerge,
            mergeMethod: prMergeMethod,
            syncAssignee: config.enablePRAssigneeSync && prSyncAssignee,
            resolveThreads: resolveThreadsRequested,
            reviewByPRURL: perPRActions
        )
    }

    /// Which review state the status line reports on. A merge-only or assignee-only config still
    /// reports approvals, as it did before request-changes existed.
    private var displayedReviewAction: PRReviewAction {
        config.prReviewAction == .requestChanges ? .requestChanges : .approve
    }

    private var prActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PR actions").font(.headline)

            // Status indicators fill in as the async PR enrichment lands.
            prStatusSummary

            if config.prReviewAction != .none {
                Toggle(reviewToggleLabel, isOn: $prReview)
                if prReview, !prStatus.openPRs.isEmpty {
                    perPRRows
                }
                if prReview {
                    TextField(reviewCommentPlaceholder, text: $prReviewComment, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(2...5)
                        .padding(.leading, 20)
                }
            }
            if config.allowsPRMerge {
                HStack {
                    Toggle("Merge linked open PRs", isOn: $prMerge)
                    Picker("Method:", selection: $prMergeMethod) {
                        Text("Merge").tag("merge")
                        Text("Squash").tag("squash")
                        Text("Rebase").tag("rebase")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .disabled(!prMerge)
                }
            }
            if config.prResolveThreads == .always {
                Toggle("Resolve open review conversations", isOn: $prResolveThreads)
            }
            if config.prResolveThreads == .ask, let offer = resolveOfferLabel {
                Toggle(offer, isOn: $resolveAsked)
            }
            if let warning = mergeBlockWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if config.enablePRAssigneeSync {
                Toggle("Set Jira Assignee as PR Assignee (only when PR Assignee is blank)", isOn: $prSyncAssignee)
            }
        }
    }

    @ViewBuilder
    private var perPRRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(prStatus.openPRs) { pr in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(pr.label).font(.footnote)
                        Text(PRActionsStatus.rowState(pr)).font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: binding(for: pr)) {
                            Text("Skip").tag(PRReviewAction.none)
                            Text("Approve").tag(PRReviewAction.approve)
                            Text("Request changes").tag(PRReviewAction.requestChanges)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .disabled(pr.isMerged)
                    }
                    if let caveat = PRActionsStatus.rowCaveat(
                        blanket: blanketAction, resolved: resolvedAction(for: pr), on: pr
                    ) {
                        Text(caveat).font(.footnote).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.leading, 20)
    }

    private func resolvedAction(for pr: PRActionsStatus.LinkedPR) -> PRReviewAction {
        perPRActions[pr.url] ?? blanketAction
    }

    private func binding(for pr: PRActionsStatus.LinkedPR) -> Binding<PRReviewAction> {
        Binding(
            get: { resolvedAction(for: pr) },
            set: {
                perPRActions[pr.url] = $0
                touchedPRs.insert(pr.url)
            }
        )
    }

    @ViewBuilder
    private var prStatusSummary: some View {
        if prStatus.loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking linked PRs…").font(.footnote).foregroundColor(.secondary)
            }
        } else if prStatus.openPRs.isEmpty {
            Text("No open linked PRs.").font(.footnote).foregroundColor(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let name = prStatus.jiraAssigneeName {
                    Text(prStatus.jiraAssignedToMe
                         ? "Jira ticket is already assigned to you."
                         : "Jira ticket assigned to \(name).")
                        .font(.footnote).foregroundColor(.secondary)
                } else {
                    Text("Jira ticket is unassigned.").font(.footnote).foregroundColor(.secondary)
                }
                let total = prStatus.openPRs.count
                let action = displayedReviewAction
                let done = prStatus.openPRs.filter { prStatus.viewerSubmitted(action, on: $0) }.count
                let merged = prStatus.openPRs.filter(\.isMerged).count
                let verb = action == .requestChanges ? "requested changes on" : "approved"
                Text("You've \(verb) \(done)/\(total) open PR\(total == 1 ? "" : "s")\(merged > 0 ? "; \(merged) already merged." : ".")")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(transitionName)
                .font(.title3)
                .fontWeight(.semibold)
            Text(issueKey)
                .font(.subheadline)
                .foregroundColor(.issueKey)
        }
    }

    private var userPickerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.userFieldLabel)
                .font(.headline)

            HStack {
                TextField("Filter loaded users…", text: $userFilter)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button {
                    loadUsers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload assignable users")
                .disabled(usersLoading)
            }

            if usersLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading users…").foregroundColor(.secondary)
                }
            } else if let loadError {
                Text(loadError)
                    .foregroundColor(.red)
                    .font(.footnote)
            } else if availableUsers.isEmpty {
                Text("No assignable users found for \(Text(issueKey).foregroundColor(.issueKey)).")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            } else if filteredUsers.isEmpty {
                Text("No users match your filter.")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredUsers) { user in
                        userRow(user)
                    }
                }
            }
            .frame(height: 160)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )

            if !selectedUsers.isEmpty {
                Text(selectedSummary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            if showGithubMirrorCheckbox {
                Toggle("Also update GitHub PR: assign me, add selected users as reviewers", isOn: $updateGithub)
                    .font(.footnote)
            }
        }
    }

    private func userRow(_ user: JiraUser) -> some View {
        let isSelected = selectedUsers.contains(user)
        return HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(user.displayName)
                if let email = user.emailAddress, !email.isEmpty {
                    Text(email).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            toggle(user)
        }
    }

    private var selectFieldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.selectFieldLabel)
                .font(.headline)
            Picker("", selection: $selectedOptionValue) {
                Text("— Choose —").tag("")
                ForEach(config.selectOptions) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var textFieldSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.textFieldLabel)
                .font(.headline)
            if config.textFieldMultiline {
                // TextField(axis: .vertical) participates in the keyboard focus chain (Tab moves on);
                // TextEditor would capture Tab as an input character.
                TextField("", text: $freeText, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(4...8)
            } else {
                TextField("", text: $freeText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comment")
                .font(.headline)
            TextField("", text: $comment, axis: .vertical)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .lineLimit(5...10)
        }
    }

    /// Everything currently blocking submit, all of it rather than the first problem. One list
    /// feeds one disabled state and one hint, so a required-field check added later shows up in
    /// both places by construction.
    ///
    /// Always visible while non-empty, not raised on a submit attempt: the Transition button is
    /// disabled off this same list, and a dead button with no stated reason is worse than an
    /// early hint.
    private var validationProblems: [String] {
        var problems: [String] = []
        // The review is the point of this transition: finishing without it would move the ticket and
        // leave the PR untouched. Same predicate `applyPRActions` gates on, not a second derivation.
        if currentPRChoices.reviewBlockedForEmptyComment {
            problems.append("Write a review comment — GitHub rejects a request-changes review without one.")
        }
        // Submitting before the linked-PR enrichment lands would find no candidates and drop every
        // PR action. The status line already says "Checking linked PRs…"; this is what makes the
        // button agree with it.
        if config.hasPRActions, prStatus.loading {
            problems.append("Still checking linked PRs…")
        }
        if config.hasPRActions, prStatus.lookupFailed {
            // An empty list from a failed lookup is indistinguishable from a ticket with no PRs, and
            // one of those means "nothing to do" while the other means "we have no idea".
            problems.append("Couldn't look up this ticket's linked PRs. Close and reopen the dialog.")
        }
        if config.hasGatableField {
            if requirements.loading {
                problems.append("Checking which fields Jira requires…")
            } else if requirements.fetchFailed {
                // Fail closed. Unknown is not false: guessing "nothing is required" would hand back
                // the silent failure this whole change removes. Cheap, too — if Jira is unreachable
                // for the metadata it is unreachable for the transition.
                // A failed read also covers the transition coming back absent, which is what happens
                // when someone else moved the ticket first.
                problems.append("Couldn't confirm which fields Jira requires — the transition may no longer be available. Close and reopen the dialog.")
            }
        }
        problems.append(contentsOf: config.missingRequirements(
            selectedUserCount: selectedUsers.count,
            textValue: freeText,
            selectValue: selectedOptionValue,
            jiraRequiredFieldIds: requirements.requiredFieldIds
        ))
        return problems
    }

    /// A required user field that is satisfied only by the current-user prefill. Not a blocker — the
    /// default was configured deliberately — but transitioning with yourself as tester when you meant
    /// someone else is a quiet wrong outcome, so it is named.
    private var prefillSatisfiesRequirementSilently: Bool {
        config.hasUserField
            && config.fieldIsRequired(
                config.userFieldId,
                manualFlag: config.userFieldRequired,
                jiraRequiredFieldIds: requirements.requiredFieldIds
            )
            && userSelectionIsUntouchedPrefill
            && prefillWasCurrentUser
            && !selectedUsers.isEmpty
    }

    private var submitErrorHeadline: String {
        TransitionOutcomeText.jiraRefused(fieldsWritten: submitErrorAfterFieldsWritten)
    }

    @ViewBuilder
    private var validationSection: some View {
        if !transitionApplied, prefillSatisfiesRequirementSilently {
            // Blue, not the orange below: orange means "this is why the button is disabled", and
            // this line is the opposite — the requirement is satisfied, just not by a decision.
            // The two can appear together, so they must not look the same.
            Label(
                "\(config.userFieldLabel) is required and was prefilled with you — change it if someone else should be named.",
                systemImage: "info.circle"
            )
            .font(.footnote).foregroundColor(.accentColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !transitionApplied {
            ValidationHints(problems: validationProblems)
        }
    }

    /// Failures reported in the window, while it is still open. A dismissed window is what made the
    /// old behaviour a lie: everything looked like it worked.
    @ViewBuilder
    private var outcomeSection: some View {
        if let submitError {
            VStack(alignment: .leading, spacing: 2) {
                Text(submitErrorHeadline)
                    .font(.footnote).bold().foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text(submitError)
                    .font(.footnote).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        if let prNote {
            // Deliberately not red and deliberately not in the failure list: nothing was attempted,
            // so calling it a failed action would be the same conflation in the other direction.
            VStack(alignment: .leading, spacing: 2) {
                Text(TransitionOutcomeText.prActionsDidNotRun)
                    .font(.footnote).foregroundColor(.secondary)
                Text(prNote)
                    .font(.footnote).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !prFailureLines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(TransitionOutcomeText.prActionsIncomplete(count: prFailureLines.count))
                    .font(.footnote).bold().foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(prFailureLines, id: \.self) { line in
                    Text("• \(line)").font(.footnote).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text(TransitionOutcomeText.prActionsIncompleteFootnote)
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            // Invisible companion button: binds ⌘-Return as a dialog-wide submit shortcut.
            // The visible Transition button keeps .defaultAction so Return still works when
            // no text field has focus, but a multi-line TextField swallows Return for newlines,
            // so we need ⌘-Return as an unambiguous submit path.
            HiddenSubmitButton(disabled: !canSubmit) { submit() }

            Spacer()
            if transitionApplied {
                // The transition already went through. Offering "Transition" again would invite
                // re-running it; the only sensible action left is to acknowledge and close.
                Button("Close") { onCancel() }
                    .keyboardShortcut(.defaultAction)
            } else {
                // Disabled in flight: the transition and the PR actions are already running and
                // cannot be called back, so a live Cancel would only throw away their report.
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(submitButtonTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
    }

    private var submitButtonTitle: String {
        submitting ? "Submitting…" : "Transition"
    }

    /// The single gate: not already in flight, nothing outstanding, and not already applied.
    private var canSubmit: Bool {
        !submitting && !transitionApplied && validationProblems.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        submitError = nil
        prFailureLines = []
        prNote = nil
        let flag = showGithubMirrorCheckbox && updateGithub
        let choices = currentPRChoices
        onSubmit(comment, Array(selectedUsers), freeText, selectedOptionValue, flag, choices) { outcome in
            switch outcome {
            case .jiraRefused(let message, let fieldsWritten):
                // Stay open, say why, and be honest about whether anything was persisted.
                submitError = message
                submitErrorAfterFieldsWritten = fieldsWritten
                submitting = false
            case .applied:
                // AppDelegate closes the window in this case; `submitting` stays true so the button
                // can't re-fire in the frames before it goes away.
                transitionApplied = true
            case .prActionsDidNotRun(let reason):
                transitionApplied = true
                submitting = false
                prNote = reason
            case .prActionsIncomplete(let lines):
                transitionApplied = true
                submitting = false
                prFailureLines = lines
            }
        }
    }

    // MARK: - Helpers

    /// Reseeds from the blanket action, keeping any row the user has set by hand. Without that, flipping
    /// the review checkbox off and on would silently discard explicit choices.
    /// Names for the offer, one call per PR that actually has unresolved conversations — nothing is asked
    /// for a clean ticket, and a failure leaves the offer standing on its count.
    private func loadResolveAuthors() {
        guard config.prResolveThreads == .ask else { return }
        for candidate in PRResolveOffer.candidates(from: prStatus.openPRs) {
            guard let pr = prStatus.openPRs.first(where: { $0.label == candidate.prLabel }),
                  resolveAuthors[pr.url] == nil
            else { continue }
            resolveThreadAuthors(pr.url) { authors in
                DispatchQueue.main.async { resolveAuthors[pr.url] = authors }
            }
        }
    }

    private func seedPerPRActions() {
        let seeded = PRActionsStatus.seedActions(blanket: blanketAction, prs: prStatus.openPRs)
        perPRActions = seeded.merging(perPRActions.filter { touchedPRs.contains($0.key) }) { _, chosen in chosen }
    }

    private func toggle(_ user: JiraUser) {
        userSelectionIsUntouchedPrefill = false
        if selectedUsers.contains(user) {
            selectedUsers.remove(user)
        } else {
            if config.userFieldAllowsMultiple {
                selectedUsers.insert(user)
            } else {
                selectedUsers = [user]
            }
        }
    }

    private var selectedSummary: String {
        let names = selectedUsers.map(\.displayName).sorted()
        return "Selected: \(names.joined(separator: ", "))"
    }

    private func loadUsers() {
        usersLoading = true
        loadError = nil
        client.getAssignableUsers(issueKey: issueKey) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let users):
                    self.availableUsers = users
                    self.preselectIfNeeded()
                case .failure(let message):
                    self.availableUsers = []
                    self.loadError = message
                }
                self.usersLoading = false
            }
        }
    }

    /// Pre-fills the user picker so the user sees who's already assigned before deciding.
    /// `userFieldDefaultsToCurrentUser` (used for "Start Progress") wins; otherwise we read
    /// whatever's currently in the configured field on the issue.
    private func preselectIfNeeded() {
        guard selectedUsers.isEmpty else { return }
        if config.userFieldDefaultsToCurrentUser {
            client.getCurrentUser { me in
                DispatchQueue.main.async {
                    if let me { self.applyPrefill([me], wasCurrentUser: true) }
                }
            }
        } else {
            client.getIssueFieldUsers(issueKey: issueKey, fieldId: config.userFieldId) { existing in
                DispatchQueue.main.async {
                    // A failed read must be surfaced — submitting an empty picker clears the
                    // field, so silently presenting an empty selection would be destructive.
                    guard let existing else {
                        self.loadError = "Couldn't load the field's current users — submitting may clear it."
                        return
                    }
                    self.applyPrefill(existing)
                }
            }
        }
    }

    /// Maps prefill candidates to instances already in `availableUsers` so the row checkboxes
    /// light up; falls back to the raw user otherwise (still selected, just not in the visible list).
    private func applyPrefill(_ candidates: [JiraUser], wasCurrentUser: Bool = false) {
        guard !candidates.isEmpty else { return }
        let matched: [JiraUser] = candidates.map { candidate in
            availableUsers.first(where: { Self.sameUser($0, candidate) }) ?? candidate
        }
        selectedUsers = Set(matched)
        // Remembered so a required field satisfied purely by a prefill can say so. Cleared by the
        // first click in `toggle`.
        userSelectionIsUntouchedPrefill = true
        prefillWasCurrentUser = wasCurrentUser
        arrangeSelectedFirst()
    }

    /// Moves pre-selected users to the top of the list (one-shot — clicks after this don't reshuffle).
    /// Selected users not returned by assignable-search are inserted so the row stays visible.
    private func arrangeSelectedFirst() {
        let selectedInList = availableUsers.filter { selectedUsers.contains($0) }
        let selectedNotInList = selectedUsers.filter { !availableUsers.contains($0) }
        let unselectedInList = availableUsers.filter { !selectedUsers.contains($0) }
        availableUsers = selectedInList + Array(selectedNotInList) + unselectedInList
    }

    private static func sameUser(_ a: JiraUser, _ b: JiraUser) -> Bool {
        if let x = a.accountId, let y = b.accountId, !x.isEmpty, !y.isEmpty { return x == y }
        if let x = a.name, let y = b.name, !x.isEmpty, !y.isEmpty { return x == y }
        if let x = a.key, let y = b.key, !x.isEmpty, !y.isEmpty { return x == y }
        return false
    }

    private func dialogHeight() -> CGFloat {
        var h: CGFloat = 80 // header + footer + padding
        if config.hasUserField { h += 280 }
        if config.hasSelectField { h += 70 }
        if config.hasTextField { h += config.textFieldMultiline ? 130 : 70 }
        if config.includeComment { h += 150 }
        if showGithubMirrorCheckbox { h += 24 }
        if config.hasPRActions {
            var pr: CGFloat = 60 // headline + status summary
            if config.prReviewAction != .none { pr += (prReview ? 90 : 24) }
            if prReview { pr += CGFloat(prStatus.openPRs.count) * 46 }
            if config.allowsPRMerge { pr += 32 }
            if config.enablePRResolveThreads { pr += 24 }
            if config.enablePRAssigneeSync { pr += 24 }
            h += pr
        }
        // Room for whatever the window is currently reporting. Growth rather than a scroll view:
        // an error the user has to scroll to find is the problem we're fixing.
        if !transitionApplied { h += CGFloat(validationProblems.count) * 18 }
        if !transitionApplied, prefillSatisfiesRequirementSilently { h += 32 }
        if submitError != nil { h += 52 }
        if prNote != nil { h += 52 }
        if !prFailureLines.isEmpty { h += 48 + CGFloat(prFailureLines.count) * 18 }
        return max(h, 220)
    }
}
