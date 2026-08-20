import Foundation

/// The pure half of @-mention autocomplete: where the caret is, whether an `@`-token is being
/// typed, which users match it, and how the readable text in the box becomes a Jira wiki-markup
/// comment body.
///
/// Deliberately free of SwiftUI and of `JiraClient`, because every rule worth arguing about lives
/// here — the identity of a mention, and the key routing that stops one Escape from both closing
/// the dropdown and throwing away a half-written comment.
enum MentionText {

    /// Past this many characters after the `@`, the user meant the character, not a mention.
    static let maxQueryLength = 32

    /// How many rows the dropdown will show. Kept small deliberately: the list is drawn over a
    /// fixed-height dialog, and a taller one would run off the bottom where its rows could be
    /// arrow-selected but neither seen nor clicked.
    static let maxSuggestions = 5

    /// A partially-typed mention: where the `@` sits, where the caret is, and what was typed
    /// between them.
    struct Query: Equatable {
        /// Offset of the `@` itself.
        let start: Int
        /// Offset just past the last typed character — the caret.
        let end: Int
        /// What was typed after the `@`, `@` excluded.
        let text: String
    }

    /// A mention the user has committed: the readable token left sitting in the text box, and the
    /// wiki markup it becomes on submit.
    struct Mention: Equatable {
        let token: String
        let reference: String
    }

    // MARK: - Caret

    /// Where the caret must be, given that an edit turned `oldText` into `newText`.
    ///
    /// SwiftUI's `TextField` does not expose its selection, so the caret is recovered by diffing:
    /// an edit is bounded by the longest common prefix and the longest common suffix, and the caret
    /// lands at the end of what changed. Without this a mention could only ever be typed at the
    /// very end of the box, and going back to fix a name mid-comment would silently do nothing.
    static func caret(oldText: String, newText: String) -> Int {
        let old = Array(oldText)
        let new = Array(newText)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        return new.count - suffix
    }

    // MARK: - Trigger

    /// The mention being typed at `caret`, or nil when there isn't one.
    ///
    /// Returns nil rather than guessing in every ambiguous case: no `@` before the nearest
    /// whitespace, an `@` glued to the end of a word (so `name@example.com` is an address and not a
    /// mention of `example.com`), nothing typed yet, or a run so long the `@` was clearly literal.
    static func activeQuery(text: String, caret: Int) -> Query? {
        let chars = Array(text)
        guard caret > 0, caret <= chars.count else { return nil }

        var index = caret - 1
        while index >= 0, chars[index] != "@" {
            if chars[index].isWhitespace || chars[index].isNewline { return nil }
            index -= 1
        }
        guard index >= 0 else { return nil }
        if index > 0, !isMentionBoundary(chars[index - 1]) { return nil }

        let typed = String(chars[(index + 1)..<caret])
        // Empty means `@` and nothing else yet. The list is meant to appear once a name is being
        // typed, which also keeps a bare `@` from dropping a directory over the box.
        guard !typed.isEmpty, typed.count <= maxQueryLength else { return nil }
        return Query(start: index, end: caret, text: typed)
    }

