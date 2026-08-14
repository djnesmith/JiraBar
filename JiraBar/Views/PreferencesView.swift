import SwiftUI
import Defaults
import UniformTypeIdentifiers

struct PreferencesView: View {
    @Default(.instanceType) var instanceType

    var body: some View {
        VStack(spacing: 0) {
            // Segmented toggle — the primary switch between Cloud and Server mode
            Picker("", selection: $instanceType) {
                Text("Jira Cloud").tag(JiraInstanceType.cloud)
                Text("Self-Hosted / Server").tag(JiraInstanceType.server)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top)

            Divider()
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 0) {
                    if instanceType == .cloud {
                        CloudPreferencesView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ServerPreferencesView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    StatusOrderSection()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 12)

                    Divider()

                    UserFieldShortcutsSection()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 12)

                    Divider()

                    TransitionPromptsSection()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 12)

                    Divider()

                    SettingsBackupSection()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                }
                // Small trailing inset keeps the macOS scrollbar off the section content.
                .padding(.trailing, 12)
            }
        }
        .frame(width: 950, height: 760)
    }
}

// MARK: - Cloud

private struct CloudPreferencesView: View {
    @Default(.jiraUsername) var jiraUsername
    @Default(.orgName) var orgName
    @Default(.jql) var jql
    @Default(.refreshRate) var refreshRate
    @Default(.maxResults) var maxResults

    @FromKeychain(.jiraToken) var jiraToken

    @StateObject private var jiraTokenValidator = JiraTokenValidator()
    @State private var orgNameState: String = ""

