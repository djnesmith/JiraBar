# Fork features

Read this before merging upstream. Every item must still work after the merge.

Branch: `main`. Base: `upstream/main` (menubar-apps/JiraBar). Self-hosted Server support is upstream's, not listed here.

Most items have unit tests. Run the suite first:

```sh
xcodebuild -project jiraBar.xcodeproj -scheme jiraBar -destination 'platform=macOS' test
```

`AppDelegate.swift`, `JiraClient.swift`, `GithubClient.swift` and `PreferencesView.swift` carry most of this fork's code; expect merge conflicts there and keep both sides.

## 1. Menu chrome: status order, board rank, dashboards

Status groups follow a set order with a colour per header; tickets sort by the board's rank field; Open Dashboard / Open My Dashboard / Open All Issues links.

- Commits: `45a7280`, `0167b1c`
- Files: `JiraBar/Extensions/StatusDisplay.swift`, `DefaultsExtensions.swift` (`statusOrder`, `rankFieldId`, `dashboardURL`, `myDashboardURL`, `allIssuesJQL`), `AppDelegate.swift`
- Check: tests `StatusDisplayTests`, `StatusGroupOrderingTests`. Menu groups appear in the configured order with coloured headers.

## 2. Per-issue submenu

Copy Key / URL / Title / Branch Name / PR Name; Add Comment, Add/Remove Flag (flag icon on the row), Upload Files; user-field shortcuts (Change Assignee/Reviewer/Tester) that show current users and read "Add" when empty. Assignee writes are read back to confirm they landed.

- Commits: `45a7280`, `9a2f281`, `d4cb5e3`, `c4afdb8`, `4efd68d`, `9c7d420`, `7aa2494`
- Files: `JiraBar/Views/UserFieldDialog.swift`, `CommentDialog.swift`, `FlagDialog.swift`, `UploadFilesDialog.swift`, `JiraBar/Extensions/UserFieldShortcut.swift`, `JiraClient.swift`
- Check: tests `FlagRowMarkerTests`, `JiraClientParsingTests`. Click path: open a ticket's submenu, Change Assignee, pick a user, the ticket shows the new assignee after refresh.

## 3. Transition prompts

Per-transition dialogs that ask for a comment, user picker, text or select field before a transition; JSON import/export; Preferences warns when a prompt name extends a real transition name (`Reopened` vs `Reopen`); user picker can default to the assignee.

- Commits: `cafaa7d`, `5054aa8`, `1d0edfc`, `f9de095`, `bd7e7c2`
- Files: `JiraBar/Extensions/TransitionPromptConfig.swift`, `JiraBar/Views/TransitionDialog.swift`, `PreferencesView.swift`
- Check: test `TransitionPromptConfigTests`. Click path: a ticket > a transition with a prompt configured opens the dialog.

## 4. Required fields gate

Transition button stays disabled until fields marked Required, or required by Jira's screen metadata, are filled. Unknown metadata keeps it disabled.

- Commits: `0ddc5c6`, `07ef132`, `ea8493c`
- Files: `TransitionDialog.swift`, `BulkMoveDialog.swift`, `JiraClient.swift`
- Check: test `TransitionPromptConfigTests` (required cases).

## 5. PR actions from a transition

A transition can also approve, request changes, merge, resolve open review conversations, and sync the assignee on linked GitHub PRs, chosen per PR. Failures show in the window, which stays open; merge failures name the blocker.

- Commits: `2f4d409`, `9e91ef5`, `97a0a15`, `a36a87c`, `ba028b7`, `879f365`, `d186939`, `3039ea8`, `37cf2ba`, `f8ff64d`, `e82b196`, `90cc8f4`, `45b5cd4`
- Files: `TransitionDialog.swift`, `GithubClient.swift`, `AppDelegate.swift`
- Check: tests `PRActionDefaultsTests`, `UserNoticeTests`. Click path: a ticket with an open PR > a transition with PR actions on; the dialog lists each PR with its approve/merge boxes.

## 6. Jira to GitHub reviewer mirror

With a GitHub token, a reviewer field id and a Jira-to-GitHub JSON map, changing reviewers in Jira also assigns you and syncs requested reviewers on linked PRs. Failed reads skip the sync rather than removing people.

