import SwiftUI

/// Minimal "Add Comment" sheet. Shares the same submit/cancel keybindings as TransitionDialog:
/// Cmd-Return submits from anywhere, Escape cancels, Tab moves between focusable controls.
struct CommentDialog: View {
    let issueKey: String
    let onSubmit: (String, @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void

    @State private var comment: String = ""
    @State private var submitting: Bool = false

    private var trimmed: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Comment")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(issueKey)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            TextField("", text: $comment, axis: .vertical)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .lineLimit(6...12)

            Spacer(minLength: 0)

            HStack {
                Button("") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .disabled(submitting || trimmed.isEmpty)

                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(submitting ? "Submitting…" : "Add Comment") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 280)
    }

    private func submit() {
        guard !submitting, !trimmed.isEmpty else { return }
        submitting = true
        onSubmit(comment) { success in
            if !success { submitting = false }
        }
    }
}
