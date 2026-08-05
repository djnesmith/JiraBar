import SwiftUI

/// Invisible ⌘-Return companion to a dialog's visible submit button. SwiftUI keyboard
/// shortcuts must live on a Button and the visible one already carries `.defaultAction`
/// (plain Return), so every dialog pairs it with this zero-size twin.
struct HiddenSubmitButton: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button("") { action() }
            .keyboardShortcut(.return, modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .disabled(disabled)
    }
}