- Commits: `45152d5`, `93adb7a`
- Files: `JiraBar/Github/JiraGithubUserMap.swift`, `GithubClient.swift`, `JiraBar/JiraBar.entitlements` (`files.user-selected.read-write`, `files.bookmarks.app-scope` for the map file)
- Check: `grep -c 'bookmarks.app-scope' JiraBar/JiraBar.entitlements` is 1. Click path: Change Reviewer shows "Also update GitHub PR" and the PR's reviewers match after submit.

## 7. Move Multiple Issues (bulk move)

Bulk-transition many tickets in one dialog, including the TODO backlog; same prompt fields, PR work and failure reporting as single moves; shows each ticket's assignee and PRs; never defaults to a closing transition; preselects you as assignee.

- Commits: `c473511`, `2017715`, `03b56f7`, `73011e8`, `f58b0a3`, `bf68f8a`
- Files: `JiraBar/Views/BulkMoveDialog.swift`
- Check: tests `BulkMoveAssigneeTests`, `BulkMoveDefaultTransitionTests`, `BulkMovePRLineTests`, `BulkMoveTodoBacklogTests`.

## 8. PR rows

Linked PRs under each ticket: state (open/merged/draft/error), review decision, unresolved threads, CI, released/releasing, owner line; modifier-click routing with hover hint pills; one shared PR-URL parser; GraphQL variables instead of string pasting.

- Commits: `0167b1c`, `6da4647`, `9b9a892`, `8e3809a`, `ae8fdfd`, `0ea2249`, `57c0d24`, `8d11dcd`
- Files: `JiraBar/Views/PRMenuItemView.swift`, `JiraBar/Github/ForgePRURL.swift`, `GithubClient.swift`
- Check: test `ForgePRURLTests`. Hover a PR row holding ⌘: a pill reads "Left Click to Create Release".

## 9. GitHub PR search fallback, rate-limit safe

When Jira links no PRs, find PRs whose title holds the ticket key in the GitHub Search Orgs. One search per project per 60s, matched locally, so the 30/min search limit is not hit.

- Commits: `9b9a892`, `41791eb`
- Files: `JiraBar/Github/GithubPRIndex.swift`, `GithubClient.swift`
- Check: test `GithubPRIndexTests`.

## 10. TODO section

Backlog submenu from the TODO JQL, or from the Dashboard board's To Do column when the Dashboard URL is a board; drops tickets already yours; lazy submenus; assignees in green.

- Commits: `a64e0cc`, `711689d`, `f20d5dc`, `37e9c23`, `4741fb7`, `d111fe7`
- Files: `JiraBar/Jira/BoardTodoQuery.swift`, `AppDelegate.swift`
- Check: tests `BoardTodoQueryTests`, `TodoOrderingTests`, `LazySectionSubmenuTests`.

## 11. PRs Without Tickets section

Your open GitHub PRs (authored, assigned, review requested) with no Jira key, in a submenu; drafts marked; handed-off PRs dropped.

- Commits: `db2b024`, `07fb555`, `00e5f07`, `d4f398f`, `281a164`
- Files: `AppDelegate.swift`, `GithubClient.swift`
- Check: test `MyPRsQueryTests`. Toggle: Preferences > "Show PRs Without Tickets section".

## 12. History sections: Recently Closed, Recently Seen, Recently Approved PRs

