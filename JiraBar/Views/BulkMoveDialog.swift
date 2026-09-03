import SwiftUI

/// Why the To Do rows in a bulk-move candidate list may be short, when they are.
///
/// Two reasons, because they lead to different user actions: waiting a moment and reopening fixes
/// one, and nothing the user does in this dialog fixes the other. Neither may be shown as an empty
/// backlog — see `TodoBacklogState`.
enum BulkBacklogGap {
    case searching
    case unreachable
}

/// Who put the current selection in the bulk dialog's user picker.
///
/// A bool could not express this. Three states matter, and the middle two are what keep a bulk
/// write honest: nothing has been chosen and a preselect may fill it in; the dialog filled it in,
/// so it may be dropped and re-resolved when the prompt config changes under it; the user decided,
/// so it is never overwritten and never re-preselected. **Deciding on nobody is a decision** — an
/// empty picker the user emptied must not be refilled, which is why this is not inferred from
/// `pickedUsers.isEmpty`.
enum BulkUserSelectionOrigin {
    case untouched
    case preselect
    case user
}

/// Move multiple issues to a new status in one shot.
///
/// Flow: pick a "from" status (only statuses that currently have issues are listed) → pick issues
/// from that status with checkboxes → pick a "to" status from the intersection of transitions
/// every selected issue supports → fill in any prompt fields (reviewers / QA result / resolution
/// etc., per the matching TransitionPromptConfig) and a shared comment → submit. Each issue gets
/// its own transition POST (with the same field payload), serially, with a progress indicator.
struct BulkMoveDialog: View {
    let issues: [Issue]
    /// Candidate keys that came from the TODO backlog rather than the rendered ticket list.
    ///
    /// Two separate jobs, deliberately not merged: this labels individual rows with a trailing
    /// `backlog` marker, and — at *status* granularity, never row by row — it is what
    /// `autoCheckedKeys` reads to decide whether a from-status auto-checks at all.
    let backlogOnlyKeys: Set<String>
    /// Set when the To Do rows may be missing or short, and why — nil when they are complete.
    /// Surfaced rather than swallowed: an absent bucket must not read as an empty backlog.
    let backlogGap: BulkBacklogGap?
    let transitionPrompts: [TransitionPromptConfig]
    let statusOrder: [StatusDisplay]
    /// Returns true when the given Jira user-field id qualifies for the GitHub mirror
    /// (correct field id, token present, mapping path set). Passed in as a closure so the
    /// dialog stays ignorant of Defaults / Keychain plumbing.
    let showMirrorFor: (String) -> Bool
    /// Reports the per-key outcome so the caller can fan out the GitHub mirror when
    /// `updateGithub` is true. `users` is the shared reviewer selection applied to every
    /// successfully transitioned issue.
    let onSubmit: (
        _ successfulKeys: [String],
        _ users: [JiraUser],
        _ failures: [(key: String, reason: String?)],
        _ updateGithub: Bool,
        _ prActions: PRActionChoices
    ) -> Void
    let onCancel: () -> Void

    @State private var prReview: Bool = true
    @State private var prReviewComment: String = ""
    @State private var prMerge: Bool = true
    @State private var prSyncAssignee: Bool = true
    @State private var prResolveThreads: Bool = true
    @State private var fromStatus: String = ""
    @State private var checkedKeys: Set<String> = []
    /// issueKey -> transitions available on that issue (fetched lazily).
    @State private var transitionsByIssue: [String: [Transition]] = [:]
    @State private var fetchingFor: Set<String> = []
    @State private var selectedTransitionName: String = ""
    /// True while `selectedTransitionName` holds an auto-applied default the user has not
    /// overridden. A pick the user made themselves is never silently swapped for a different
    /// transition — this dialog applies its choice to every checked issue at once — so when the
    /// intersection stops offering it, it clears and Submit goes back to needing a decision.
    @State private var transitionSelectionIsDefault: Bool = true
    /// Whose choice `pickedUsers` currently is — see `BulkUserSelectionOrigin`. Same provenance rule
    /// as `transitionSelectionIsDefault`, and also what lets a required field satisfied purely by
    /// the preselect say so.
    @State private var userSelectionOrigin: BulkUserSelectionOrigin = .untouched