    var body: some View {
        HStack {
            Spacer()
            Form {
                TextField("Email:", text: $jiraUsername)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                LabeledContent("Org Name:") {
                    HStack {
                        Text("https://")
                            .foregroundColor(.secondary)

                        DebounceTextField(label: "", value: $orgNameState) { _ in
                            orgNameState = orgNameState.trimmingCharacters(in: .whitespaces)
                            orgName = orgNameState
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onAppear {
                            orgNameState = orgName
                        }

                        Text(".atlassian.net")
                            .foregroundColor(.secondary)
                    }
                }

                LabeledContent("API Token:") {
                    HStack {
                        SecureField("", text: $jiraToken)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Button("Test") {
                            jiraTokenValidator.validate()
                        }

                        Image(systemName: jiraTokenValidator.iconName)
                            .foregroundColor(jiraTokenValidator.iconColor)
                    }
                }

                Text("Generate an [API Token](https://id.atlassian.com/manage/api-tokens) in your Atlassian account settings.")
                    .font(.footnote)

                Divider()

                QuerySection(jql: $jql, maxResults: $maxResults, refreshRate: $refreshRate)
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: - Server

private struct ServerPreferencesView: View {
    @Default(.jiraServerUsername) var jiraUsername
    @Default(.jiraHost) var jiraHost
    @Default(.serverAuthType) var serverAuthType
    @Default(.jql) var jql
    @Default(.refreshRate) var refreshRate
    @Default(.maxResults) var maxResults

    @FromKeychain(.jiraServerToken) var jiraToken

    @StateObject private var jiraTokenValidator = JiraTokenValidator()
    @State private var jiraHostState: String = ""

    var body: some View {
        HStack {
            Spacer()
            Form {
                LabeledContent("Jira URL:") {
                    DebounceTextField(label: "", value: $jiraHostState) { _ in
                        jiraHostState = jiraHostState.trimmingCharacters(in: .whitespaces)
                        jiraHost = jiraHostState
                    }
                    .labelsHidden()
                    .frame(width: 280)
                    .onAppear {
                        jiraHostState = jiraHost
                    }
                }

                Picker("Auth Type:", selection: $serverAuthType) {
                    Text("Personal Access Token").tag(JiraServerAuthType.pat)
                    Text("Username & Password").tag(JiraServerAuthType.basic)
                }
                .frame(width: 300)
                .onChange(of: serverAuthType) { _ in
                    jiraTokenValidator.setLoading()
                }

                if serverAuthType == .basic {
                    TextField("Username:", text: $jiraUsername)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                LabeledContent(serverAuthType == .pat ? "Token:" : "Password:") {
                    HStack {
                        SecureField("", text: $jiraToken)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Button("Test") {
                            jiraTokenValidator.validate()
                        }

                        Image(systemName: jiraTokenValidator.iconName)
                            .foregroundColor(jiraTokenValidator.iconColor)
                    }
                }

                if serverAuthType == .pat {
                    Text("Generate a Personal Access Token in your Jira profile settings. Available on Jira Server 8.14+ and Data Center.")
                        .font(.footnote)
                } else {
                    Text("Basic authentication using your Jira username and password. For older Jira Server instances.")
                        .font(.footnote)
                }

                Divider()

                QuerySection(jql: $jql, maxResults: $maxResults, refreshRate: $refreshRate)
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: - Shared query/poll section

private struct QuerySection: View {
    @Binding var jql: String
    @Binding var maxResults: String
    @Binding var refreshRate: Int
    @Default(.dashboardURL) var dashboardURL
    @Default(.myDashboardURL) var myDashboardURL
    @Default(.flagFieldId) var flagFieldId
    @Default(.rankFieldId) var rankFieldId
    @Default(.allIssuesJQL) var allIssuesJQL
    @FromKeychain(.gitHubToken) var gitHubToken
    @Default(.githubSearchOrgs) var githubSearchOrgs
    @Default(.jiraGithubUserMapPath) var jiraGithubUserMapPath
    @Default(.jiraGithubUserMapBookmark) var jiraGithubUserMapBookmark
    @Default(.githubPRReviewerJiraFieldId) var githubPRReviewerJiraFieldId
    @Default(.showMyPRsSection) var showMyPRsSection
    @Default(.todoJQL) var todoJQL
    @Default(.recentlyClosedJQL) var recentlyClosedJQL
    @Default(.recentlyClosedMaxResults) var recentlyClosedMaxResults
    @Default(.showRecentlyApprovedSection) var showRecentlyApprovedSection
    @Default(.recentlyApprovedMaxResults) var recentlyApprovedMaxResults
    @Default(.todoMaxResults) var todoMaxResults

    var body: some View {
        TextField("JQL Query:", text: $jql)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Use advanced search in Jira to create a JQL query and then paste it here.")
            .font(.footnote)
        TextField("All-Issues JQL:", text: $allIssuesJQL)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Adds an Open All Issues menu entry under Open Search results. Use a broader query (e.g. include closed tickets) for an everything-I've-touched view.")
            .font(.footnote)
        TextField("TODO JQL:", text: $todoJQL)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Adds a TODO entry whose submenu lists these tickets, each with the same submenu it gets in the main list. Meant for a backlog view your main JQL can't show — e.g. status = \"To Do\" ORDER BY Rank ASC for the whole column, not just your own tickets. Set the Rank field id below and the submenu follows board order.")
            .font(.footnote)
        TextField("TODO Max Results:", text: $todoMaxResults)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .frame(width: 120)
        TextField("Recently Closed JQL:", text: $recentlyClosedJQL)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Adds a Recently Closed entry under TODO listing finished tickets, each showing its PRs including merged and closed ones. No transitions or editing — it's a history rollup. Empty switches it off. Order by statusCategoryChangedDate rather than resolutiondate, which many workflows never populate. Add \"AND project in (ABC, DEF)\" to keep other projects' idea of \"Done\" out.")
            .font(.footnote)
        TextField("Recently Closed Max Results:", text: $recentlyClosedMaxResults)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .frame(width: 120)
        Toggle("Show Recently Approved PRs section", isOn: $showRecentlyApprovedSection)
        Text("The PRs you most recently approved, newest-updated first, scoped by GitHub Search Orgs above. Requires a GitHub Token. Built on first open — it costs a search plus one lookup per candidate, because GitHub cannot search on \"I approved it\" and the approval has to be checked per PR.")
            .font(.footnote)
        TextField("Recently Approved PRs Max Results:", text: $recentlyApprovedMaxResults)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .frame(width: 120)
        TextField("Max Results:", text: $maxResults)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .frame(width: 120)
        TextField("Dashboard URL:", text: $dashboardURL)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Adds an Open Dashboard entry to the menu. Accepts a full URL or a path that's appended to your Jira base.")
            .font(.footnote)
        TextField("My Dashboard URL:", text: $myDashboardURL)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Adds an Open My Dashboard entry below the first dashboard — same format. Handy for a board view filtered to just your work.")
            .font(.footnote)
        TextField("Flag field id:", text: $flagFieldId)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Field id for Jira's Flagged custom field (commonly customfield_10021 on Cloud). When set, an Add Flag entry appears in each ticket's submenu.")
            .font(.footnote)
        TextField("Rank field id:", text: $rankFieldId)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Lexorank field id (commonly customfield_10019 on Cloud). When set, tickets inside each status group are sorted to match your board order.")
            .font(.footnote)
        SecureField("GitHub Token:", text: $gitHubToken)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. GitHub PAT with pull-request read scope. When set, each linked PR gets a third line with review decision, unresolved-thread count, and CI state. Open PRs whose CI failed are labeled \"error\" in red.")
            .font(.footnote)
        TextField("GitHub Search Orgs:", text: $githubSearchOrgs)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Comma-separated GitHub orgs (e.g. \"acme, acme-labs\"). When Jira's dev-status API returns no PRs for a ticket, JiraBar falls back to searching these orgs for PRs whose title contains the ticket key. Requires a GitHub Token.")
            .font(.footnote)
        Toggle("Show PRs Without Tickets section", isOn: $showMyPRsSection)
        Text("Shows your open GitHub PRs — assigned to you or awaiting your review — that aren't tied to any Jira ticket (no issue key in the title or branch, and not linked to a visible ticket). Requires a GitHub Token; scoped by GitHub Search Orgs when set.")
            .font(.footnote)
        LabeledContent("Jira → GitHub Map:") {
            HStack {
                TextField("", text: $jiraGithubUserMapPath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url {
                        jiraGithubUserMapPath = url.path
                        // Capture a security-scoped bookmark so a sandboxed launch can still
                        // read the file next time. Silently keep the raw path only when the
                        // bookmark can't be created (rare — usually a permission edge case).
                        if let data = try? url.bookmarkData(
                            options: [.withSecurityScope],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            jiraGithubUserMapBookmark = data
                        }
                    }
                }
            }
        }
        Text("Optional. Path to a JSON file mapping Jira accountIds to GitHub logins. When set alongside a GitHub Token and the PR Reviewer field id below, the reviewer-picker dialogs offer a checkbox to also assign you and add the selected users as reviewers on any linked open PR.")
            .font(.footnote)
        TextField("PR Reviewer field id:", text: $githubPRReviewerJiraFieldId)
            .textFieldStyle(RoundedBorderTextFieldStyle())
        Text("Optional. Jira custom-field id whose users mirror to GitHub PR reviewers — usually a per-install \"Reviewers\" user-picker field. Only dialogs editing this field show the GitHub mirror checkbox.")
            .font(.footnote)
        Picker("Refresh Rate:", selection: $refreshRate) {
            Text("1 minute").tag(1)
            Text("5 minutes").tag(5)
            Text("10 minutes").tag(10)
            Text("15 minutes").tag(15)
            Text("30 minutes").tag(30)
        }
        .frame(width: 200)
    }
}

// MARK: - Status Display (order + color)

/// Lets the user define the display order and color of status groups in the menu bar.
/// Status names are matched case-insensitively against Jira's `status.name`; anything not in this
/// list falls below, sorted alphabetically. Generic by design — no workflow-specific names live in source.
private struct StatusOrderSection: View {
    @Default(.statusDisplay) var entries

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status Order & Colors").font(.headline)
                Spacer()
                Button {
                    entries.append(StatusDisplay())
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            Text("Order status groups in the menu to match your board and color the headers. Unlisted statuses fall to the bottom.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if entries.isEmpty {
                Text("No statuses configured. Headers are listed alphabetically with the default text color.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("Status name (e.g. \"To Do\")", text: $entries[index].name)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        ColorPicker(
                            "",
                            selection: colorBinding(for: index),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .frame(width: 44)
                        if !entries[index].colorHex.isEmpty {
                            Button {
                                entries[index].colorHex = ""
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Clear color")
                        }
                        Button {
                            entries.swapAt(index, index - 1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        Button {
                            entries.swapAt(index, index + 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == entries.count - 1)
                        Button(role: .destructive) {
                            entries.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// Bridges between the SwiftUI `Color` that ColorPicker wants and the `#RRGGBB` we persist.
    /// Default-shown swatch is white when no color is set; the user picking any color writes hex.
    private func colorBinding(for index: Int) -> Binding<Color> {
        Binding(
            get: {
                Color(statusHex: entries[index].colorHex) ?? .white
            },
            set: { newValue in
                entries[index].colorHex = newValue.statusHex
            }
        )
    }
}

// MARK: - User Field Shortcuts

/// Lets the user define menu entries for editing user-picker fields on the active issue
/// (e.g. "Change Assignee", "Change Reviewer"). Generic — field ids are user-supplied.
private struct UserFieldShortcutsSection: View {
    @Default(.userFieldShortcuts) var shortcuts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("User Field Shortcuts").font(.headline)
                Spacer()
                Button {
                    shortcuts.append(UserFieldShortcut())
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            Text("Each shortcut shows under \"Add Comment\" in a ticket's submenu and opens a dialog pre-loaded with the current value. Submitting with no users selected clears the field.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shortcuts.isEmpty {
                Text("No shortcuts configured.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                Text("Color = status whose color tints the assigned-user lines under this shortcut. Blank = use the ticket's own status color.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, _ in
                    HStack(spacing: 6) {
                        TextField("Menu label (e.g. \"Change Assignee\")", text: $shortcuts[index].label)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField("Field id", text: $shortcuts[index].fieldId)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 140)
                        TextField("Color from status", text: $shortcuts[index].colorFromStatus)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 130)
                        Toggle("Multi", isOn: $shortcuts[index].allowsMultiple)
                        Button(role: .destructive) {
                            shortcuts.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - Transition Prompts

/// Lets the user define generic prompt dialogs that appear before specific transitions are submitted.
/// Each entry maps a transition name to an optional comment box, an optional user-picker custom field,
/// and an optional free-text custom field — nothing here assumes a particular workflow.
private struct TransitionPromptsSection: View {
    @Default(.transitionPrompts) var prompts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transition Prompts").font(.headline)
                Spacer()
                Button {
                    prompts.append(TransitionPromptConfig())
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            Text("Show a dialog before a transition is submitted. Match on the transition's display name; expose a comment, a user-picker custom field, and/or a free-text custom field.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if prompts.isEmpty {
                Text("No prompts configured. Transitions run immediately.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach($prompts) { $prompt in
                            TransitionPromptRow(prompt: $prompt) {
                                prompts.removeAll { $0.id == prompt.id }
                            }
                            Divider()
                        }
                    }
                    .padding(.trailing, 16)
                }
                .frame(maxHeight: 320)
            }
        }
    }
}

private struct TransitionPromptRow: View {
    @Binding var prompt: TransitionPromptConfig
    let onDelete: () -> Void

    @State private var expanded: Bool = true
    /// Transition names JiraBar has actually seen, used only to warn about a name that can never match.
    @Default(.seenTransitionNames) var seenTransitionNames

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)

                TextField("Transition name (e.g. \"Ready for Review\")", text: $prompt.transitionName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            // The one thing standing between a near-miss name and a prompt that silently never opens.
            if let warning = prompt.unknownTransitionNameWarning(seenNames: seenTransitionNames) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Include comment box", isOn: $prompt.includeComment)

                    GroupBox("User picker (optional)") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Field id (e.g. assignee or customfield_10100)", text: $prompt.userFieldId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            TextField("Label (e.g. Reviewers)", text: $prompt.userFieldLabel)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Toggle("Allow selecting multiple users", isOn: $prompt.userFieldAllowsMultiple)
                            Toggle("Default to current user", isOn: $prompt.userFieldDefaultsToCurrentUser)
                            // Needed even though JiraBar reads Jira's own required flags: a rule
                            // enforced by a workflow validator reports required:false and still
                            // rejects the transition. See TransitionPromptConfig.userFieldRequired.
                            Toggle("Required — block submitting unless at least one is selected",
                                   isOn: $prompt.userFieldRequired)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Text field (optional)") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Custom field id (e.g. customfield_10200)", text: $prompt.textFieldId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            TextField("Label (e.g. QA Result)", text: $prompt.textFieldLabel)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Toggle("Multi-line", isOn: $prompt.textFieldMultiline)
                            Toggle("Required — block submitting unless filled in",
                                   isOn: $prompt.textFieldRequired)
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("Select field (optional)") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Field id (e.g. resolution or customfield_10300)", text: $prompt.selectFieldId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            TextField("Label (e.g. Resolution)", text: $prompt.selectFieldLabel)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Toggle("Required — block submitting unless an option is chosen",
                                   isOn: $prompt.selectFieldRequired)

                            HStack {
                                Text("Options").font(.subheadline)
                                Spacer()
                                Button {
                                    prompt.selectOptions.append(TransitionSelectOption())
                                } label: {
                                    Label("Add option", systemImage: "plus")
                                }
                                .controlSize(.small)
                            }

                            if prompt.selectOptions.isEmpty {
                                Text("Add option rows: label is what users see, value is what's sent to Jira (e.g. 10000 for the Done resolution).")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach($prompt.selectOptions) { $option in
                                    HStack {
                                        TextField("Label", text: $option.label)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                        TextField("Value", text: $option.value)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                            .frame(width: 100)
                                        Button {
                                            prompt.selectOptions.removeAll { $0.id == option.id }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("PR actions (optional)") {
                        VStack(alignment: .leading, spacing: 6) {
                            // One picker, not two checkboxes: a review is either an approval or a
                            // request for changes, never both.
                            Picker("Review linked open PRs:", selection: $prompt.prReviewAction) {
                                Text("Don't review").tag(PRReviewAction.none)
                                Text("Approve").tag(PRReviewAction.approve)
                                Text("Request changes").tag(PRReviewAction.requestChanges)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 320)
                            HStack {
                                Toggle("Auto-merge linked open PRs", isOn: $prompt.enablePRMerge)
                                Picker("Method:", selection: $prompt.prMergeMethod) {
                                    Text("Merge").tag("merge")
                                    Text("Squash").tag("squash")
                                    Text("Rebase").tag("rebase")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 180)
                                .disabled(!prompt.enablePRMerge)
                            }
                            .disabled(prompt.prReviewAction == .requestChanges)
                            Picker("Resolve open review conversations:", selection: $prompt.prResolveThreads) {
                                Text("Never").tag(PRResolveThreadsMode.never)
                                Text("Always").tag(PRResolveThreadsMode.always)
                                Text("Ask when there are any").tag(PRResolveThreadsMode.ask)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 360)
                            Text("Resolves all of them, including other people's. \"Ask\" offers a checkbox in the dialog, unticked, only when the linked PRs actually have open conversations.")
                                .font(.footnote).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Sync Jira Assignee to PR (only when PR Assignee is blank)", isOn: $prompt.enablePRAssigneeSync)
                            Text("Runs after the Jira transition succeeds. Requires a GitHub Token.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if prompt.prReviewAction == .requestChanges {
                                Text("Request changes needs a comment — GitHub rejects a request-changes review without one, so the dialog won't submit until you write one. Merging is unavailable in this mode.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if prompt.allowsPRMerge {
                                Text("PRs whose repos disallow the chosen merge method are skipped with a summary notification.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Backup

/// Full export/import of all settings (everything in Defaults). Secrets (API tokens) stay in
/// Keychain and are NOT included in the JSON — users re-enter the token on the new machine.
private struct SettingsBackupSection: View {
    @State private var message: String?
    @State private var messageIsError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Settings Backup").font(.headline)
                Spacer()
                Button {
                    importAll()
                } label: {
                    Label("Import All…", systemImage: "square.and.arrow.down")
                }
                Button {
                    exportAll()
                } label: {
                    Label("Export All…", systemImage: "square.and.arrow.up")
                }
            }

            Text("Save every preference to a JSON file or restore from one. The Jira API token is not included — you'll re-enter it after import.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(messageIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "jirabar-settings.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(AppSettings.snapshot())
            try data.write(to: url)
            message = "Exported to \(url.lastPathComponent)."
            messageIsError = false
        } catch {
            message = "Export failed: \(error.localizedDescription)"
            messageIsError = true
        }
    }

    private func importAll() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            decoded.apply()
            message = "Imported from \(url.lastPathComponent). Re-enter your API token if this is a new machine."
            messageIsError = false
        } catch {
            message = "Import failed: \(error.localizedDescription)"
            messageIsError = true
        }
    }
}

#Preview {
    PreferencesView()
}
