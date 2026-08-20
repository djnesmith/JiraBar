import SwiftUI
import AppKit
import Defaults

/// The mutable half of the mention dropdown, and the owner of the AppKit key monitor.
///
/// A reference type on purpose. The monitor's closure outlives the `body` pass that created it, and
/// SwiftUI `@State` read and written from an escaping AppKit callback only works by virtue of its
/// storage box — not by contract. Everything the monitor touches lives here instead.
@MainActor
final class MentionDropdown: ObservableObject {
    @Published private(set) var matches: [JiraUser] = []
    @Published private(set) var highlight = 0
    @Published private(set) var query: MentionText.Query?

    /// The last server result, kept so another keystroke narrows the list locally instead of
    /// blanking it until the next round trip lands.
    private var candidates: [JiraUser] = []
    /// The `@` offset dismissed with Escape, so the dropdown does not reappear on the next keystroke
    /// of a token the user has already said no to.
    private var suppressedStart: Int?
    private var previousText = ""
    private var focused = false

    private var monitor: Any?
    /// The window the field is hosted in. The monitor is app-wide, so without this it would act on
    /// keys typed in Preferences.
    weak var host: NSWindow?
    /// Applies a pick to the caller's text and mention list.
    var onCommit: ((JiraUser, MentionText.Query) -> Void)?

    var isOpen: Bool { query != nil && !matches.isEmpty && focused }

    // MARK: - Text tracking

    func seed(text: String) {
        previousText = text
    }

    func setFocused(_ value: Bool) {
        focused = value
        syncMonitor()
    }

    /// Recomputes the trigger after an edit. Runs on every keystroke — only the network lookup is
    /// debounced, or the dropdown would trail the caret by a couple of characters.
    func retrigger(text: String) {
        let caret = MentionText.caret(oldText: previousText, newText: text)
        previousText = text

        guard let found = MentionText.activeQuery(text: text, caret: caret) else {
            // Off the token entirely, so a previous Escape stops applying.
            suppressedStart = nil
            close()
            return
        }
        guard found.start != suppressedStart else {
            close()
            return
        }
        suppressedStart = nil
        query = found
        show(MentionText.ranked(candidates, query: found.text))
    }

    /// Folds in a lookup result, unless the user has since typed something it cannot answer for.
    func apply(users: [JiraUser], forQuery asked: String) {
        guard let current = query, current.text.hasPrefix(asked) else { return }
        candidates = users
        show(MentionText.ranked(users, query: current.text))
    }

    /// Replaces the visible rows, resetting the highlight whenever the *set* of people changed.
    ///
    /// Keeping the index across a changed list would silently move the selection onto somebody the
    /// user never looked at — and Tab would then commit them.
    private func show(_ updated: [JiraUser]) {
        let sameRows = updated.map(\.id) == matches.map(\.id)
        matches = updated
        highlight = sameRows
            ? MentionText.movedHighlight(from: highlight, by: 0, count: updated.count)
            : 0
        syncMonitor()
    }

    // MARK: - Dismissal

    /// Closes the dropdown. Deliberately never touches the caller's text — dismissing a suggestion
    /// list must leave what was typed exactly as typed.
    func close() {
        query = nil
        matches = []
        highlight = 0
        syncMonitor()
    }

    /// Escape. Closes the dropdown and remembers which `@` was refused, so it does not spring back on
    /// the very next keystroke of a token the user has already turned down.
    func dismiss() {
        suppressedStart = query?.start
        close()
    }

    func moveHighlight(by delta: Int) {
        highlight = MentionText.movedHighlight(from: highlight, by: delta, count: matches.count)
    }

    func pick(_ index: Int) {
        guard matches.indices.contains(index), let query else { return }
        let user = matches[index]
        // Closed before the commit so the row set is gone even if applying the pick re-enters here
        // through the caller's text change.
        close()
        onCommit?(user, query)
    }

    // MARK: - Key monitor

