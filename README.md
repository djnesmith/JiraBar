# JiraBar

<p align="center">
  <a href="https://github.com/menubar-apps/JiraBar"><img src="https://img.shields.io/badge/-JiraBar-black?logo=github&style=flat"></a>
  <img alt="GitHub all releases" src="https://img.shields.io/github/downloads/menubar-apps/jirabar/total">
  <img alt="GitHub top language" src="https://img.shields.io/github/languages/top/menubar-apps/jirabar">
</p>


Native MacOS menubar application to show Jira issues in your menu bar:

<p align="center">
<img width="539" alt="Screen Shot 2022-09-27 at 8 49 39 PM" src="https://user-images.githubusercontent.com/9363150/192662802-a4640dd9-dc7b-4aeb-9aa8-fa0708738b11.png">
</p>

# Installation

[Download](https://github.com/menubar-apps/JiraBar/releases) and install the latest release. Then start the application, open preferences and setup your jira host, credentials and a query:

<p align="center">
<img width="612" alt="Screen Shot 2022-09-27 at 8 51 13 PM" src="https://user-images.githubusercontent.com/9363150/192662959-5fb0fde2-efe1-4631-a454-f7330315262b.png">
</p>

# Features

## Menu

- **Status Order & Colors** — order status groups to match your board and pick a color per header. Unlisted statuses fall to the bottom, alphabetically.
- **Issue type colour** — `Bug` renders red; `Epic` and any `… Initiative` type render a deep purple; `Task` and `Improvement` render the same purple lighter, because they are the same kind of ordinary work item to anyone scanning the row. `Story`, `Sub-task` and anything else your instance defines stay in the metadata grey. Note that `Task` is usually the majority of rows, so most of the menu carries the light purple and the grey is the exception. The two purples are the tightest pair in the palette and are written out as explicit light/dark values rather than taken from `systemPurple`, because Apple retunes the system colours between macOS releases and this margin is too small to absorb that quietly. On a dark background the lighter shade reads louder than the deeper one, so the ordinary types carry more visual weight than epics — a consequence of separating them by lightness rather than hue.
- **Board order within a group** — set the Jira Lexorank field id (commonly `customfield_10019` on Cloud) and each status group sorts by rank ascending, matching your board.
- **Open Search results / Open All Issues / Open Dashboard / Open My Dashboard** — quick links under the ticket list. The two dashboard slots each take a full URL or a path relative to your Jira base; the second is handy for a filtered "just me" board view.
- **Refresh** and **Create issue** entries at the bottom.

## Per-issue submenu

- **Copy Key / Copy URL / Copy Title / Copy Branch Name / Copy PR Name** — the branch name uses `KEY-slugified-title` (max 50-char slug, git-safe).
- **Add Comment / Add Flag / Upload Files** — the upload dialog supports drag-and-drop. Add Flag only appears when a Flagged custom-field id is configured.
- **Change Assignee / Change Reviewer / Change Tester** (and any other user-picker fields you add) — configured per install as "User Field Shortcuts" so it works against whatever your custom-field ids are. Opening a ticket's submenu lazily fetches each shortcut field's current users and renders them under the shortcut label, colored by the ticket's status color (or a per-shortcut status-color override). A label beginning `Change ` switches to `Add ` when the field turns out to be empty — but only on a successful read: if the value can't be established, the label stays as configured rather than claiming the field is free.
- **Transitions** — every available Jira transition. Configure per-transition prompts to require a comment, a user picker, a text field, or a select field before submitting.
- **Move Multiple Issues…** — bulk-transition several tickets at once. The dialog carries the same prompt fields as single transitions (user picker / text / select, plus a shared comment), and — when the reviewer mirror is configured — an "also update GitHub PRs" checkbox that mirrors reviewers onto every successfully-moved issue's linked PRs.

## Pull-request rows

Below each ticket, JiraBar shows any GitHub PRs Jira has linked to the ticket via its dev-status API. Rows are enriched from GitHub when a token is set:

- **Line 1** — PR title (truncated).
- **Line 2** — `owner/repo #NNN · <state>` where state is `open` / `merged` / `declined` / `draft` (color-coded). Drafts are detected from GitHub even though it reports them as open, so they're marked wherever they appear, including in PRs Without Tickets. If a token is set and CI failed on an open PR, the state word becomes `error` in red — that outranks the draft marker, being the more actionable signal.
- **Line 3 (OPEN PRs)** — review decision (`approved` / `changes requested`; nothing is shown while review is still required), unresolved-thread count, and CI outcome, whichever the token can see.
- **Line 3 (MERGED PRs)** — `released` (green) once the repo's most recent release was published *after* the merge, or `releasing` (yellow) while the default branch's checks are still `PENDING`/`EXPECTED`.

**Click routing on a PR row:**

| Click | Action |
|---|---|
| Left-click | Open the PR |
| ⌘ + Left-click | Open the repo's `releases/new` page |
| ⌥ + Left-click | Open the repo's Actions tab |
| ⌃ + Left-click | Open the repo home |
| ⇧ + Left-click | Copy just the PR number (e.g. `269`) |
| Right-click | Copy the PR URL |

Hovering over a PR row with any modifier held pops small accent-colored hint pills over the row so you don't have to memorize the table: the left pill spells out what a left-click will do, and the right pill reminds you that right-click copies the URL. Plain hover shows nothing, so casual mouse-over stays quiet.

## TODO section

Set a **TODO JQL** in Preferences and a `TODO` entry appears above PRs Without Tickets, whose submenu lists the matching tickets — each carrying the same submenu it gets in the main list (transitions, copy shortcuts, comment/flag/upload, user-field shortcuts, PR rows). It's meant for the backlog your main JQL can't show: the main query is usually scoped to you, so the column you'd *pick from* is invisible. A query like `project = ABC AND status = "To Do" ORDER BY Rank ASC` gives you that.

Tickets **already assigned to you are left out**, whatever your query says. The section answers "what would I pick up next", and a ticket that's already yours isn't a candidate — it's work in hand, and the status groups above are already showing it. Your own tickets are matched by your Jira account, not your display name, so a namesake's ticket still appears. If JiraBar can't establish who you are, nothing is filtered rather than something being hidden without explanation.

Ordering follows the **Rank field id** when one is configured, which is what makes the submenu match board order. Without it, the order Jira returned is preserved untouched, so any `ORDER BY` in your query still applies. **TODO Max Results** caps the list separately from the main one, since a backlog usually wants a different depth.

The per-ticket submenus are built the first time you open TODO, not on every refresh — each one costs a transitions call plus a dev-status call, so a 15-ticket backlog would otherwise multiply JiraBar's request volume for a menu you may never open. The section hides itself entirely when there's nothing left to show — whether the query came back empty or everything it returned was already yours.

To keep your own tickets from eating into **TODO Max Results**, the search asks for roughly twice the cap and trims after filtering. That's headroom, not a guarantee: if your own tickets fill the top of the column past that margin, you'll see a short section — or none at all — even though unassigned backlog exists further down. Raise **TODO Max Results**, or scope the query past the tickets you're already holding.

There's deliberately no default query. `status = "To Do"` with no project or board scope doesn't mean "my To Do column" — it means every To Do ticket in every project you can see, which after the result cap is a near-random sample. The query has to name your project or board to be meaningful, so it's yours to write.

## Recently Closed section

A `Recently Closed` entry appears under TODO, listing finished tickets newest-first with their PRs — including merged and closed ones, which for a finished ticket are the artifact worth seeing. It works out of the box; clear **Recently Closed JQL** in Preferences to switch it off.

Each ticket's submenu carries the copy shortcuts and its PR rows, and nothing else: no transitions, comment, flag, upload or user-field shortcuts. It is a history rollup, so every one of those would be either a mutation or a request per ticket. Submenus are built the first time you open the section, so it costs nothing until then, and **Recently Closed Max Results** caps the list separately.

Each row also shows the ticket's **status** after its type, coloured from your own **Status Order & Colors** mapping. A status you have not given a colour renders in the same grey as the rest of the row's metadata rather than being dropped or given an invented colour.

The ordering is yours — put it in the query. Use **`ORDER BY statusCategoryChangedDate DESC`**, not `resolutiondate`: plenty of workflows never set a resolution, and NULLs sort first under `DESC`, so a third of your rows can be ancient tickets crowding out the recent ones. `statusCategoryChangedDate` is the field that means "when did this become Done".

The default query is scoped to you but not to any project, because `statusCategory = Done` means different things in different workflows — a status like "General Availability" can count as Done and surface tickets nobody would call closed. If you work across projects, add `AND project in (ABC, DEF)`.

## Recently Seen section

A `Recently Seen` entry sits under Recently Closed, listing tickets **you moved that are not yours**. You transition something as reviewer or tester, it goes to someone else's name, and it leaves your board immediately — with nothing anywhere recording that you touched it. This is that record.

Three clauses define it, and each is load-bearing: `status CHANGED BY currentUser()` (you moved it), `assignee != currentUser()` (which is why it vanished), and `statusCategory != Done` (which is what keeps it disjoint from Recently Closed rather than duplicating it). It works out of the box; clear **Recently Seen JQL** to switch it off, and cap it with **Recently Seen Max Results** (default 10).

Rows show the key, the type and the **status** — the status is the whole point, since it is the thing you changed. Submenus are the same history rollup Recently Closed uses: copy shortcuts and PR rows, no transitions. These are not your tickets, and offering to move someone else's out of a rollup invites a misclick with no context.

Ordered by **`updated`**, not `statusCategoryChangedDate` as Recently Closed uses. A hand-off is often between two statuses inside the same category — a review-to-QA move can be two "In Progress" statuses — and `statusCategoryChangedDate` does not move for those, so it would order the section by an event that never happened.

The window is **14 days**: one two-week sprint, so something handed off at the start of the sprint is still listed, while the section stays a memory aid rather than an archive. Change it in the query. A ticket already visible in your main list is filtered out rather than shown twice, and the section hides itself entirely when nothing survives — which, if you mostly hand things straight to Done, will be often.

## Recently Approved PRs section

A `Recently Approved PRs` entry lists the PRs **you** most recently approved — your review activity, not your authored work — newest-**updated** first, so a PR you approved days ago and someone pushed to this morning sits at the top. Rows are the usual PR rows, so merged and closed states and their colours come free.

Scoped by **GitHub Search Orgs** and requires a GitHub Token; both are the settings the PRs Without Tickets section already uses, so there is no query to configure. Toggle it with **Show Recently Approved PRs section** and cap it with **Recently Approved PRs Max Results** (default 10).

GitHub has no search qualifier for "the viewer approved it" — `review:approved` is the PR's overall decision, not yours — so the search asks for `reviewed-by:@me` and the approval is checked per PR afterwards. That means PRs you only commented on, or requested changes on and never came back to, are filtered out; a PR you requested changes on and later approved stays in, because what counts is your *latest* review.

## PRs Without Tickets section

With a GitHub token set, a **PRs Without Tickets** entry appears between the ticket groups and the utility items. Its submenu lists your open GitHub PRs — ones you authored, ones assigned to you, and ones whose review was requested from you — that **aren't** associated with any Jira ticket. All three matter: opening a PR doesn't assign it to you or request your review, and a PR assigned to you may well have been written by someone else. A PR counts as ticket-associated (and is excluded) when it already renders under a visible ticket, or when a Jira issue key (`ABC-123` style) appears in its title or head branch name — that second rule catches tickets outside your JQL window. Rows click exactly like ticket PR rows (same modifier routing and hint pills) and carry the same first three lines, plus a fourth naming who the PR is assigned to and where its reviews stand — `assignee: djnesmith · jgerman approved · alice pending`. That line only appears here, because every other PR row sits under a Jira ticket that already answers "whose is this". An unassigned PR says `unassigned` rather than leaving a gap, and a PR whose GitHub read failed shows no ownership line at all rather than claiming nobody owns it, the entry hides itself entirely when there's nothing to show, and results are scoped to **GitHub Search Orgs** when that's set. Toggle it off in Preferences with **Show PRs Without Tickets section**.

## GitHub search fallback

When Jira's dev-status API returns no PRs for a ticket — usually because the branch name doesn't include the ticket key and the org's Jira↔GitHub integration only matches on branch name — JiraBar can fall back to searching GitHub. Set a **GitHub Search Orgs** value in Preferences (comma-separated) and any PR whose title contains the ticket key inside those orgs is picked up. Results are deduped by URL against whatever Jira returned so a PR that later gets picked up by both sources renders once.

## Jira → GitHub reviewer mirror

Enable this by setting three things in Preferences:

1. **GitHub Token** — a PAT with `repo` scope (or `public_repo` if you only care about public repos), with permission to assign and request reviewers on the repos you care about.
2. **PR Reviewer field id** — the Jira custom-field id whose users represent PR reviewers (e.g. `customfield_10029` on many Cloud installs — check your own).
3. **Jira → GitHub Map** — a JSON file mapping Jira `accountId`s to GitHub logins. Click **Browse…** to pick it (the picker also stores a security-scoped bookmark so the sandbox can read the file next launch).

With all three set, the "Ready for Review" transition dialog and the "Change Reviewer" shortcut show a checkbox — **Also update GitHub PR: assign me, add selected users as reviewers** — default on. Submitting will:

- Add you (looked up via your own Jira accountId in the map) to the PR **Assignees** on every linked open GitHub PR — additive, existing assignees are kept.
- Sync the PR's **Requested reviewers** list to match the Jira reviewers: add anyone missing, remove anyone the map knows about who's no longer in the Jira list. Requested reviewers not in the map (external contributors, ad-hoc adds) are left alone. If the PR's current reviewer list can't be read (auth/network failure), the sync for that PR is skipped entirely rather than diffing against an unknown state.

A notification summarizes what happened per PR, and lists any Jira users that don't have a mapping.

## PR actions from a transition

Each transition prompt can additionally enable **PR actions** that run against every open linked GitHub PR after the transition commits:

- **Review** — a three-way choice per transition: don't review, **Approve**, or **Request changes**.
  - *Approve* submits an APPROVE review with an optional comment; PRs you've already approved are skipped. The dialog pre-fetches state and shows "You've approved N/M open PRs" so you know before submitting.
  - *Request changes* submits a REQUEST_CHANGES review, and its **comment is mandatory** — GitHub rejects a request-changes review with no body, so the dialog won't submit until you write one. Repeats are never skipped: the comment is the payload, and a ticket coming back a second time is exactly when you want another one.
  - Because it's one picker rather than two checkboxes, approving and requesting changes can't both be asked for.
- **Merge** — merges with a configurable method (merge / squash / rebase); PRs whose repo disallows the chosen method are skipped and counted in the summary. **Unavailable in request-changes mode** — merging a PR you just asked for changes on is nonsense, so it's withdrawn rather than merely greyed out.
- **Resolve open review conversations** — marks every unresolved review thread on the PR resolved. **All of them, including conversations you did not write and may not have answered.** It exists because a branch with `required_conversation_resolution` refuses to merge while any thread is open, and an outdated-looking thread still counts. The summary names how many were closed and whose they were, per PR.
- **Sync Jira Assignee** — sets the ticket's Jira Assignee (mapped via the Jira → GitHub file) as the PR assignee, only when the PR has no assignee yet.

Reviews and conversation resolution go out first, then assignee-sync and merges. Resolution must precede the merge: a branch requiring conversation resolution refuses the merge outright rather than queueing behind it, and the batch does not retry. Reviews go first for the same class of reason — so GitHub's merge-eligibility check never races a just-submitted review.

When a merge does fail, the window names the blocker GitHub reported rather than only that it failed — unresolved conversations (with a count), conflicts, a draft, a branch out of date with its base, or mergeability still being computed.

**The dialog stays open until the PR actions finish**, and reports anything that didn't land, naming the PR — "the Jira transition WAS applied, but 1 PR action did not: Review not submitted on acme/api #2". The Jira transition is not rolled back, so retrying the transition isn't the fix; do it on the PR. A summary notification is also posted, leading with the failure count when something failed, but the window is the primary channel: a notification is missable and a closed window looks like success. A transition Jira *refuses* also keeps the window open, carrying Jira's own message.

None of this runs on **Move Multiple Issues** — bulk move performs no PR actions at all.

## Transition names, not status names

Prompts match on the **transition's name**, not the status it moves to — the transition may be `Reopen` while the status it lands in is `Reopened`, and the status is what Jira shows on the ticket. Matching is plain equality, so a near-miss name opens no dialog and reports nothing.

Preferences warns about the likeliest version of that mistake: a name that *extends* a transition JiraBar has actually seen (`Reopened` when it has seen `Reopen`). It stays quiet about a name it simply doesn't recognise, because it never sees your whole workflow — Jira only reports the transitions reachable from the current status of the tickets your query returned, so a correctly-named prompt for a transition out of some other status is unrecognisable and perfectly fine.

## Required fields

Any configured field on a transition prompt can be marked **Required**, which disables the Transition button until it's filled — for a user picker, until at least one user is selected. The dialog lists everything outstanding at once, so you don't fix one thing to discover the next.

JiraBar also reads Jira's own required-field flags for the transition being submitted (`expand=transitions.fields`, once, when the dialog opens) and honours those too. The two are OR'd, and both are needed: a rule enforced by a **workflow validator** — "Testers are required before moving into QA." — reports `required: false` on the transition screen while still rejecting the transition, so only the manual flag can express it. Conversely Jira's flags catch screen-required fields you never marked locally.

If the metadata can't be read, requiredness is *unknown* rather than empty and the button stays disabled with a reason. Guessing "nothing is required" would just move the failure to Jira. Prompts with no fields at all are never gated by this.

**Move Multiple Issues** honours the **Required** checkboxes but not Jira's own flags: those are per-issue metadata, and reading them for a bulk move would mean one extra request per ticket before the dialog could open.

### Mapping file format

```json
{
  "version": 1,
  "mappings": [
    { "jiraAccountId": "605e4480-abcd-4000-a000-000000000001", "jiraDisplayName": "Alice Example",   "githubLogin": "alice" },
    { "jiraAccountId": "712020:1234abcd-0000-0000-0000-000000000000", "jiraDisplayName": "Bob Example", "githubLogin": "bexample" }
  ]
}
```

- `jiraAccountId` is the Cloud accountId (found under Atlassian profile URLs, or via `/rest/api/3/user/search`). Server installs use the `name`/`key` field on `JiraUser`; the map takes whichever value your instance surfaces.
- `jiraDisplayName` is informational (helps a human review the file); matching is by `jiraAccountId`.
- `githubLogin` is the GitHub username.
- Anyone not in the file is treated as unmapped: they can't be added as reviewers, and if they're already on a PR they won't be removed by the sync.

## Settings backup

**Export All / Import All** in Preferences writes every configurable value (JQL, dashboards, status display, user-field shortcuts, transition prompts, GitHub search orgs, mapping file path, and so on) to a JSON file, and restores from one. Secrets (API tokens, GitHub PAT) are intentionally excluded — you re-enter them on import.

## Self-hosted Jira Server / Data Center

Preferences has a **Jira Cloud / Self-Hosted** segmented control. Self-hosted works with either Basic auth (username + password, for older Server pre-8.14) or Bearer / PAT (Server 8.14+ / Data Center).
