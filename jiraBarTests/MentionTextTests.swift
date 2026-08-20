import XCTest
@testable import jiraBar

/// Account ids, names and emails below are invented. The live Cloud shapes they follow were checked
/// against a real instance: a `/user/search` result carries `accountId`, `displayName`,
/// `emailAddress`, `active` and `accountType`, and a comment posted through v2 with
/// `[~accountid:<id>]` reads back through v3 as an ADF `mention` node whose `attrs.id` is that id.
final class MentionTextTests: XCTestCase {

    private func user(
        _ displayName: String,
        accountId: String? = nil,
        email: String? = nil,
        name: String? = nil
    ) -> JiraUser {
        JiraUser(
            accountId: accountId,
            name: name,
            key: nil,
            displayName: displayName,
            emailAddress: email,
            active: true,
            accountType: "atlassian"
        )
    }

    // MARK: - Caret recovery

    func testCaretAtEndOfTypedText() {
        XCTAssertEqual(MentionText.caret(oldText: "hi @ge", newText: "hi @ger"), 7)
    }

    func testCaretForInsertionInTheMiddle() {
        // "ab|cd" with an x typed at the bar.
        XCTAssertEqual(MentionText.caret(oldText: "abcd", newText: "abxcd"), 3)
    }

    func testCaretForDeletionInTheMiddle() {
        XCTAssertEqual(MentionText.caret(oldText: "abcd", newText: "abd"), 2)
    }

    func testCaretForWholesaleReplacement() {
        XCTAssertEqual(MentionText.caret(oldText: "abc", newText: "xyz"), 3)
    }

    func testCaretUnchangedText() {
        XCTAssertEqual(MentionText.caret(oldText: "same", newText: "same"), 4)
    }

    func testCaretOnEmptyStrings() {
        XCTAssertEqual(MentionText.caret(oldText: "", newText: ""), 0)
        XCTAssertEqual(MentionText.caret(oldText: "@abc", newText: ""), 0)
        XCTAssertEqual(MentionText.caret(oldText: "", newText: "@a"), 2)
    }

    /// The whole design counts in `Character`s — grapheme clusters — and the same unit has to be used
    /// by the caret, the trigger and the replacement or an emoji earlier in the comment would shift
    /// the token out from under the offsets.
    func testGraphemeClustersCountAsSingleCharacters() {
        let text = "🇺🇸👨‍👩‍👧 @lov"
        let caret = MentionText.caret(oldText: "🇺🇸👨‍👩‍👧 @lo", newText: text)
        XCTAssertEqual(caret, 7)

        let query = MentionText.activeQuery(text: text, caret: caret)
        XCTAssertEqual(query, MentionText.Query(start: 3, end: 7, text: "lov"))

        let result = MentionText.commit(
            text: text,
            query: query!,
            user: user("Ada Lovelace", accountId: "acct-1"),
            cloud: true
        )
        XCTAssertEqual(result?.text, "🇺🇸👨‍👩‍👧 @Ada Lovelace ")
    }

    // MARK: - Trigger detection

    func testTriggersOnAtFollowedByLetters() {
        let query = MentionText.activeQuery(text: "ping @ger", caret: 9)
        XCTAssertEqual(query, MentionText.Query(start: 5, end: 9, text: "ger"))
    }

    func testTriggersAtTheStartOfTheBox() {
        XCTAssertEqual(MentionText.activeQuery(text: "@ab", caret: 3)?.text, "ab")
    }

    func testTriggersMidTextSoAMentionCanBeFixedInPlace() {
        // Caret sits after "@ge", with more text beyond it.
        let query = MentionText.activeQuery(text: "hi @ge and the rest", caret: 6)
        XCTAssertEqual(query, MentionText.Query(start: 3, end: 6, text: "ge"))
    }

    func testTriggersAfterAnOpeningBracket() {
        XCTAssertEqual(MentionText.activeQuery(text: "(@ab", caret: 4)?.text, "ab")
    }

    func testBareAtDoesNotTrigger() {
        XCTAssertNil(MentionText.activeQuery(text: "hello @", caret: 7))
    }