    private static func isMentionBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character.isNewline || "([{<\"',;:/".contains(character)
    }

    // MARK: - Matching

    /// Match quality, best first. The list is sorted by this so the row the user wants is already
    /// highlighted before they touch an arrow key — which is what makes "type three letters, hit
    /// Tab" work.
    ///
    /// `nil` means no match at all: not shown, so that "nothing matches" is a real state and the
    /// typed text can be left exactly as it is.
    static func tier(_ user: JiraUser, query: String) -> Int? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return nil }
        let display = user.displayName.lowercased()
        if display.hasPrefix(needle) { return 0 }
        if words(in: display).contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if let local = user.emailAddress?.lowercased().split(separator: "@").first,
           local.hasPrefix(needle) { return 2 }
        if let name = user.name?.lowercased(), name.hasPrefix(needle) { return 3 }
        if display.contains(needle) { return 4 }
        return nil
    }

    /// A display name's words. Split on more than spaces so hyphenated surnames and "J.R." style
    /// initials each expose their own start to a prefix match.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || "-.'’,_".contains($0) }).map(String.init)
    }

    /// Orders (and trims) what the server returned so the best match is first.
    ///
    /// Jira has already narrowed the list server-side; this is about which row is highlighted, and
    /// about narrowing further between keystrokes without waiting for another round trip. Ties keep
    /// Jira's own ordering.
    static func ranked(_ users: [JiraUser], query: String, limit: Int = maxSuggestions) -> [JiraUser] {
        users.enumerated()
            .compactMap { offset, user in
                tier(user, query: query).map { (tier: $0, offset: offset, user: user) }
            }
            .sorted { ($0.tier, $0.offset) < ($1.tier, $1.offset) }
            .prefix(limit)
            .map(\.user)
    }

    /// Arrow movement inside the dropdown. Clamped rather than wrapping, so holding an arrow key
    /// settles at an end instead of cycling past it.
    static func movedHighlight(from current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current + delta, 0), count - 1)
    }

    // MARK: - Committing

    /// The wiki-markup mention token for a user, or nil when we cannot say who they are.
    ///
    /// Cloud mentions are keyed by `accountId` and Server/DC by username — never by display name,
    /// which is not unique on any instance of a useful size. A nil here means we decline to write a
    /// mention at all, because one aimed at the wrong person is worse than none.
    static func reference(for user: JiraUser, cloud: Bool) -> String? {
        if cloud {
            guard let accountId = user.accountId, !accountId.isEmpty else { return nil }
            return "[~accountid:\(accountId)]"
        }
        guard let name = user.name, !name.isEmpty else { return nil }
        return "[~\(name)]"
    }

    /// The readable token to drop in the box for a pick.
    ///
    /// Normally just the display name. It gets qualified only when an *already-picked* mention wears
    /// the same name for a different account: two identical tokens in one comment cannot be told
    /// apart when the body is built, and the failure that produces is notifying the wrong namesake.
    /// The same person picked twice keeps the same token, which is harmless — both stand for one id.
    static func token(for user: JiraUser, reference: String, existing: [Mention]) -> String {
        let base = "@\(user.displayName)"
        func clashes(_ candidate: String) -> Bool {
            existing.contains { $0.token == candidate && $0.reference != reference }
        }
        guard clashes(base) else { return base }
        if let local = user.emailAddress?.split(separator: "@").first, !local.isEmpty {
            let qualified = "\(base) (\(local))"
            if !clashes(qualified) { return qualified }
        }
        var suffix = 2
        while clashes("\(base) (\(suffix))") { suffix += 1 }
        return "\(base) (\(suffix))"
    }

    /// Replaces the partially-typed `@love` with a readable `@Ada Lovelace `, and reports the
    /// mention to record. The box keeps a name; the account id is substituted on submit.
    ///
    /// Nil when the user carries no usable identifier — see `reference(for:cloud:)`.
    static func commit(
        text: String,
        query: Query,
        user: JiraUser,
        cloud: Bool,
        existing: [Mention] = []
    ) -> (text: String, mention: Mention)? {
        guard let reference = reference(for: user, cloud: cloud) else { return nil }
        let chars = Array(text)
        guard query.start >= 0, query.end <= chars.count, query.start <= query.end else { return nil }
        let token = token(for: user, reference: reference, existing: existing)
        // No second space when one is already there, or fixing a mention mid-sentence would leave a
        // gap behind every correction.
        let followedBySpace = query.end < chars.count && chars[query.end] == " "
        let replacement = followedBySpace ? token : token + " "
        let updated = String(chars[0..<query.start]) + replacement + String(chars[query.end...])
        return (updated, Mention(token: token, reference: reference))
    }

    // MARK: - Submitting

    /// Rewrites the readable tokens back into wiki markup — one occurrence claimed per recorded
    /// mention.
    ///
    /// A recorded mention whose token the user has since deleted finds nothing and is skipped, so
    /// editing the text can only ever drop a mention, never misdirect one. That rests entirely on
    /// tokens being unique per account (see `token(for:reference:existing:)`): with two identical
    /// tokens standing for different people, deleting one would hand its account the other's
    /// occurrence and notify the wrong namesake.
    ///
    /// Longest token first, because a qualified "@Dana Scully (dana)" contains the bare
    /// "@Dana Scully" and would otherwise have its occurrence claimed by it.
    static func wikiBody(text: String, mentions: [Mention]) -> String {
        var claimed: [Range<String.Index>] = []
        var edits: [(range: Range<String.Index>, replacement: String)] = []

        let ordered = mentions.enumerated()
            .sorted { ($1.element.token.count, $0.offset) < ($0.element.token.count, $1.offset) }
            .map(\.element)

        for mention in ordered where !mention.token.isEmpty {
            var from = text.startIndex
            while let found = text.range(of: mention.token, range: from..<text.endIndex) {
                let free = !claimed.contains { $0.overlaps(found) }
                if free, !continuesWord(text, after: found) {
                    claimed.append(found)
                    edits.append((found, mention.reference))
                    break
                }
                from = text.index(after: found.lowerBound)
            }
        }

        var result = text
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result
    }

    /// True when the character straight after a token continues a word, so a recorded "@Dan" does
    /// not claim the "@Dan" inside a hand-typed "@Daniel".
    private static func continuesWord(_ text: String, after range: Range<String.Index>) -> Bool {
        guard range.upperBound < text.endIndex else { return false }
        let next = text[range.upperBound]
        return next.isLetter || next.isNumber
    }

    /// The account ids a wiki-markup body mentions.
    ///
    /// Read back out of the body we are about to send rather than carried alongside it, so the
    /// post-write verification checks what was actually posted and not what was intended.
    static func mentionedAccountIds(inWiki body: String) -> [String] {
        let opener = "[~accountid:"
        var ids: [String] = []
        var from = body.startIndex
        while let start = body.range(of: opener, range: from..<body.endIndex) {
            guard let close = body.range(of: "]", range: start.upperBound..<body.endIndex) else { break }
            let id = String(body[start.upperBound..<close.lowerBound])
            if !id.isEmpty { ids.append(id) }
            from = close.upperBound
        }
        return ids
    }
}