    // Per-prompt-config field state — only the ones the matching prompt enables actually render.
    @State private var comment: String = ""
    @State private var mentions: [MentionText.Mention] = []
    @State private var mentionListOpen = false
    @State private var pickedUsers: Set<JiraUser> = []
    @State private var assignableUsers: [JiraUser] = []
    /// Monotonic id of the newest `getAssignableUsers` request, so only its answer is applied.
    ///
    /// Two things make this load-bearing rather than tidiness. The picker is loaded from two places
    /// on a single open (a transitions completion and the transition's `onChange`), and
    /// `assignableUsers.isEmpty` cannot dedupe them because it only flips in a *completion* — so
    /// without this, the later answer overwrites the list the preselect was mapped against and can
    /// delete the row showing it. And `applyFromStatusChange` cannot cancel a request already
    /// pivoted on the previous status's issue; bumping this is what stops that answer landing.
    @State private var assignableUsersRequest = 0
    /// True while a request is outstanding, so the second caller on one pass does not issue a
    /// duplicate at all rather than issuing one whose answer is then discarded.
    @State private var loadingUsers = false
    @State private var userFilter: String = ""
    @State private var freeText: String = ""
    @State private var selectValue: String = ""

    @State private var submitting: Bool = false
    @State private var progress: String = ""
    @State private var updateGithub: Bool = true

    private let client = JiraClient()

    // MARK: - Derived

    /// Every status present in `issues`, in the user's configured order, with anything they have
    /// not ordered falling to the end alphabetically. Every candidate status is offered — the
    /// backlog's included — because the from-picker is how the user reaches it deliberately.
    private var availableFromStatuses: [String] {
        BulkMoveDialog.orderedStatuses(issues, order: statusOrder.map(\.name))
    }

    private var issuesInFromStatus: [Issue] {
        issues.filter { $0.fields.status.name == fromStatus }
    }

