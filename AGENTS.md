# AGENTS.md

Practical guidance for AI agents working on JiraBar.

## Project Snapshot

- Native macOS menu bar app (single Xcode target, Swift 5)
- Polls Jira REST API on a timer and renders issues in an `NSMenu`
- `AppDelegate` is the central coordinator for menu lifecycle and refresh logic
- SwiftUI is used for Preferences and About windows only

## High-Signal Files

- `JiraBar/AppDelegate.swift`: status bar lifecycle, timer, menu rebuild, window hosting, TODO, Recently Closed and PRs Without Tickets sections, GitHub mirror/PR-action orchestration
- `JiraBar/Jira/JiraClient.swift`: Jira API calls, auth headers, credential validation
- `JiraBar/Github/GithubClient.swift`: GraphQL PR enrichment, searches, reviews/merge/assignee/reviewer endpoints
- `JiraBar/Github/ForgePRURL.swift`: the one PR/repo URL parser — don't re-implement path walking
- `JiraBar/Views/PreferencesView.swift`: Cloud/Server settings UI and Test button behavior
- `JiraBar/Views/`: the SwiftUI dialogs (Transition, BulkMove, UserField, Comment, Flag, Upload) and the custom PR row view
- `JiraBar/Extensions/DefaultsExtensions.swift`: Defaults keys, enums, Keychain keys
- `JiraBar/Keychain.swift`: `@FromKeychain` / `@KeychainStorage` wrappers

## Auth and Instance Model

- `instanceType`: `.cloud` or `.server`
- `serverAuthType`: `.pat` or `.basic`
- Cloud:
  - Base URL: `https://{org}.atlassian.net`
  - API: v3 for search (`/rest/api/3/search/jql`)
  - Auth: Basic (`jiraUsername` + `jiraToken`)
- Server/Data Center:
  - Base URL: `jiraHost` (trim trailing slash)
  - API: v2 (`/rest/api/2/...`)
  - PAT: Bearer (`jiraServerToken`)
  - Basic: username/password (`jiraServerUsername` + `jiraServerToken`)

## Storage Rules

- Secrets stay in Keychain only (`jiraToken`, `jiraServerToken`)
- UserDefaults keys are defined in `DefaultsExtensions.swift`; do not invent ad-hoc keys
- Preserve existing key names unless a migration is explicitly requested

## Networking Conventions

- Use Alamofire with closure-based callbacks (current project style)
- Keep auth/header construction centralized in `JiraClient`
- Handle Cloud vs Server differences explicitly (URL, API version, auth type)

## Build and Verify

- Build command:
  - `xcodebuild -project jiraBar.xcodeproj -scheme jiraBar -destination 'platform=macOS' build`
- Test command (unit tests in `jiraBarTests/`, hosted in the app):
  - `xcodebuild -project jiraBar.xcodeproj -scheme jiraBar -destination 'platform=macOS' test`
- New pure logic should get a unit test; UI/menu behavior still needs manual checks:
  1. Menu bar icon appears and refreshes on interval
  2. Preferences save and reload correctly for Cloud and Server modes
  3. Issue grouping and transitions still work
  4. About and external links still open

## Current Tech Debt

- `Base.lproj/Main.storyboard` contains a dead scene referencing a deleted `ViewController`
  class; the scene never instantiates (`visibleAtLaunch="NO"`), the storyboard itself is
  still needed (`INFOPLIST_KEY_NSMainStoryboardFile` wires NSApplication/main menu)
- The user-picker UI (filter/row/toggle/arrange) is duplicated across
  `TransitionDialog` and `UserFieldDialog`, with a diverging variant in `BulkMoveDialog` —
  extraction deferred because it's SwiftUI with no test coverage possible. The identity
  match is not part of that: it lives in `JiraUser.isSame(as:)` (`JiraDtos.swift`). Note
  `JiraUser.id` tiers the same three fields for a different purpose — it must never be nil,
  so it falls back to displayName, which `isSame` must never do

## Reading the running app's logs

Two things make the installed app look like it logs nothing. Both cost an hour once.

- **`log` is a zsh builtin and shadows `/usr/bin/log` in a non-interactive shell.** `log show ...`
  from a script or an agent's shell silently returns nothing at all. Always invoke `/usr/bin/log`
  by absolute path.
- **A Release build ad-hoc signed without `get-task-allow` redacts os_log dynamic data to
  `<private>`.** So `NSLog("Refresh finished, menubar shows %@", count)` is present in the log but
  unreadable, while a Debug/test-host build shows the text because it is debuggable. **Timestamps
  are not redacted**, so the timing and count of log calls is still usable evidence — that is how
  the post-write refresh schedule was verified on a live install:

      /usr/bin/log show --predicate 'processIdentifier == <pid> AND senderImagePath CONTAINS "Foundation"' \
        --start '<time>' --end '<time>' --style compact

  Unredacting needs `sudo log config --mode private_data:on`, a system-wide privacy change — ask
  first. The better fix is `os_log` with the app's own subsystem and `%{public}` on the values worth
  reading; not done yet.

## Checking a deployed binary with `strings`

`strings` is a valid check that an installed bundle carries an edit **only for literals longer than
15 UTF-8 bytes.** Swift's small-string optimization stores a literal of 15 bytes or fewer inline in
the `String` struct rather than as a C string in `__TEXT`, so it never appears in `strings` output.
Measured on the notification bodies: `transition failed: ` (19 bytes) and `couldn't load
transitions` (25) were present, while `Transitioned ` (13) and `Moved no issues` (exactly 15) were
absent from a binary that definitely contained both. Read as "the edit did not land", that is a
wrong conclusion and an expensive one.

Delivered user notifications are readable without provoking a TCC prompt, which is the better check
for notification text: the `record` table of
`~/Library/Group Containers/group.com.apple.usernoted/db2/db`, joined to `app` on `app_id`, where
each row's `data` is a binary plist whose `req.body` is the banner text. `delivered_date` is seconds
from the 2001-01-01 UTC epoch, so convert before comparing against local timestamps.

## Entitlements

- Keep sandbox/network client entitlements as-is
- Do not add `com.apple.security.network.server`