Recently Closed (your Done tickets, with status), Recently Seen (tickets you moved that aren't yours), Recently Approved PRs (PRs you approved). All get the full ticket submenu.

- Commits: `1ca7f65`, `0c8fd7a`, `c62b98e`, `6882a70`, `db1b74e`, `c6794ee`
- Files: `AppDelegate.swift`, `DefaultsExtensions.swift` (`recentlyClosedJQL`, `recentlySeenJQL`, `showRecentlyApprovedSection`)
- Check: test `MenuSectionHeaderTests`. All three entries show in the menu under TODO.

## 13. @-mentions in comment boxes

Typing `@` in any comment box offers users and posts a real Jira mention. Return picks, it doesn't submit.

- Commits: `162b347`, `30abdb9`
- Files: `JiraBar/Jira/MentionText.swift`, `JiraBar/Views/MentionTextField.swift`
- Check: tests `MentionTextTests`, `MentionDropdownTests`, `MentionVerificationTests`.

## 14. Colours and legibility

Issue keys in link blue (per chosen projects); Bug red, Epic purple, Task/Improvement lighter purple; colours tuned for the macOS 26 glass menu background.

- Commits: `66403be`, `fecaf22`, `7ceebfc`, `94594ec`, `c23947d`, `df900ee`, `a9e37f5`, `305e199`, `e4ea6fb`, `0f13ab8`
- Files: `NSMutableAttributedString.swift`, `NSImageExtensions.swift`, `NSColorExtensions.swift`, `AppDelegate.swift`
- Check: test `AppDelegateHelpersTests` (contrast cases). Menu in dark mode: metadata text readable, Bug type in red.

## 15. Status-header copy

Clicking a status header copies its ticket keys; modifier keys choose the format.

- Commits: `ec6688a`, `4eb9d8f`
- Files: `AppDelegate.swift`
- Check: tests `StatusCopyFormatTests`, `StatusHeaderCopyTests`, `IssueKeyListTests`.

## 16. Refresh and status signals

`notifyutil -p com.dnesmith.jirabar.refresh` refreshes at once, then again at 3s and 20s; a moved ticket shows without Refresh; ✕ instead of a count when Jira is unreachable; notifications name the ticket.

- Commits: `41c00db`, `a1a4484`, `91a84d1`, `7956637`, `bfd9d5a`, `822efd0`
- Files: `JiraBar/Extensions/CatchUpRefreshSchedule.swift`, `RefreshDebouncer.swift`, `AppDelegate.swift`, `JiraClient.swift`
- Check: tests `CatchUpRefreshScheduleTests`, `RefreshDebouncerTests`. Run `notifyutil -p com.dnesmith.jirabar.refresh` and the menu refreshes.

## 17. Settings backup

Export All / Import All of every setting to JSON, secrets excluded.

- Commits: `c018f57`
- Files: `JiraBar/Extensions/SettingsBackup.swift`, `PreferencesView.swift`
- Check: Preferences > Export All, then Import All the same file; settings unchanged.

## 18. Hardening

Failed reads no longer look like empty data (no reviewers wiped); additive PR assignees; keychain write errors don't crash; refresh races guarded; force-unwraps removed; tests can't post real notifications or read machine prefs; real identifiers replaced with placeholders.

- Commits: `56bde29`, `2d26def`, `e3c688c`, `307c14c`, `0755662`, `7427802`, `e375a6e`
- Files: `JiraBar/Keychain.swift`, `JiraTokenValidator.swift`, `GithubClient.swift`, `AppDelegate.swift`, `jiraBarTests/`
- Check: test suite passes; `JiraBar/Notifications.swift` stays deleted (one `sendNotification`).

## 19. Unit tests and CI

`jiraBarTests` target and `.github/workflows/tests.yml`: unit suite on every push/PR, plus a Release-config job that asserts the sandbox wiring (`CODE_SIGN_ENTITLEMENTS`, hardened runtime, `app-sandbox`). Xcode 26 project settings.

- Commits: `a5a58af`, `5fb0c1f`, `d1f5c87`, `d251403`, `107f786`, `73b23cb`, `bab80db`, `0e7ef06`
- Files: `jiraBar.xcodeproj/project.pbxproj`, `jiraBar.xcodeproj/xcshareddata/xcschemes/jiraBar.xcscheme`, `.github/workflows/tests.yml`, `jiraBarTests/`
- Check: the test command above, 0 failures; GitHub Actions run on the merge commit is green.

## 20. Docs and agent notes

README covers every fork feature; AGENTS.md has the test command, log-reading and `strings` notes; `.gitignore` drops `.brief-*.md`.

- Commits: `e5c3e70`, `d1ec70e`, `7fb30c8`, `ffff97e`
- Files: `README.md`, `AGENTS.md`, `.gitignore`
- Check: README still has the "PR actions from a transition" and "TODO section" headings after the merge.