    func testEmailAddressDoesNotTrigger() {
        XCTAssertNil(MentionText.activeQuery(text: "someone@example.com", caret: 19))
    }

    func testWhitespaceBeforeTheCaretDoesNotTrigger() {
        XCTAssertNil(MentionText.activeQuery(text: "@ger done", caret: 9))
    }

    func testNoAtAtAllDoesNotTrigger() {
        XCTAssertNil(MentionText.activeQuery(text: "plain words", caret: 11))
    }

    func testAnOverlongRunIsALiteralAt() {
        let long = "@" + String(repeating: "x", count: MentionText.maxQueryLength + 1)
        XCTAssertNil(MentionText.activeQuery(text: long, caret: long.count))
    }

    func testCaretAtZeroDoesNotTrigger() {
        XCTAssertNil(MentionText.activeQuery(text: "@ab", caret: 0))
    }

    // MARK: - Matching and ranking

    /// Typing a surname prefix has to find the person — matching only the first name would make
    /// most of the directory unreachable.
    func testSurnamePrefixMatches() {
        let users = [user("Alice Adams"), user("Ada Lovelace"), user("Bob Brown")]
        XCTAssertEqual(MentionText.ranked(users, query: "love").map(\.displayName), ["Ada Lovelace"])
        XCTAssertEqual(MentionText.tier(user("Ada Lovelace"), query: "love"), 1)
    }

    func testFullNamePrefixOutranksWordPrefix() {
        let users = [user("Ada Smithson"), user("Smith Jones")]
        XCTAssertEqual(
            MentionText.ranked(users, query: "smith").map(\.displayName),
            ["Smith Jones", "Ada Smithson"]
        )
    }

    func testHyphenatedAndInitialledNamesExposeEachWord() {
        XCTAssertEqual(MentionText.words(in: "ada smith-jones"), ["ada", "smith", "jones"])
        XCTAssertEqual(MentionText.words(in: "j.r. hartley"), ["j", "r", "hartley"])
    }

    func testEmailLocalPartMatches() {
        let users = [user("Ada Lovelace", email: "alove@example.invalid")]
        XCTAssertEqual(MentionText.ranked(users, query: "alov").count, 1)
    }

    func testServerUsernameMatches() {
        let users = [user("Ada Lovelace", name: "alovelace")]
        XCTAssertEqual(MentionText.ranked(users, query: "alovel").count, 1)
    }

    func testNonMatchingUsersAreDropped() {
        let users = [user("Alice Adams"), user("Bob Brown")]
        XCTAssertTrue(MentionText.ranked(users, query: "zzz").isEmpty)
        XCTAssertNil(MentionText.tier(user("Alice Adams"), query: "zzz"))
    }

    func testRankingKeepsJirasOrderWithinATier() {
        let users = [user("Dana One"), user("Dana Two"), user("Dana Three")]
        XCTAssertEqual(
            MentionText.ranked(users, query: "dana").map(\.displayName),
            ["Dana One", "Dana Two", "Dana Three"]
        )
    }

    func testRankingHonoursTheRowLimit() {
        let users = (0..<20).map { user("Dana \($0)") }
        XCTAssertEqual(MentionText.ranked(users, query: "dana").count, MentionText.maxSuggestions)
    }

    // MARK: - Highlight movement

    func testHighlightClampsRatherThanWrapping() {
        XCTAssertEqual(MentionText.movedHighlight(from: 0, by: -1, count: 3), 0)
        XCTAssertEqual(MentionText.movedHighlight(from: 2, by: 1, count: 3), 2)
        XCTAssertEqual(MentionText.movedHighlight(from: 1, by: 1, count: 3), 2)
        XCTAssertEqual(MentionText.movedHighlight(from: 5, by: 0, count: 3), 2)
        XCTAssertEqual(MentionText.movedHighlight(from: 0, by: 1, count: 0), 0)
    }

    // MARK: - Identity

    func testCloudReferenceUsesAccountId() {
        let reference = MentionText.reference(for: user("Ada Lovelace", accountId: "acct-1"), cloud: true)
        XCTAssertEqual(reference, "[~accountid:acct-1]")
    }