    private func syncMonitor() {
        if isOpen {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        } else {
            removeMonitor()
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The single place a keypress is either swallowed or handed on.
    ///
    /// Returning nil consumes the event before the window dispatches it, so the dialog's
    /// `.cancelAction` and `.defaultAction` buttons never see it; returning it untouched is the only
    /// other outcome. `MentionKeyAction.consumesEvent` picks which, and `.passThrough` is its only
    /// non-consuming case — so one Escape can close the dropdown *or* cancel the dialog, never both.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // These dialogs are hosted in windows that are never released and carry no delegate, so
        // closing one does not tear the SwiftUI graph down and `onDisappear` never fires. Left to
        // `isOpen` alone this app-wide monitor would outlive its dropdown and start eating Escape and
        // Tab everywhere in the app — so it retires itself the moment its window is gone.
        guard let host, host.isVisible else {
            removeMonitor()
            return event
        }
        guard event.window === host else { return event }

        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let action = MentionKeys.action(
            keyCode: event.keyCode,
            modified: !event.modifierFlags.intersection(modifiers).isEmpty,
            dropdownOpen: isOpen,
            hasHighlight: matches.indices.contains(highlight)
        )
        switch action {
        case .passThrough:
            break
        case .dismiss:
            dismiss()
        case .moveHighlight(let delta):
            moveHighlight(by: delta)
        case .commitHighlighted:
            pick(highlight)
        }
        return action.consumesEvent ? nil : event
    }
}

/// A comment box with Jira @-mention autocomplete. All three comment dialogs use this instead of a
/// bare `TextField`, so the interaction — and the key handling that makes it safe — exists once.
///
/// `text` stays readable: the box shows "@Ada Lovelace", never an account id. `mentions` collects
/// the wiki markup each committed name stands for, and callers submit
/// `MentionText.wikiBody(text:mentions:)` rather than `text` itself.
struct MentionTextField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var mentions: [MentionText.Mention]
    let lineLimit: ClosedRange<Int>

    @StateObject private var dropdown = MentionDropdown()
    @FocusState private var focused: Bool

    private let client = JiraClient()

    /// Fixed row metric: the list is positioned by offsetting itself, and SwiftUI will not report a
    /// measured height early enough to lay out against.
    private static let rowHeight: CGFloat = 22

    var body: some View {
        DebounceTextField(
            label: placeholder,
            value: $text,
            axis: .vertical,
            lineLimit: lineLimit,
            focus: $focused,
            valueChanged: { _ in runSearch() },
            debounceSeconds: 0.2
        )
        // Anchored to the top of the box and hanging over the text rather than below the field: the
        // dialogs are fixed-height, and a list dropped below a twelve-line box would run off the
        // bottom where its rows could be arrow-selected but neither seen nor clicked.
        .overlay(alignment: .topLeading) { list.offset(y: Self.rowHeight + 2) }
        .background(WindowReader { dropdown.host = $0 })
        .zIndex(1)
        .onAppear {
            dropdown.seed(text: text)
            dropdown.onCommit = commit
        }
        .onDisappear { dropdown.removeMonitor() }
        .onChange(of: text) { dropdown.retrigger(text: $0) }
        .onChange(of: focused) { dropdown.setFocused($0) }
    }

    // MARK: - Dropdown

    @ViewBuilder
    private var list: some View {
        if dropdown.isOpen {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(dropdown.matches.enumerated()), id: \.element.id) { index, user in
                    row(user, index: index)
                }
            }
            .frame(width: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
    }

    private func row(_ user: JiraUser, index: Int) -> some View {
        let highlighted = index == dropdown.highlight
        return HStack(spacing: 6) {
            Text(user.displayName)
                .lineLimit(1)
            if let email = user.emailAddress, !email.isEmpty {
                Text(email)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(highlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { dropdown.pick(index) }
    }

    // MARK: - Search and commit

    private func runSearch() {
        guard let asked = dropdown.query?.text else { return }
        client.searchUsers(query: asked) { users in
            DispatchQueue.main.async { dropdown.apply(users: users, forQuery: asked) }
        }
    }

    private func commit(_ user: JiraUser, query: MentionText.Query) {
        guard
            let result = MentionText.commit(
                text: text,
                query: query,
                user: user,
                cloud: Defaults[.instanceType] == .cloud,
                existing: mentions
            )
        else {
            // No account id on Cloud, no username on Server: we cannot say who this is, and a
            // mention aimed at the wrong person is worse than none. Leave the typed text alone.
            return
        }
        text = result.text
        dropdown.seed(text: result.text)
        mentions.append(result.mention)
    }
}

/// Reports the `NSWindow` the SwiftUI view is hosted in, so the key monitor can tell its own
/// window's keystrokes from the rest of the app's.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `window` is nil until the view is in a hierarchy, so resolve after this layout pass.
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
