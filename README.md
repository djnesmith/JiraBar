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
- **Board order within a group** — set the Jira Lexorank field id (commonly `customfield_10019` on Cloud) and each status group sorts by rank ascending, matching your board.
- **Open Search results / Open All Issues / Open Dashboard / Open My Dashboard** — quick links under the ticket list. The two dashboard slots each take a full URL or a path relative to your Jira base; the second is handy for a filtered "just me" board view.
- **Refresh** and **Create issue** entries at the bottom.

## Per-issue submenu

- **Copy Key / Copy URL / Copy Title / Copy Branch Name / Copy PR Name** — the branch name uses `KEY-slugified-title` (max 50-char slug, git-safe).
- **Add Comment / Add Flag / Upload Files** — the upload dialog supports drag-and-drop. Add Flag only appears when a Flagged custom-field id is configured.
- **Change Assignee / Change Reviewer / Change Tester** (and any other user-picker fields you add) — configured per install as "User Field Shortcuts" so it works against whatever your custom-field ids are. Opening a ticket's submenu lazily fetches each shortcut field's current users and renders them under the shortcut label, colored by the ticket's status color (or a per-shortcut status-color override).
- **Transitions** — every available Jira transition. Configure per-transition prompts to require a comment, a user picker, a text field, or a select field before submitting.
- **Move Multiple Issues…** — bulk-transition several tickets at once. The dialog carries the same prompt fields as single transitions (user picker / text / select, plus a shared comment), and — when the reviewer mirror is configured — an "also update GitHub PRs" checkbox that mirrors reviewers onto every successfully-moved issue's linked PRs.

## Pull-request rows

Below each ticket, JiraBar shows any GitHub PRs Jira has linked to the ticket via its dev-status API. Rows are enriched from GitHub when a token is set:

- **Line 1** — PR title (truncated).
- **Line 2** — `owner/repo #NNN · <state>` where state is `open` / `merged` / `declined` / `draft` (color-coded). If a token is set and CI failed on an OPEN PR, state is replaced with `error` in red.
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

## My PRs section

With a GitHub token set, a **My PRs** entry appears between the ticket groups and the utility items. Its submenu lists your open GitHub PRs — ones you're assigned to or whose review was requested from you — that **aren't** associated with any Jira ticket. A PR counts as ticket-associated (and is excluded) when it already renders under a visible ticket, or when a Jira issue key (`ABC-123` style) appears in its title or head branch name — that second rule catches tickets outside your JQL window. Rows look and click exactly like ticket PR rows (same third line, same modifier routing and hint pills), the entry hides itself entirely when there's nothing to show, and results are scoped to **GitHub Search Orgs** when that's set. Toggle it off in Preferences with **Show My PRs section**.

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

- **Approve** — submits an APPROVE review (with an optional comment); PRs you've already approved are skipped. The dialog pre-fetches state and shows "You've approved N/M open PRs" so you know before submitting.
- **Merge** — merges with a configurable method (merge / squash / rebase); PRs whose repo disallows the chosen method are skipped and counted in the summary.
- **Sync Jira Assignee** — sets the ticket's Jira Assignee (mapped via the Jira → GitHub file) as the PR assignee, only when the PR has no assignee yet.

Approvals go out first, then assignee-sync and merges, so GitHub's merge-eligibility check never races a just-submitted approval. One summary notification reports counts per action.

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