    func testServerReferenceUsesUsername() {
        let reference = MentionText.reference(for: user("Ada Lovelace", name: "alovelace"), cloud: false)
        XCTAssertEqual(reference, "[~alovelace]")
    }

    /// A user with no usable identifier gets no mention at all. Display names are not unique, so
    /// falling back to one would notify a namesake instead of the person meant.
    func testMissingIdentifierRefusesToBuildAReference() {
        XCTAssertNil(MentionText.reference(for: user("Ada Lovelace"), cloud: true))
        XCTAssertNil(MentionText.reference(for: user("Ada Lovelace", accountId: "acct-1"), cloud: false))
        XCTAssertNil(MentionText.reference(for: user("Ada Lovelace", accountId: ""), cloud: true))
    }

    // MARK: - Committing a pick

    func testCommitLeavesAReadableNameInTheBox() {
        let query = MentionText.activeQuery(text: "ping @love", caret: 10)!
        let result = MentionText.commit(
            text: "ping @love",
            query: query,
            user: user("Ada Lovelace", accountId: "acct-9"),
            cloud: true
        )
        XCTAssertEqual(result?.text, "ping @Ada Lovelace ")
        XCTAssertEqual(result?.mention.token, "@Ada Lovelace")
        XCTAssertEqual(result?.mention.reference, "[~accountid:acct-9]")
    }

    /// The caret lands past the name and its space, ready to keep typing. Without applying this the
    /// field editor keeps the whole replaced value selected and the next keystroke wipes the name.
    func testCommitReportsACaretPastTheNameAndItsSpace() {
        let query = MentionText.activeQuery(text: "ping @love", caret: 10)!
        let result = MentionText.commit(
            text: "ping @love",
            query: query,
            user: user("Ada Lovelace", accountId: "acct-9"),
            cloud: true
        )
        XCTAssertEqual(result?.text, "ping @Ada Lovelace ")
        XCTAssertEqual(result?.caret, 19)
        XCTAssertEqual(result?.text.count, 19, "caret sits at the very end here, with nothing selected")
    }

    /// Mid-sentence, the caret still lands after the existing space rather than before it.
    func testCaretClearsAnExistingSpaceItReused() {
        let query = MentionText.activeQuery(text: "hi @ge and more", caret: 6)!
        let result = MentionText.commit(
            text: "hi @ge and more",
            query: query,
            user: user("Ada Lovelace", accountId: "acct-1"),
            cloud: true
        )
        XCTAssertEqual(result?.text, "hi @Ada Lovelace and more")
        let caret = result!.caret
        XCTAssertEqual(String(result!.text.prefix(caret)), "hi @Ada Lovelace ")
    }

    /// `NSRange` counts UTF-16 units, so a caret measured in Characters has to be converted or an
    /// emoji earlier in the comment would put the insertion point in the wrong place.
    func testCaretConvertsToAUTF16OffsetForTheFieldEditor() {
        XCTAssertEqual(MentionText.utf16Offset(ofCaret: 3, in: "abcdef"), 3)
        // A flag is one Character but two UTF-16 surrogate pairs.
        XCTAssertEqual(MentionText.utf16Offset(ofCaret: 1, in: "🇺🇸ab"), 4)
        XCTAssertEqual(MentionText.utf16Offset(ofCaret: 0, in: "abc"), 0)
        XCTAssertEqual(MentionText.utf16Offset(ofCaret: -5, in: "abc"), 0)
        XCTAssertEqual(MentionText.utf16Offset(ofCaret: 99, in: "abc"), 3)
    }

    /// Fixing a mention mid-sentence must not leave a double space where the old token ended.
    func testCommitDoesNotDoubleTheSpaceItLandsBefore() {
        let query = MentionText.activeQuery(text: "hi @ge and more", caret: 6)!
        let result = MentionText.commit(
            text: "hi @ge and more",
            query: query,
            user: user("Ada Lovelace", accountId: "acct-1"),
            cloud: true
        )
        XCTAssertEqual(result?.text, "hi @Ada Lovelace and more")
    }

