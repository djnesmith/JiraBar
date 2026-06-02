import SwiftUI

/// Sheet that lets the user edit a single user-picker field on an issue.
/// Pre-loads the current value so they can confirm/add/remove. Empty selection clears the field.
/// Same keybindings as the other dialogs: Cmd-Return submits, Escape cancels.
struct UserFieldDialog: View {
    let issueKey: String
    let shortcut: UserFieldShortcut
    let onSubmit: ([JiraUser], @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void

    @State private var availableUsers: [JiraUser] = []
    @State private var selectedUsers: Set<JiraUser> = []
    @State private var filter: String = ""
    @State private var loading: Bool = false
    @State private var loadError: String?
    @State private var submitting: Bool = false

    private let client = JiraClient()

    private var filteredUsers: [JiraUser] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return availableUsers }
        return availableUsers.filter { u in
            if u.displayName.lowercased().contains(q) { return true }
            if let email = u.emailAddress?.lowercased(), email.contains(q) { return true }
            if let name = u.name?.lowercased(), name.contains(q) { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.label.isEmpty ? "Change User" : shortcut.label)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(issueKey)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack {
                TextField("Filter loaded users…", text: $filter)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button {
                    loadUsers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload assignable users")
                .disabled(loading)
            }

            if loading {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundColor(.secondary) }
            } else if let loadError {
                Text(loadError).foregroundColor(.red).font(.footnote)
            } else if availableUsers.isEmpty {
                Text("No assignable users found for \(issueKey).").foregroundColor(.secondary).font(.footnote)
            } else if filteredUsers.isEmpty {
                Text("No users match your filter.").foregroundColor(.secondary).font(.footnote)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredUsers) { user in
                        userRow(user)
                    }
                }
            }
            .frame(height: 200)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )

            HStack {
                if selectedUsers.isEmpty {
                    Text("No users selected — submitting will clear this field.")
                        .font(.footnote)
                        .foregroundColor(.orange)
                } else {
                    Text("Selected: \(selectedUsers.map(\.displayName).sorted().joined(separator: ", "))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !selectedUsers.isEmpty {
                    Button("Clear all") { selectedUsers = [] }
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .disabled(submitting)

                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? "Saving…" : "Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .onAppear {
            DispatchQueue.main.async { loadUsers() }
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
        .onTapGesture { toggle(user) }
    }

    private func toggle(_ user: JiraUser) {
        if selectedUsers.contains(user) {
            selectedUsers.remove(user)
        } else {
            if shortcut.allowsMultiple {
                selectedUsers.insert(user)
            } else {
                selectedUsers = [user]
            }
        }
    }

    private func loadUsers() {
        loading = true
        loadError = nil
        client.getAssignableUsers(issueKey: issueKey) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let users):
                    self.availableUsers = users
                    self.preselectExisting()
                case .failure(let message):
                    self.availableUsers = []
                    self.loadError = message
                }
                self.loading = false
            }
        }
    }

    /// Loads whoever's currently in the field on the issue and pre-selects them.
    private func preselectExisting() {
        guard selectedUsers.isEmpty else { return }
        client.getIssueFieldUsers(issueKey: issueKey, fieldId: shortcut.fieldId) { existing in
            DispatchQueue.main.async {
                guard !existing.isEmpty else { return }
                let matched: [JiraUser] = existing.map { candidate in
                    availableUsers.first(where: { Self.sameUser($0, candidate) }) ?? candidate
                }
                selectedUsers = Set(matched)
                arrangeSelectedFirst()
            }
        }
    }

    /// Moves pre-selected users to the top of the list (one-shot — clicks after this don't reshuffle).
    /// Any selected users not returned by assignable-search are inserted so the list still reflects
    /// the current field value (e.g. an inactive user that was already on the field).
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

    private func submit() {
        guard !submitting else { return }
        submitting = true
        onSubmit(Array(selectedUsers)) { success in
            if !success { submitting = false }
        }
    }
}
