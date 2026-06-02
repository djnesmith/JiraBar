import SwiftUI

/// Adds the Flagged option to an issue, with an optional comment. Same keybindings as the other
/// dialogs: Cmd-Return submits, Escape cancels.
struct FlagDialog: View {
    let issueKey: String
    let onSubmit: (String, @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void

    @State private var comment: String = ""
    @State private var submitting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "flag.fill")
                    .foregroundColor(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Flag")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(issueKey)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Text("Marks the issue as Impediment. Comment is optional and posted alongside the flag.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Optional comment", text: $comment, axis: .vertical)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .lineLimit(4...8)

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
                Button(submitting ? "Flagging…" : "Add Flag") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting)
            }
        }
        .padding(16)
        .frame(width: 480, height: 260)
    }

    private func submit() {
        guard !submitting else { return }
        submitting = true
        onSubmit(comment) { success in
            if !success { submitting = false }
        }
    }
}