    func testCommitPreservesTextAfterTheCaret() {
        let query = MentionText.activeQuery(text: "hi @ge,and more", caret: 6)!
        let result = MentionText.commit(
            text: "hi @ge,and more",
            query: query,
            user: user("Gerald Smith", accountId: "acct-2"),
            cloud: true
        )
        XCTAssertEqual(result?.text, "hi @Gerald Smith ,and more")
    }

    func testCommitRefusesAUserItCannotIdentify() {
        let query = MentionText.activeQuery(text: "@ab", caret: 3)!
        XCTAssertNil(
            MentionText.commit(text: "@ab", query: query, user: user("Ada Byron"), cloud: true)
        )
    }

    // MARK: - Building the wiki body

    func testWikiBodySubstitutesTheAccountId() {
        let mentions = [MentionText.Mention(token: "@Ada Lovelace", reference: "[~accountid:acct-9]")]
        XCTAssertEqual(
            MentionText.wikiBody(text: "ping @Ada Lovelace please", mentions: mentions),
            "ping [~accountid:acct-9] please"
        )
    }

    /// Two people sharing a display name get distinguishable tokens, so each resolves to its own id.
    func testSharedDisplayNamesResolveToTheirOwnAccounts() {
        let mentions = [
            MentionText.Mention(token: "@Dana Scully", reference: "[~accountid:acct-a]"),
            MentionText.Mention(token: "@Dana Scully (dana2)", reference: "[~accountid:acct-b]")
        ]
        XCTAssertEqual(
            MentionText.wikiBody(text: "@Dana Scully and @Dana Scully (dana2)", mentions: mentions),
            "[~accountid:acct-a] and [~accountid:acct-b]"
        )
    }

    /// The same person picked twice is not a clash — one token, one id, two occurrences claimed.
    func testTheSamePersonTwiceKeepsOneToken() {
        let mentions = [
            MentionText.Mention(token: "@Ada Byron", reference: "[~accountid:acct-a]"),
            MentionText.Mention(token: "@Ada Byron", reference: "[~accountid:acct-a]")
        ]
        XCTAssertEqual(
            MentionText.wikiBody(text: "@Ada Byron and @Ada Byron", mentions: mentions),
            "[~accountid:acct-a] and [~accountid:acct-a]"
        )
    }

    /// A namesake's token is qualified on the way in, which is the whole reason deleting one pick
    /// cannot hand its account the survivor's occurrence.
    func testNamesakeGetsAQualifiedToken() {
        let existing = [MentionText.Mention(token: "@Dana Scully", reference: "[~accountid:acct-a]")]
        let token = MentionText.token(
            for: user("Dana Scully", accountId: "acct-b", email: "dscully@example.invalid"),
            reference: "[~accountid:acct-b]",
            existing: existing
        )
        XCTAssertEqual(token, "@Dana Scully (dscully)")
    }

    /// A nameless user gets no token, because "@" alone would claim any bare `@` in the comment.
    func testANamelessUserGetsNoToken() {
        for name in ["", "   "] {
            XCTAssertNil(
                MentionText.token(
                    for: user(name, accountId: "acct-1"), reference: "[~accountid:acct-1]", existing: []
                ),
                "display name \(name.debugDescription)"
            )
        }
        let query = MentionText.activeQuery(text: "@ab", caret: 3)!
        XCTAssertNil(
            MentionText.commit(
                text: "@ab", query: query, user: user("", accountId: "acct-1"), cloud: true
            )
        )
    }

    func testNamesakeWithNoEmailFallsBackToACounter() {
        let existing = [MentionText.Mention(token: "@Dana Scully", reference: "[~accountid:acct-a]")]
        let token = MentionText.token(
            for: user("Dana Scully", accountId: "acct-b"),
            reference: "[~accountid:acct-b]",
            existing: existing
        )
        XCTAssertEqual(token, "@Dana Scully (2)")
    }

    /// Deleting the wrong pick and choosing again must not notify the person who was removed. The
    /// deleted record finds no token of its own and is skipped.
    func testDeletingAPickDoesNotMisdirectItsNamesake() {
        let mentions = [
            MentionText.Mention(token: "@Dana Scully", reference: "[~accountid:acct-DELETED]"),
            MentionText.Mention(token: "@Dana Scully (dscully)", reference: "[~accountid:acct-WANTED]")
        ]
        XCTAssertEqual(
            MentionText.wikiBody(text: "hi @Dana Scully (dscully)", mentions: mentions),
            "hi [~accountid:acct-WANTED]"
        )
    }

