import SwiftUI

/// Choices the user made in the PR-actions section of a transition dialog. Bundled into one
/// struct so `onSubmit` doesn't grow every time we add a knob.
struct PRActionChoices {
    var review: PRReviewAction
    var reviewComment: String
    var merge: Bool
    var mergeMethod: String
    var syncAssignee: Bool

    static let disabled = PRActionChoices(
        review: .none, reviewComment: "", merge: false, mergeMethod: "rebase", syncAssignee: false
    )

    /// Whitespace-only is empty — it satisfies neither the user's intent nor GitHub's
    /// body requirement.
    var trimmedReviewComment: String {
        reviewComment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `event` to POST to the reviews API, or nil when no review should go out — including
    /// when the mode's comment is mandatory (`PRReviewAction.requiresComment`) and blank, which
    /// resolves to nil rather than to a review GitHub would reject.
    var reviewEvent: String? {
        guard let event = review.githubEvent else { return nil }
        if review.requiresComment, trimmedReviewComment.isEmpty { return nil }
        return event
    }

    /// A review was asked for and withheld only because its mandatory comment is blank. The
    /// summary notification has to name that, rather than report it as a failed review.
    var reviewBlockedForEmptyComment: Bool {
        review.requiresComment && trimmedReviewComment.isEmpty
    }

    /// True when at least one PR action would be attempted.
    var hasWork: Bool {
        review != .none || merge || syncAssignee
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
        let assignees: [String]
        let mergeCommitAllowed: Bool
        let squashMergeAllowed: Bool
        let rebaseMergeAllowed: Bool
    }
    @Published var loading: Bool = true
    @Published var openPRs: [LinkedPR] = []
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
    let onSubmit: (String, [JiraUser], String, String, Bool, PRActionChoices, @escaping (Bool) -> Void) -> Void
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
    @State private var showReviewCommentWarning: Bool = false
    @State private var prMerge: Bool = true
    @State private var prMergeMethod: String = "rebase"
    @State private var prSyncAssignee: Bool = true

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

            footer
        }
        .padding(16)
        .frame(width: 520, height: dialogHeight())
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
        }
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

    /// The blocked state: a review whose comment is mandatory, ticked, with nothing typed.
    /// Submitting is refused while this holds — the review is the point of the transition, so
    /// finishing without it would leave the ticket moved and the PR untouched.
    private var reviewCommentMissing: Bool {
        prReview
            && config.prReviewAction.requiresComment
            && prReviewComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                if prReview {
                    TextField(reviewCommentPlaceholder, text: $prReviewComment, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(2...5)
                        .padding(.leading, 20)
                    // Raised by a submit attempt, not on open — an untouched dialog shouldn't
                    // greet you with an error for something you haven't had a chance to type.
                    if showReviewCommentWarning, reviewCommentMissing {
                        Text("GitHub requires a comment on a request-changes review.")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .padding(.leading, 20)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            if config.enablePRAssigneeSync {
                Toggle("Set Jira Assignee as PR Assignee (only when PR Assignee is blank)", isOn: $prSyncAssignee)
            }
        }
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
                .foregroundColor(.secondary)
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
                Text("No assignable users found for \(issueKey).")
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

    private var footer: some View {
        HStack {
            // Invisible companion button: binds ⌘-Return as a dialog-wide submit shortcut.
            // The visible Transition button keeps .defaultAction so Return still works when
            // no text field has focus, but a multi-line TextField swallows Return for newlines,
            // so we need ⌘-Return as an unambiguous submit path.
            HiddenSubmitButton(disabled: submitting) { submit() }

            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(submitting ? "Submitting…" : "Transition") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(submitting)
        }
    }

    private func submit() {
        guard !submitting else { return }
        if reviewCommentMissing {
            showReviewCommentWarning = true
            return
        }
        submitting = true
        let flag = showGithubMirrorCheckbox && updateGithub
        let choices: PRActionChoices
        if config.hasPRActions {
            choices = PRActionChoices(
                review: prReview ? config.prReviewAction : .none,
                reviewComment: prReviewComment,
                merge: config.allowsPRMerge && prMerge,
                mergeMethod: prMergeMethod,
                syncAssignee: config.enablePRAssigneeSync && prSyncAssignee
            )
        } else {
            choices = .disabled
        }
        onSubmit(comment, Array(selectedUsers), freeText, selectedOptionValue, flag, choices) { success in
            if !success { submitting = false }
        }
    }

    // MARK: - Helpers

    private func toggle(_ user: JiraUser) {
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
                    if let me { self.applyPrefill([me]) }
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
    private func applyPrefill(_ candidates: [JiraUser]) {
        guard !candidates.isEmpty else { return }
        let matched: [JiraUser] = candidates.map { candidate in
            availableUsers.first(where: { Self.sameUser($0, candidate) }) ?? candidate
        }
        selectedUsers = Set(matched)
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
            if showReviewCommentWarning, reviewCommentMissing { pr += 20 } // required-comment warning
            if config.allowsPRMerge { pr += 32 }
            if config.enablePRAssigneeSync { pr += 24 }
            h += pr
        }
        return max(h, 220)
    }
}
