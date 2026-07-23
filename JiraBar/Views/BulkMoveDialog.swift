import SwiftUI

/// Move multiple issues to a new status in one shot.
///
/// Flow: pick a "from" status (only statuses that currently have issues are listed) → pick issues
/// from that status with checkboxes → pick a "to" status from the intersection of transitions
/// every selected issue supports → fill in any prompt fields (reviewers / QA result / resolution
/// etc., per the matching TransitionPromptConfig) and a shared comment → submit. Each issue gets
/// its own transition POST (with the same field payload), serially, with a progress indicator.
struct BulkMoveDialog: View {
    let issues: [Issue]
    let transitionPrompts: [TransitionPromptConfig]
    let statusOrder: [StatusDisplay]
    /// Returns true when the given Jira user-field id qualifies for the GitHub mirror
    /// (correct field id, token present, mapping path set). Passed in as a closure so the
    /// dialog stays ignorant of Defaults / Keychain plumbing.
    let showMirrorFor: (String) -> Bool
    /// Reports the per-key outcome so the caller can fan out the GitHub mirror when
    /// `updateGithub` is true. `users` is the shared reviewer selection applied to every
    /// successfully transitioned issue.
    let onSubmit: (_ successfulKeys: [String], _ users: [JiraUser], _ failureCount: Int, _ updateGithub: Bool) -> Void
    let onCancel: () -> Void

    @State private var fromStatus: String = ""
    @State private var checkedKeys: Set<String> = []
    /// issueKey -> transitions available on that issue (fetched lazily).
    @State private var transitionsByIssue: [String: [Transition]] = [:]
    @State private var fetchingFor: Set<String> = []
    @State private var selectedTransitionName: String = ""

    // Per-prompt-config field state — only the ones the matching prompt enables actually render.
    @State private var comment: String = ""
    @State private var pickedUsers: Set<JiraUser> = []
    @State private var assignableUsers: [JiraUser] = []
    @State private var userFilter: String = ""
    @State private var freeText: String = ""
    @State private var selectValue: String = ""

    @State private var submitting: Bool = false
    @State private var progress: String = ""
    @State private var updateGithub: Bool = true

    private let client = JiraClient()

    // MARK: - Derived

    private func sortPosition(for name: String) -> Int {
        statusOrder.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? Int.max
    }