    /// A qualified token contains the bare one, so the bare one must not claim its occurrence.
    func testABareTokenDoesNotStealAQualifiedOccurrence() {
        let mentions = [
            MentionText.Mention(token: "@Dana Scully", reference: "[~accountid:acct-a]"),
            MentionText.Mention(token: "@Dana Scully (dscully)", reference: "[~accountid:acct-b]")
        ]
        // Only the qualified token is present; the bare record has nothing to claim.
        XCTAssertEqual(
            MentionText.wikiBody(text: "hi @Dana Scully (dscully)", mentions: mentions),
            "hi [~accountid:acct-b]"
        )
    }

    func testDeletedTokenIsSkippedRatherThanMisdirected() {
        let mentions = [
            MentionText.Mention(token: "@Gone Away", reference: "[~accountid:acct-x]"),
            MentionText.Mention(token: "@Still Here", reference: "[~accountid:acct-y]")
        ]
        XCTAssertEqual(
            MentionText.wikiBody(text: "only @Still Here left", mentions: mentions),
            "only [~accountid:acct-y] left"
        )
    }

    func testATokenDoesNotClaimALongerHandTypedName() {
        let mentions = [MentionText.Mention(token: "@Dan", reference: "[~accountid:acct-d]")]
        XCTAssertEqual(
            MentionText.wikiBody(text: "@Daniel is not @Dan", mentions: mentions),
            "@Daniel is not [~accountid:acct-d]"
        )
    }

    func testWikiBodyWithNoMentionsIsTheTextVerbatim() {
        XCTAssertEqual(MentionText.wikiBody(text: "email me@example.invalid", mentions: []),
                       "email me@example.invalid")
    }

    // MARK: - Reading ids back out of the body

    func testMentionedAccountIdsFindsEveryReference() {
        let body = "[~accountid:acct-a] and [~accountid:acct-b] done"
        XCTAssertEqual(MentionText.mentionedAccountIds(inWiki: body), ["acct-a", "acct-b"])
    }

    func testMentionedAccountIdsIgnoresPlainText() {
        XCTAssertTrue(MentionText.mentionedAccountIds(inWiki: "@Someone plain").isEmpty)
        XCTAssertTrue(MentionText.mentionedAccountIds(inWiki: "[~accountid:]").isEmpty)
        XCTAssertTrue(MentionText.mentionedAccountIds(inWiki: "[~accountid:unterminated").isEmpty)
    }
}

/// The key routing, pinned rather than argued about. The nesting that matters: one Escape closes the
/// dropdown *or* reaches the dialog, and can never do both.
final class MentionKeyRoutingTests: XCTestCase {

    private func action(
        _ keyCode: UInt16,
        control: Bool = false,
        otherModifiers: Bool = false,
        open: Bool = true,
        highlight: Bool = true
    ) -> MentionKeyAction {
        MentionKeys.action(
            keyCode: keyCode,
            control: control,
            otherModifiers: otherModifiers,
            dropdownOpen: open,
            hasHighlight: highlight
        )
    }

    // MARK: - Escape nesting

    /// Escape with the dropdown open is consumed, so the dialog's `.cancelAction` never sees it and
    /// the half-written comment survives.
    func testEscapeWithDropdownOpenDismissesOnlyTheDropdown() {
        let result = action(MentionKeys.escape, open: true)
        XCTAssertEqual(result, .dismiss)
        XCTAssertTrue(result.consumesEvent)
    }

    /// Escape with the dropdown closed is handed on untouched, so the dialog still closes as it
    /// always did.
    func testEscapeWithDropdownClosedReachesTheDialog() {
        let result = action(MentionKeys.escape, open: false)
        XCTAssertEqual(result, .passThrough)
        XCTAssertFalse(result.consumesEvent)
    }