    /// Transitions that EVERY checked issue supports (matched by name, since transition IDs
    /// differ per issue/project). One representative `Transition` is kept for each name.
    private var availableTransitions: [Transition] {
        guard !checkedKeys.isEmpty else { return [] }
        var representative: [String: Transition] = [:]
        var counts: [String: Int] = [:]
        // Sorted, not raw Set order: `representative` is last-write-wins, and two issues can expose
        // the same transition name with different target statuses. Undefined order there decides
        // whether the default matches, so the order has to be fixed.
        for key in checkedKeys.sorted() {
            guard let ts = transitionsByIssue[key] else { return [] }  // not all loaded yet
            for t in ts {
                representative[t.name] = t
                counts[t.name, default: 0] += 1
            }
        }
        let required = checkedKeys.count
        return counts.compactMap { name, count -> Transition? in
            count == required ? representative[name] : nil
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var matchingPromptConfig: TransitionPromptConfig? {
        guard !selectedTransitionName.isEmpty else { return nil }
        return transitionPrompts.first {
            $0.transitionName.caseInsensitiveCompare(selectedTransitionName) == .orderedSame
        }
    }

    /// True when the currently-selected transition edits the configured PR-reviewer field
    /// and the app's mirror preconditions (token + map) are satisfied. Drives the checkbox.
    private var showGithubMirrorCheckbox: Bool {
        guard let config = matchingPromptConfig, config.hasUserField else { return false }
        return showMirrorFor(config.userFieldId)
    }

    private var filteredAssignableUsers: [JiraUser] {
        let q = userFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return assignableUsers }
        return assignableUsers.filter { u in
            if u.displayName.lowercased().contains(q) { return true }
            if let email = u.emailAddress?.lowercased(), email.contains(q) { return true }
            return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scrolls above a pinned footer rather than growing without limit. With PR actions, a prompt's
            // fields and a long issue list all showing, this dialog is taller than a laptop display — and
            // the one thing that must never be pushed off is the button it exists for.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    backlogNotice

            fromStatusSection

                    if !fromStatus.isEmpty {
                issueListSection
                    }

                    if !checkedKeys.isEmpty {
                toStatusSection
                    }

                    if let config = matchingPromptConfig {
                if config.hasUserField {
                    userPickerSection(config: config)
                }
                if config.hasSelectField {
                    selectFieldSection(config: config)
                }
                if config.hasTextField {
                    textFieldSection(config: config)
                }
                    }

                    if !selectedTransitionName.isEmpty {
                commentSection
                    }

                    if showGithubMirrorCheckbox {
                Toggle("Also update GitHub PRs for every moved issue: assign me, add selected users as reviewers", isOn: $updateGithub)
                    .font(.footnote)
                    }

                    if submitting {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(AppDelegate.attributedColoringIssueKeys(progress))
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }

                    prActionsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            requirementsSection

            footer
        }
        .padding(16)
        .frame(width: 600)
        .frame(minHeight: 700, maxHeight: .infinity)
        // On the outermost container, not on the "To" picker it watches: that picker renders only
        // once something is checked, and a modifier on a view that is not in the tree observes
        // nothing. Here it cannot be conditioned out from under the preselect.
        .onChange(of: selectedTransitionName) { _ in applyTransitionChange() }
        .onAppear {
            // Pre-pick the opening status — see `initialFromStatus` for why this is not simply the
            // first entry the picker offers.
            if fromStatus.isEmpty,
               let first = BulkMoveDialog.initialFromStatus(
                   candidates: issues, backlogOnly: backlogOnlyKeys,
                   order: statusOrder.map(\.name)
               ) {
                fromStatus = first
            }
            // When the from status is settled, default-check every issue in it.
            DispatchQueue.main.async { applyFromStatusChange() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.square")
                .foregroundColor(.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Move Multiple Issues")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Pick a from-status, choose issues, and submit a shared transition.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var fromStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From").font(.headline)
            Picker("", selection: $fromStatus) {
                ForEach(availableFromStatuses, id: \.self) { status in
                    Text(status).tag(status)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: fromStatus) { _ in applyFromStatusChange() }
        }
    }

    private var issueListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Issues (\(checkedKeys.count) selected)").font(.headline)
                Spacer()
                if !issuesInFromStatus.isEmpty {
                    Button("Select all") {
                        checkedKeys = Set(issuesInFromStatus.map(\.key))
                        loadTransitionsForChecked()
                        applyDefaultSelectionIfNeeded()
                    }
                    .controlSize(.small)
                    Button("Clear") {
                        checkedKeys.removeAll()
                        applyDefaultSelectionIfNeeded()
                    }
                    .controlSize(.small)
                    .disabled(checkedKeys.isEmpty)
                }
            }

            if issuesInFromStatus.isEmpty {
                Text("No issues in this status.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(issuesInFromStatus, id: \.key) { issue in
                            issueRow(issue)
                        }
                    }
                }
                .frame(height: 150)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                // Says why nothing is ticked. Without it an empty column in one status and a full
                // one in every other reads as a bug, and the user cannot tell it was deliberate.
                // Deliberately does not point at "Select all": the rule exists because a
                // pre-filled list gets submitted unread, and recommending the button that fills it
                // in one click argues against itself. It is right there for whoever wants it.
                if issuesInFromStatus.contains(where: { backlogOnlyKeys.contains($0.key) }) {
                    Text("This status includes backlog issues, so nothing starts checked — pick the ones you want to move.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Named when the To Do rows may be missing, with the reason — see `BulkBacklogGap`. Orange, not
    /// the accent colour: this is "attend to it before this does what you want", which is what
    /// orange means here — see `ValidationHints`.
    ///
    /// It also covers a second thing, which is why the wording is about the rows rather than about
    /// the network: with no backlog rows in the list, `autoCheckedKeys` has nothing to hold back on,
    /// so the To Do status auto-checks the user's own tickets there as it did before this feature.
    @ViewBuilder
    private var backlogNotice: some View {
        if let backlogGap {
            Label(
                BulkMoveDialog.backlogNoticeText(backlogGap),
                systemImage: "exclamationmark.triangle"
            )
            .font(.footnote).foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func backlogNoticeText(_ gap: BulkBacklogGap) -> String {
        switch gap {
        case .searching:
            return "Your TODO backlog is still loading, so To Do issues may be missing here. Close and reopen this dialog to include them."
        case .unreachable:
            return "Your TODO backlog couldn't be loaded, so To Do issues are missing here. This list is everything else."
        }
    }

    private func issueRow(_ issue: Issue) -> some View {
        let isChecked = checkedKeys.contains(issue.key)
        return HStack(spacing: 8) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundColor(isChecked ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(AppDelegate.attributedColoringIssueKeys(issue.fields.summary)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(issue.key).font(.caption).foregroundColor(.forIssueKey(issue.key))
                    // Trails the key rather than leading the row: the checkbox column is the row's
                    // anchor, and a marker in front of it would compete with the thing being read.
                    if backlogOnlyKeys.contains(issue.key) {
                        Text("backlog").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isChecked {
                checkedKeys.remove(issue.key)
            } else {
                checkedKeys.insert(issue.key)
                fetchTransitionsIfNeeded(for: issue.key)
            }
            // The changed intersection may no longer offer the chosen transition. Re-resolve:
            // a default gets re-defaulted, the user's own pick clears.
            applyDefaultSelectionIfNeeded()
        }
    }

    private var toStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To").font(.headline)
            if availableTransitions.isEmpty {
                let stillLoading = checkedKeys.contains(where: { fetchingFor.contains($0) || transitionsByIssue[$0] == nil })
                if stillLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading available transitions…").foregroundColor(.secondary).font(.footnote)
                    }
                } else {
                    Text("No transition is valid for every selected issue.")
                        .foregroundColor(.orange)
                        .font(.footnote)
                }
            } else {
                Picker("", selection: Binding(
                    get: { selectedTransitionName },
                    set: { picked in
                        selectedTransitionName = picked
                        transitionSelectionIsDefault = false
                    }
                )) {
                    Text("— Choose —").tag("")
                    ForEach(availableTransitions, id: \.name) { t in
                        Text(t.name).tag(t.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private func userPickerSection(config: TransitionPromptConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.userFieldLabel).font(.headline)
            HStack {
                TextField("Filter loaded users…", text: $userFilter)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button {
                    loadAssignableUsers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload assignable users from the first selected issue")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredAssignableUsers) { user in
                        userRow(user, multi: config.userFieldAllowsMultiple)
                    }
                }
            }
            .frame(height: 120)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
    }

    private func userRow(_ user: JiraUser, multi: Bool) -> some View {
        let isPicked = pickedUsers.contains(user)
        return HStack(spacing: 8) {
            Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                .foregroundColor(isPicked ? .accentColor : .secondary)
            Text(user.displayName)
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isPicked {
                pickedUsers.remove(user)
            } else if multi {
                pickedUsers.insert(user)
            } else {
                pickedUsers = [user]
            }
            // Touched, so it is theirs now: it survives a transition change, it stops being
            // reported as a requirement satisfied without a decision, and — including when they
            // just emptied the picker — it is never refilled by the preselect.
            userSelectionOrigin = .user
        }
    }

    private func selectFieldSection(config: TransitionPromptConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.selectFieldLabel).font(.headline)
            Picker("", selection: $selectValue) {
                Text("— Choose —").tag("")
                ForEach(config.selectOptions) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func textFieldSection(config: TransitionPromptConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.textFieldLabel).font(.headline)
            if config.textFieldMultiline {
                TextField("", text: $freeText, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(3...6)
            } else {
                TextField("", text: $freeText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comment (applies to every transitioned issue)").font(.headline)
            MentionTextField(
                placeholder: "",
                text: $comment,
                mentions: $mentions,
                dropdownOpen: $mentionListOpen,
                lineLimit: 3...6
            )
        }
    }

    private var footer: some View {
        HStack {
            HiddenSubmitButton(disabled: submitting || !canSubmit) { submit() }

            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(submitting ? "Moving…" : "Move \(checkedKeys.count) issue\(checkedKeys.count == 1 ? "" : "s")") {
                submit()
            }
            .keyboardShortcut(mentionListOpen ? nil : .defaultAction)
            .disabled(submitting || !canSubmit)
        }
    }

    @ViewBuilder
    private var requirementsSection: some View {
        if preselectSatisfiesRequirementSilently, let config = matchingPromptConfig {
            // Blue, not the orange below — same split as `TransitionDialog.validationSection`:
            // orange says "this is why the button is disabled", and this says the opposite, that the
            // requirement is met but not by a decision. They can show together, so they must differ.
            Label(
                "\(config.userFieldLabel) is required and was prefilled with you for all \(checkedKeys.count) issue\(checkedKeys.count == 1 ? "" : "s") — change it if someone else should be named.",
                systemImage: "info.circle"
            )
            .font(.footnote).foregroundColor(.accentColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        ValidationHints(problems: missingRequirements)
    }

    /// A required user field that only the current-user preselect is satisfying. Not a blocker — the
    /// default was configured deliberately — but this dialog writes that one selection to every
    /// checked issue, so naming yourself across a batch you never looked at is a quiet wrong
    /// outcome. Ported from `TransitionDialog.prefillSatisfiesRequirementSilently`; the count is the
    /// part that is specific to here.
    ///
    /// Manual flag only, matching `missingRequirements` — this dialog reads no per-issue metadata.
    private var preselectSatisfiesRequirementSilently: Bool {
        guard let config = matchingPromptConfig else { return false }
        return config.hasUserField
            && config.fieldIsRequired(
                config.userFieldId, manualFlag: config.userFieldRequired, jiraRequiredFieldIds: []
            )
            && userSelectionOrigin == .preselect
            && !pickedUsers.isEmpty
    }

    /// The batch's PR-action choices, from the same config the single-issue dialog uses. No per-PR rows:
    /// see the report — a dozen PRs across five tickets is not a grid anyone acts on.
    private var currentPRChoices: PRActionChoices {
        guard let config = matchingPromptConfig, config.hasPRActions else { return .disabled }
        return PRActionChoices(
            review: prReview ? config.prReviewAction : .none,
            reviewComment: prReviewComment,
            merge: config.allowsPRMerge && prMerge,
            mergeMethod: config.prMergeMethod,
            syncAssignee: config.enablePRAssigneeSync && prSyncAssignee,
            resolveThreads: config.prResolveThreads == .always && prResolveThreads
        )
    }

    @ViewBuilder
    private var prActionsSection: some View {
        if let config = matchingPromptConfig, config.hasPRActions {
            VStack(alignment: .leading, spacing: 6) {
                Text("PR actions").font(.headline)
                Text("Applied to every ticket that moves, one ticket at a time.")
                    .font(.footnote).foregroundColor(.secondary)
                if config.prReviewAction != .none {
                    Toggle(
                        config.prReviewAction == .requestChanges
                            ? "Request changes on linked open PRs"
                            : "Approve linked open PRs",
                        isOn: $prReview
                    )
                    if prReview {
                        TextField(
                            config.prReviewAction.requiresComment
                                ? "Review comment (required)"
                                : "Approval comment (optional)",
                            text: $prReviewComment,
                            axis: .vertical
                        )
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(2...4)
                        .padding(.leading, 20)
                    }
                }
                if config.allowsPRMerge {
                    Toggle("Merge linked open PRs via \(config.prMergeMethod)", isOn: $prMerge)
                }
                if config.prResolveThreads == .always {
                    Toggle("Resolve open review conversations", isOn: $prResolveThreads)
                }
                if config.enablePRAssigneeSync {
                    Toggle("Sync Jira Assignee to PR (only when PR Assignee is blank)", isOn: $prSyncAssignee)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !checkedKeys.isEmpty && !selectedTransitionName.isEmpty && missingRequirements.isEmpty
    }

    /// The same required-field gate the single-issue dialog uses. This dialog renders the same
    /// prompt config's fields and submits through the same `config.fieldUpdates`, so without this a
    /// bulk move sends an empty required picker into the refusal the gate exists to prevent.
    ///
    /// Manual flags only — no `jiraRequiredFieldIds`. Jira's own flags are per-issue metadata and a
    /// bulk move spans many issues; fetching them for each one would put a round trip per ticket in
    /// front of the dialog. The manual half needs no network, and it is the half that expresses the
    /// workflow-validator rules a bulk move is most likely to trip.
    private var missingRequirements: [String] {
        guard let config = matchingPromptConfig else { return [] }
        var problems: [String] = []
        if currentPRChoices.reviewBlockedForEmptyComment {
            problems.append("Write a review comment — GitHub rejects a request-changes review without one.")
        }
        return problems + config.missingRequirements(
            selectedUserCount: pickedUsers.count,
            textValue: freeText,
            selectValue: selectValue,
            jiraRequiredFieldIds: []
        )
    }

    // MARK: - State transitions

    private func applyFromStatusChange() {
        // Default the in-status issues to checked, minus the backlog ones — see `backlogOnlyKeys`.
        checkedKeys = BulkMoveDialog.autoCheckedKeys(
            inStatus: issuesInFromStatus, backlogOnly: backlogOnlyKeys
        )
        selectedTransitionName = ""
        transitionSelectionIsDefault = true
        pickedUsers = []
        userSelectionOrigin = .untouched
        assignableUsers = []
        // A load already pivoted on the previous status's issue must not land on this one — see
        // `assignableUsersRequest`.
        assignableUsersRequest += 1
        loadingUsers = false
        userFilter = ""
        freeText = ""
        selectValue = ""
        loadTransitionsForChecked()
        // Sync, after the loads: whatever is already cached can be defaulted right now, and the
        // ones still in flight come back through the completion above.
        applyDefaultSelectionIfNeeded()
    }

    private func loadTransitionsForChecked() {
        for key in checkedKeys {
            fetchTransitionsIfNeeded(for: key)
        }
    }

    private func fetchTransitionsIfNeeded(for key: String) {
        if transitionsByIssue[key] != nil { return }
        if fetchingFor.contains(key) { return }
        fetchingFor.insert(key)
        client.getTransitionsByIssueKey(issueKey: key) { transitions in
            AppDelegate.rememberTransitionNames(transitions.map(\.name))
            DispatchQueue.main.async {
                self.transitionsByIssue[key] = transitions
                self.fetchingFor.remove(key)
                // Once we have a default-able transition list, pre-pick the "next logical" one.
                self.applyDefaultSelectionIfNeeded()
                // Belt and braces with the `selectedTransitionName` onChange: this fires when a
                // fetch completion resolves the default, that fires when the picker's value moves,
                // and which one covers a given path depends on whether the lists were already
                // cached. Silently losing the preselect is worse than resolving it twice — and
                // running twice is safe only because of `loadingUsers` and `assignableUsersRequest`,
                // not because either call is idempotent on its own.
                self.loadUsersAndPreselectIfNeeded()
            }
        }
    }

    /// The statuses present in a set of issues, in the user's configured order. Pure, and shared by
    /// the from-picker and the opening pick so the two cannot order things differently.
    static func orderedStatuses(_ issues: [Issue], order: [String]) -> [String] {
        let position: (String) -> Int = { name in
            order.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) ?? Int.max
        }
        return Set(issues.map { $0.fields.status.name }).sorted { lhs, rhs in
            let lp = position(lhs)
            let rp = position(rhs)
            if lp != rp { return lp < rp }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// The status the dialog opens on, or nil when there is nothing to open on.
    ///
    /// **Computed over the main-list rows only.** The project backlog must not decide which view
    /// the dialog lands in. On any order that puts the backlog's status early (a typical one runs
    /// Reopened, To Do, In Progress, …) counting backlog rows would make that status the opening
    /// view whenever the ones before it are empty — so the status the dialog has always opened on
    /// would silently change. The backlog's status is still offered by the picker; it just is not
    /// landed on.
    ///
    /// The fallback to the full candidate list covers the one case where the backlog may decide it:
    /// the main list is empty, and opening on nothing while there are backlog rows to move is worse.
    ///
    /// This filters *rows* by where they came from, never *statuses* by name — the distinction
    /// matters. A main list that legitimately holds the user's own tickets in the backlog's status
    /// makes that status eligible and possibly first, exactly as today; nothing here suppresses it.
    static func initialFromStatus(
        candidates: [Issue], backlogOnly: Set<String>, order: [String]
    ) -> String? {
        let mainList = candidates.filter { !backlogOnly.contains($0.key) }
        return orderedStatuses(mainList, order: order).first
            ?? orderedStatuses(candidates, order: order).first
    }

    /// The keys checked for the user when a from-status settles.
    ///
    /// **All of the status's rows or none of them, never a mixture.** A status the TODO backlog
    /// feeds starts entirely unchecked — including the rows that came from the main list and are
    /// already the user's own. Holding only the backlog rows back would open this dialog on a
    /// half-checked list whose two halves differ by which of two JQL searches answered, which is
    /// not visible from the UI and is exactly the state where someone hits Select all or Return
    /// without reading it. Unchecked is also the gesture the feature is for: you grab the ones you
    /// want. Every other status keeps the existing auto-check untouched.
    ///
    /// Keyed off the backlog rather than off a status named "To Do": status names belong to the
    /// user's workflow and nothing else in this app hard-codes one. So the rule generalises, and the
    /// general form is the one to hold in mind — **any** status the TODO query feeds stops
    /// auto-checking, not only the status a single-status query happens to name. A TODO JQL scoped
    /// by something other than status (`assignee is EMPTY AND project = ABC`, which the Preferences
    /// copy invites) will therefore hold back every status its rows land in. That is the intended
    /// reading, not an accident of a one-status query: what makes a status unsafe to pre-tick is
    /// containing rows the user did not put there, whatever its name.
    ///
    /// It fails safe in either direction — fewer boxes ticked, never more.
    ///
    /// A backlog search that failed or has not answered leaves `backlogOnly` empty, so that status
    /// auto-checks as it did before this feature. There are no unselected backlog rows in the list
    /// to protect against, and `backlogNotice` is already saying the list is short.
    static func autoCheckedKeys(inStatus: [Issue], backlogOnly: Set<String>) -> Set<String> {
        let keys = Set(inStatus.map(\.key))
        return keys.isDisjoint(with: backlogOnly) ? keys : []
    }

    private func defaultTransitionName() -> String {
        BulkMoveDialog.defaultTransitionName(
            fromStatus: fromStatus,
            statusOrder: statusOrder.map(\.name),
            available: availableTransitions
        )
    }

    /// The transition that moves an issue to the next status in the user's configured order — the
    /// "next logical" move out of `fromStatus` — or `""` when there isn't one.
    ///
    /// Matched on each transition's **target status**, not its name. A workflow names transitions
    /// for the action and statuses for the state, so "Ready for Review" is what moves an issue to
    /// "Review and Test": comparing the two strings only ever matched where a workflow happened to
    /// name them alike, and otherwise fell through.
    ///
    /// No match selects nothing, deliberately. What this replaced fell back to the
    /// alphabetically-first available transition, and this dialog applies its choice to every
    /// checked issue at once — out of "In Progress" that arbitrary pick was "Force Close", and out
    /// of "QA" it was "Done - Release Not Required". Both close tickets. An absent default costs
    /// one click; a wrong one is not recoverable in bulk.
    ///
    /// Only the immediately-next status, never scanning further ahead: a forward scan past an
    /// unreachable neighbour walks toward the terminal status and finds exactly the closing
    /// transition this exists to stop selecting.
    static func defaultTransitionName(
        fromStatus: String,
        statusOrder: [String],
        available: [Transition]
    ) -> String {
        guard
            let fromIdx = statusOrder.firstIndex(where: {
                $0.caseInsensitiveCompare(fromStatus) == .orderedSame
            }),
            fromIdx + 1 < statusOrder.count
        else { return "" }

        let next = statusOrder[fromIdx + 1]
        return available.first {
            $0.to?.name.caseInsensitiveCompare(next) == .orderedSame
        }?.name ?? ""
    }

    /// Re-resolves the picker against the current intersection.
    ///
    /// Called from every place the intersection can change rather than only from the fetch
    /// completion: with every checked issue's transition list already cached no request is made,
    /// so no completion fires and the default would never be applied at all.
    private func applyDefaultSelectionIfNeeded() {
        let resolved = BulkMoveDialog.resolvedSelection(
            current: selectedTransitionName,
            isDefault: transitionSelectionIsDefault,
            available: availableTransitions,
            fromStatus: fromStatus,
            statusOrder: statusOrder.map(\.name)
        )
        selectedTransitionName = resolved.name
        transitionSelectionIsDefault = resolved.isDefault
    }

    /// What the picker should hold after the available set changes, and whether that is still an
    /// auto-applied default.
    ///
    /// A selection still on offer is left alone, whoever made it. Once it is not on offer, the
    /// answer depends on who chose it: a default is replaced by the new default, while the user's
    /// own pick clears to nothing. Substituting a different transition for one the user chose would
    /// leave Submit armed with a value they never selected, across every checked issue — and the
    /// pick they lost may have been deliberate, including a closing one they actually wanted.
    static func resolvedSelection(
        current: String,
        isDefault: Bool,
        available: [Transition],
        fromStatus: String,
        statusOrder: [String]
    ) -> (name: String, isDefault: Bool) {
        if available.contains(where: { $0.name == current }) { return (current, isDefault) }
        guard isDefault else { return ("", false) }
        return (
            defaultTransitionName(
                fromStatus: fromStatus, statusOrder: statusOrder, available: available
            ),
            true
        )
    }

    /// Re-resolves the user picker after the selected transition changes.
    ///
    /// Same provenance rule the transition itself follows (see `resolvedSelection`): a preselect the
    /// dialog applied is dropped, because it named people for the *previous* prompt config's field
    /// and carrying it over would arm the new transition's field with them. A pick the user made
    /// themselves is kept — it was a decision about people, and it also blocks the new preselect
    /// below, so a deliberate choice is never overwritten.
    private func applyTransitionChange() {
        if userSelectionOrigin == .preselect {
            pickedUsers = []
            userSelectionOrigin = .untouched
        }
        loadUsersAndPreselectIfNeeded()
    }

    /// Loads the assignable users for the selected transition's user field, if it has one, and
    /// applies the preselect. Re-uses whatever is already loaded rather than re-fetching.
    private func loadUsersAndPreselectIfNeeded() {
        guard let config = matchingPromptConfig, config.hasUserField else { return }
        if assignableUsers.isEmpty {
            loadAssignableUsers()   // applies the preselect from its own completion
        } else {
            applyUserPreselectIfNeeded()
        }
    }

    private func loadAssignableUsers() {
        guard !loadingUsers else { return }
        // Sorted, for the reason `availableTransitions` sorts: `Set.first` is not stable across
        // runs, and an arbitrary pivot means an arbitrary user list — which decides whether the
        // preselect below finds itself a row to light up.
        guard let pivot = checkedKeys.sorted().first else { return }
        assignableUsersRequest += 1
        let request = assignableUsersRequest
        loadingUsers = true
        client.getAssignableUsers(issueKey: pivot) { result in
            DispatchQueue.main.async {
                // Superseded — a from-status change, or a newer load — so this answer describes a
                // pivot that is no longer the one on screen. Dropping it is the point.
                guard request == self.assignableUsersRequest else { return }
                self.loadingUsers = false
                if case .success(let users) = result {
                    self.assignableUsers = users
                    // Every assignment to `assignableUsers` has to be followed by this, or a
                    // selection made before the list arrived loses the row that shows it.
                    self.keepPickedUsersVisible()
                    // After the list, never before: `pickedUsers` is a `Set<JiraUser>` and the rows
                    // test membership by hash, so the preselect has to be mapped onto the instance
                    // that is actually in the list or the checkbox stays empty while the field is
                    // armed. Same reason `TransitionDialog.applyPrefill` maps.
                    self.applyUserPreselectIfNeeded()
                }
            }
        }
    }

    /// Keeps every picked user on screen, selected rows first.
    ///
    /// `getAssignableUsers` is paged and pivots on one issue, so a legitimate account can be absent
    /// from what it returns. A selection with no row to show it is the worst state this dialog can
    /// reach: the field is armed with a person the user cannot see and cannot untick, across every
    /// checked issue, while the requirement banner reports it as satisfied. Mirrors
    /// `TransitionDialog.arrangeSelectedFirst`.
    private func keepPickedUsersVisible() {
        let pickedInList = assignableUsers.filter { pickedUsers.contains($0) }
        let pickedNotInList = pickedUsers.filter { !assignableUsers.contains($0) }
        let rest = assignableUsers.filter { !pickedUsers.contains($0) }
        assignableUsers = pickedInList + Array(pickedNotInList) + rest
    }

    /// Preselects the current user in the picker when the prompt config asks for it.
    ///
    /// **`.currentUser` only.** `.assignee` and `.fieldValue` both answer from *one* issue, and this
    /// dialog writes a single selection to every checked issue — prefilling from an arbitrary member
    /// of the batch would arm that one ticket's people onto all the others. `.currentUser` is the
    /// only preselect whose answer is the same for every issue in the batch, so it is the only one
    /// that means anything here. A prompt configured either other way gets no preselect and, when
    /// its field is required, keeps Submit disabled until the user picks — which is the correct
    /// outcome for a per-issue value, not a gap.
    private func applyUserPreselectIfNeeded() {
        guard let config = matchingPromptConfig,
              config.hasUserField,
              config.userFieldPreselect == .currentUser,
              userSelectionOrigin == .untouched
        else { return }
        client.getCurrentUser { me in
            DispatchQueue.main.async {
                guard let me else { return }
                // Re-checked against live state: `/myself` is a round trip, and the transition, the
                // checked set or the user's own pick can all have moved while it was in flight.
                // `.untouched` rather than `pickedUsers.isEmpty`: the reload-users button also
                // routes here, and an empty picker the user emptied themselves must stay empty.
                guard let live = self.matchingPromptConfig,
                      live.hasUserField,
                      live.userFieldPreselect == .currentUser,
                      self.userSelectionOrigin == .untouched
                else { return }
                self.pickedUsers = [self.assignableUsers.first(where: { $0.isSame(as: me) }) ?? me]
                self.userSelectionOrigin = .preselect
                // Guarantees the row exists even when `/myself` is not in the returned page.
                self.keepPickedUsersVisible()
            }
        }
    }

    // MARK: - Submit

    private func submit() {
        guard !submitting, canSubmit else { return }
        submitting = true
        progress = "Starting…"

        let keys = Array(checkedKeys)
        let transitionName = selectedTransitionName
        let config = matchingPromptConfig

        let updates = config?.fieldUpdates(
            users: Array(pickedUsers),
            freeText: freeText,
            selectValue: selectValue
        ) ?? []
        let includeComment = config?.includeComment ?? true
        let effectiveComment: String? = (includeComment && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? MentionText.wikiBody(text: comment, mentions: mentions) : nil

        var index = 0
        var successfulKeys: [String] = []
        var failures: [(key: String, reason: String?)] = []
        let prActions = currentPRChoices
        // Snapshot the shared user list + mirror flag before submit — the dialog's @State
        // could otherwise be reset by the time the last callback fires.
        let sharedUsers = Array(pickedUsers)
        let shouldMirror = showGithubMirrorCheckbox && updateGithub

        func processNext() {
            if index >= keys.count {
                onSubmit(successfulKeys, sharedUsers, failures, shouldMirror, prActions)
                return
            }
            let key = keys[index]
            progress = "Transitioning \(index + 1) of \(keys.count): \(key)"
            guard let transitions = transitionsByIssue[key],
                  let target = transitions.first(where: { $0.name == transitionName }) else {
                failures.append((key: key, reason: "\(transitionName) is not available on this issue"))
                index += 1
                processNext()
                return
            }
            client.transitionIssue(
                issueKey: key,
                to: target.id,
                comment: effectiveComment,
                fieldUpdates: updates
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        successfulKeys.append(key)
                    case .failed(let message, let fieldsAlreadyWritten):
                        // Jira's own words rather than a count. `fieldsAlreadyWritten` matters: the field
                        // PUT precedes the transition POST, so a refusal can leave values persisted.
                        let suffix = fieldsAlreadyWritten ? " (field values were saved)" : ""
                        failures.append((key: key, reason: (message ?? "Jira gave no reason") + suffix))
                    }
                    index += 1
                    processNext()
                }
            }
        }

        processNext()
    }
}