// MARK: - Key routing

/// What a keypress should do while the mention dropdown is on screen.
///
/// A value with no side effects of its own, so that the event monitor has exactly one decision to
/// make: consume the event, or hand it on untouched. `.passThrough` is the only non-consuming case,
/// which is how a single Escape can close the dropdown *or* reach the dialog's Cancel button but
/// never both — losing a half-written comment to a dismissed suggestion list is the failure this
/// shape rules out.
enum MentionKeyAction: Equatable {
    case passThrough
    case moveHighlight(by: Int)
    case commitHighlighted
    case dismiss

    /// True when the monitor must swallow the event instead of letting the dialog see it.
    var consumesEvent: Bool { self != .passThrough }
}

enum MentionKeys {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let up: UInt16 = 126
    static let down: UInt16 = 125

    /// Routes one keypress.
    ///
    /// A closed dropdown is answered `.passThrough` before anything else is considered, which is
    /// what keeps Tab moving focus between controls and Escape closing the dialog exactly as they
    /// did before mentions existed. Modified presses pass through for the same reason — ⌘-Return
    /// still submits with the dropdown open.
    static func action(
        keyCode: UInt16,
        modified: Bool,
        dropdownOpen: Bool,
        hasHighlight: Bool
    ) -> MentionKeyAction {
        guard dropdownOpen, !modified else { return .passThrough }
        switch keyCode {
        case escape:
            return .dismiss
        case up:
            return .moveHighlight(by: -1)
        case down:
            return .moveHighlight(by: 1)
        case tab, returnKey, keypadEnter:
            // Tab and Return are the same commit: Tab is not a separate "complete the prefix", it
            // takes whatever is highlighted. With nothing highlighted there is nothing to take, so
            // it falls through to ordinary focus movement. The view keeps a row highlighted for as
            // long as the dropdown is open, so that fall-through is defensive — it is the rule the
            // caller relies on to be allowed to index the highlighted row without checking.
            return hasHighlight ? .commitHighlighted : .passThrough
        default:
            return .passThrough
        }
    }
}