    /// The structural guarantee behind "one press cannot do both": `.passThrough` is the only case
    /// the monitor hands on, and it is the only case that does nothing itself. Every other action
    /// consumes the event, so no single press can both act on the dropdown and reach the dialog.
    func testPassThroughIsTheOnlyNonConsumingAction() {
        let every: [MentionKeyAction] = [
            .passThrough, .dismiss, .commitHighlighted, .moveHighlight(by: 1), .moveHighlight(by: -1)
        ]
        for action in every {
            XCTAssertEqual(action.consumesEvent, action != .passThrough, "\(action)")
        }
    }

    // MARK: - Tab and Return commit the highlighted row

    func testTabAndReturnBothCommitTheHighlightedRow() {
        for key in [MentionKeys.tab, MentionKeys.returnKey, MentionKeys.keypadEnter] {
            XCTAssertEqual(action(key, open: true, highlight: true), .commitHighlighted, "\(key)")
        }
    }

    /// Tab has a job already. With nothing highlighted there is nothing to commit, so it falls
    /// through and keeps moving focus between the dialog's controls.
    func testTabFallsThroughToFocusMovementWithNothingHighlighted() {
        XCTAssertEqual(action(MentionKeys.tab, open: true, highlight: false), .passThrough)
    }

    func testTabWithTheDropdownClosedAlwaysMovesFocus() {
        XCTAssertEqual(action(MentionKeys.tab, open: false), .passThrough)
        XCTAssertEqual(action(MentionKeys.returnKey, open: false), .passThrough)
    }

    // MARK: - Arrows

    func testArrowsMoveTheHighlightWhileOpen() {
        XCTAssertEqual(action(MentionKeys.down), .moveHighlight(by: 1))
        XCTAssertEqual(action(MentionKeys.up), .moveHighlight(by: -1))
    }

    func testArrowsAreLeftAloneWhileClosed() {
        XCTAssertEqual(action(MentionKeys.down, open: false), .passThrough)
        XCTAssertEqual(action(MentionKeys.up, open: false), .passThrough)
    }

    // MARK: - Modifiers

    /// ⌘-Return must still submit the dialog with the dropdown open, so ⌘/⌥/⇧ presses pass through
    /// untouched.
    func testModifiedPressesAlwaysPassThrough() {
        for key in [MentionKeys.returnKey, MentionKeys.tab, MentionKeys.escape, MentionKeys.down] {
            XCTAssertEqual(action(key, otherModifiers: true, open: true), .passThrough, "\(key)")
        }
    }

    // MARK: - Emacs bindings

    func testControlNAndControlPMoveTheHighlight() {
        XCTAssertEqual(action(MentionKeys.n, control: true), .moveHighlight(by: 1))
        XCTAssertEqual(action(MentionKeys.p, control: true), .moveHighlight(by: -1))
    }

    /// A text view binds ⌃-N/⌃-P to moving the caret a line, so driving the list has to consume them
    /// or the caret would jump at the same time.
    func testControlNAndControlPAreConsumedWhileOpen() {
        XCTAssertTrue(action(MentionKeys.n, control: true).consumesEvent)
        XCTAssertTrue(action(MentionKeys.p, control: true).consumesEvent)
    }

    /// With the dropdown closed they go back to being ordinary caret movement.
    func testControlNAndControlPAreLeftAloneWhileClosed() {
        XCTAssertEqual(action(MentionKeys.n, control: true, open: false), .passThrough)
        XCTAssertEqual(action(MentionKeys.p, control: true, open: false), .passThrough)
    }

    func testPlainNAndPStillType() {
        XCTAssertEqual(action(MentionKeys.n), .passThrough)
        XCTAssertEqual(action(MentionKeys.p), .passThrough)
    }

    /// ⌃ with anything else held is not the binding, and ⌃ with another letter is somebody else's.
    func testOtherControlCombinationsPassThrough() {
        XCTAssertEqual(action(MentionKeys.n, control: true, otherModifiers: true), .passThrough)
        XCTAssertEqual(action(MentionKeys.returnKey, control: true), .passThrough)
        XCTAssertEqual(action(0 /* "a" */, control: true), .passThrough)
    }

    func testOrdinaryTypingPassesThrough() {
        XCTAssertEqual(action(0 /* "a" */, open: true), .passThrough)
    }
}