    private var availableFromStatuses: [String] {
        let names = Set(issues.map { $0.fields.status.name })
        return names.sorted { lhs, rhs in
            let lp = sortPosition(for: lhs)
            let rp = sortPosition(for: rhs)
            if lp != rp { return lp < rp }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
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
        for key in checkedKeys {
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
            header

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
                    Text(progress).font(.footnote).foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(16)
        .frame(width: 600, height: 700)
        .onAppear {
            // Pre-pick the first status that has issues.
            if fromStatus.isEmpty, let first = availableFromStatuses.first {
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
                    }
                    .controlSize(.small)
                    Button("Clear") { checkedKeys.removeAll() }
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
            }
        }
    }

    private func issueRow(_ issue: Issue) -> some View {
        let isChecked = checkedKeys.contains(issue.key)
        return HStack(spacing: 8) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundColor(isChecked ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(issue.fields.summary).lineLimit(1)
                Text(issue.key).font(.caption).foregroundColor(.secondary)
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
            // If the new selection invalidates the chosen transition, clear it.
            if !availableTransitions.contains(where: { $0.name == selectedTransitionName }) {
                selectedTransitionName = ""
            }
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
                Picker("", selection: $selectedTransitionName) {
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
            TextField("", text: $comment, axis: .vertical)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .lineLimit(3...6)
        }
    }

    private var footer: some View {
        HStack {
            Button("") { submit() }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                .disabled(submitting || !canSubmit)

            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(submitting ? "Moving…" : "Move \(checkedKeys.count) issue\(checkedKeys.count == 1 ? "" : "s")") {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(submitting || !canSubmit)
        }
    }

    private var canSubmit: Bool {
        !checkedKeys.isEmpty && !selectedTransitionName.isEmpty
    }

    // MARK: - State transitions

    private func applyFromStatusChange() {
        let inStatus = issuesInFromStatus
        // Default all in-state issues to checked when the from-status changes.
        checkedKeys = Set(inStatus.map(\.key))
        selectedTransitionName = ""
        pickedUsers = []
        assignableUsers = []
        userFilter = ""
        freeText = ""
        selectValue = ""
        loadTransitionsForChecked()
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
            DispatchQueue.main.async {
                self.transitionsByIssue[key] = transitions
                self.fetchingFor.remove(key)
                // Once we have a default-able transition list, pre-pick the "next logical" one.
                if self.selectedTransitionName.isEmpty {
                    self.selectedTransitionName = self.defaultTransitionName()
                }
                // If a user-picker section becomes relevant, load assignable users for it once.
                if let config = self.matchingPromptConfig, config.hasUserField, self.assignableUsers.isEmpty {
                    self.loadAssignableUsers()
                }
            }
        }
    }

    /// Picks the next status in the user's status-order list as the default target, when present
    /// in the intersection. Falls back to the first valid transition.
    private func defaultTransitionName() -> String {
        let transitions = availableTransitions
        guard !transitions.isEmpty else { return "" }
        if let fromIdx = statusOrder.firstIndex(where: { $0.name.caseInsensitiveCompare(fromStatus) == .orderedSame }),
           fromIdx + 1 < statusOrder.count {
            let nextName = statusOrder[fromIdx + 1].name
            if let match = transitions.first(where: { $0.name.caseInsensitiveCompare(nextName) == .orderedSame }) {
                return match.name
            }
        }
        return transitions.first?.name ?? ""
    }

    private func loadAssignableUsers() {
        guard let pivot = checkedKeys.first else { return }
        client.getAssignableUsers(issueKey: pivot) { result in
            DispatchQueue.main.async {
                if case .success(let users) = result {
                    self.assignableUsers = users
                }
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

        var updates: [JiraClient.TransitionFieldUpdate] = []
        if let config {
            if config.hasUserField, !pickedUsers.isEmpty {
                updates.append(.users(
                    fieldId: config.userFieldId.trimmingCharacters(in: .whitespaces),
                    users: Array(pickedUsers),
                    multi: config.userFieldAllowsMultiple
                ))
            }
            if config.hasTextField, !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updates.append(.text(
                    fieldId: config.textFieldId.trimmingCharacters(in: .whitespaces),
                    value: freeText
                ))
            }
            if config.hasSelectField, !selectValue.trimmingCharacters(in: .whitespaces).isEmpty {
                updates.append(.select(
                    fieldId: config.selectFieldId.trimmingCharacters(in: .whitespaces),
                    value: selectValue
                ))
            }
        }
        let includeComment = config?.includeComment ?? true
        let effectiveComment: String? = (includeComment && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? comment : nil

        var index = 0
        var successfulKeys: [String] = []
        var failureCount = 0
        // Snapshot the shared user list + mirror flag before submit — the dialog's @State
        // could otherwise be reset by the time the last callback fires.
        let sharedUsers = Array(pickedUsers)
        let shouldMirror = showGithubMirrorCheckbox && updateGithub

        func processNext() {
            if index >= keys.count {
                onSubmit(successfulKeys, sharedUsers, failureCount, shouldMirror)
                return
            }
            let key = keys[index]
            progress = "Transitioning \(index + 1) of \(keys.count): \(key)"
            guard let transitions = transitionsByIssue[key],
                  let target = transitions.first(where: { $0.name == transitionName }) else {
                failureCount += 1
                index += 1
                processNext()
                return
            }
            client.transitionIssue(
                issueKey: key,
                to: target.id,
                comment: effectiveComment,
                fieldUpdates: updates
            ) { success in
                DispatchQueue.main.async {
                    if success {
                        successfulKeys.append(key)
                    } else {
                        failureCount += 1
                    }
                    index += 1
                    processNext()
                }
            }
        }

        processNext()
    }
}
