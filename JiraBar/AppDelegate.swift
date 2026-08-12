import Cocoa
import SwiftUI
import Foundation
import Defaults


/// Concrete payload for the per-issue user-field menu items — keeps the cast in the handler clean.
private final class IssueShortcutTarget {
    let issueKey: String
    let shortcut: UserFieldShortcut
    init(issueKey: String, shortcut: UserFieldShortcut) {
        self.issueKey = issueKey
        self.shortcut = shortcut
    }
}

/// Menu delegate that lazy-fetches the current value(s) of the user-picker fields exposed as
/// per-issue shortcuts and updates each shortcut item to render as
/// `<label>\n<user 1>\n<user 2>…`. Deferred until first hover so a menu refresh doesn't pay
/// for a per-shortcut REST call on every visible ticket up front.
private final class IssueSubmenuDelegate: NSObject, NSMenuDelegate {
    struct Target {
        let fieldId: String
        let label: String
        /// Color used for the assigned-user lines under this shortcut. When nil the delegate
        /// falls back to the ticket-status color passed in at construction time.
        let color: NSColor?
        weak var item: NSMenuItem?
    }
    let issueKey: String
    let targets: [Target]
    let fallbackColor: NSColor?
    private let jiraClient: JiraClient
    private var fetched = false

    init(issueKey: String, targets: [Target], fallbackColor: NSColor?, jiraClient: JiraClient) {
        self.issueKey = issueKey
        self.targets = targets
        self.fallbackColor = fallbackColor
        self.jiraClient = jiraClient
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Only fire once per menu lifetime — the fetched values are still fresh next time this
        // submenu is opened, and the enclosing menu triggers a full refreshMenu on any change
        // that would invalidate them.
        guard !fetched else { return }
        fetched = true
        for target in targets {
            jiraClient.getIssueFieldUsers(issueKey: issueKey, fieldId: target.fieldId) { [weak self] users in
                DispatchQueue.main.async {
                    // nil (failed read) renders the same as empty — no user lines, non-destructive.
                    guard let self, let item = target.item else { return }
                    item.attributedTitle = self.buildTitle(label: target.label, users: users ?? [], color: target.color ?? self.fallbackColor)
                }
            }
        }
    }

    /// Builds an attributed title: label on the first line, one user per subsequent line in the
    /// resolved color (per-shortcut override, else the ticket status color; falls back to the
    /// secondary label color when neither is set). Users get a slightly smaller font so the
    /// label remains the anchor.
    private func buildTitle(label: String, users: [JiraUser], color: NSColor?) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: label)
        guard !users.isEmpty else { return attr }
        // Two-space indent per line so the user names visually nest under the label rather
        // than aligning flush with it — reads as a sublist.
        let names = users.map { "  " + $0.displayName }.joined(separator: "\n")
        let addition = NSMutableAttributedString(string: "\n" + names)
        let range = NSRange(location: 0, length: addition.length)
        addition.addAttribute(.foregroundColor, value: color ?? NSColor.secondaryLabelColor, range: range)
        addition.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: range)
        attr.append(addition)
        return attr
    }
}

/// Defers work until a menu is first opened, then runs it once. Used by the TODO section,
/// whose per-ticket submenus each cost a transitions call plus a dev-status call: paying that
/// for a whole backlog on every refresh — for a section that often goes unopened — would
/// multiply the app's request volume for nothing.
private final class LazyMenuDelegate: NSObject, NSMenuDelegate {
    private let populate: () -> Void
    private var populated = false

    init(populate: @escaping () -> Void) {
        self.populate = populate
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !populated else { return }
        populated = true
        populate()
    }
}

/// A one-shot rendezvous between a fetch that starts early and the menu item it fills in.
///
/// Sections like TODO can start their network call at the top of a refresh, but their menu item
/// can only be inserted once the sections above it exist — so the data and the item become
/// available in either order. `deliver` and `onReady` are the two sides of that race and
/// resolve it whichever way it lands: data first is held until the item asks for it, item first
/// leaves a renderer waiting for the data.
///
/// Main-thread only. Every caller is already there (Alamofire's default response queue is
/// `.main`, and refreshMenu runs from a timer or a menu action), so this deliberately carries no
/// lock — one would only hide a threading mistake.
final class PendingSection<T> {
    private var value: T?
    private var render: ((T) -> Void)?
    private var delivered = false

    /// Hands over the fetched data. Later deliveries are ignored — a section renders once.
    func deliver(_ newValue: T) {
        guard !delivered else { return }
        delivered = true
        if let render {
            self.render = nil
            render(newValue)
        } else {
            value = newValue
        }
    }

    /// Registers the renderer for this section, running it immediately if the data already landed.
    func onReady(_ newRender: @escaping (T) -> Void) {
        if let value {
            self.value = nil
            newRender(value)
        } else {
            render = newRender
        }
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    @Default(.refreshRate) var refreshRate
    @Default(.jql) var jql
    @Default(.orgName) var orgName
    @Default(.instanceType) var instanceType
    @Default(.jiraHost) var jiraHost
    @Default(.transitionPrompts) var transitionPrompts
    @Default(.statusOrder) var statusOrder
    @Default(.statusDisplay) var statusDisplay
    @Default(.dashboardURL) var dashboardURL
    @Default(.userFieldShortcuts) var userFieldShortcuts
    @Default(.flagFieldId) var flagFieldId
    @Default(.allIssuesJQL) var allIssuesJQL
    @Default(.myDashboardURL) var myDashboardURL
    @Default(.githubSearchOrgs) var githubSearchOrgs
    @Default(.jiraGithubUserMapPath) var jiraGithubUserMapPath
    @Default(.jiraGithubUserMapBookmark) var jiraGithubUserMapBookmark
    @Default(.githubPRReviewerJiraFieldId) var githubPRReviewerJiraFieldId
    @Default(.showMyPRsSection) var showMyPRsSection
    @Default(.todoJQL) var todoJQL
    @Default(.todoMaxResults) var todoMaxResults

    @FromKeychain(.gitHubToken) var gitHubToken

    let jiraClient = JiraClient()

    /// Base web URL for opening pages in the browser — mirrors JiraClient.baseUrl.
    private var baseUrl: String {
        switch instanceType {
        case .cloud:  return "https://\(orgName).atlassian.net"
        case .server: return jiraHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }
    
    var statusBarItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu: NSMenu = NSMenu()

    var timer: Timer? = nil
    
    var preferencesWindow: NSWindow!
    var aboutWindow: NSWindow!
    var transitionWindow: NSWindow?
    var commentWindow: NSWindow?
    var userFieldWindow: NSWindow?
    var flagWindow: NSWindow?
    var uploadWindow: NSWindow?
    var bulkMoveWindow: NSWindow?

    /// Snapshot of the issues currently rendered in the menu. Captured at each refresh so the
    /// bulk-move dialog has a list of candidates without a fresh API call.
    private var lastIssues: [Issue] = []

    /// Strong references to the submenu delegates (per-issue field-value loaders and the TODO
    /// section's lazy builder). `NSMenu.delegate` is a weak reference, so without this they'd
    /// be released the moment refreshMenu finished and their deferred work would never fire.
    /// Cleared on each refresh.
    private var submenuDelegates: [any NSMenuDelegate] = []

    /// Guards against overlapping menu rebuilds (timer fire racing a manual Refresh) — two
    /// concurrent builds would interleave items on the same NSMenu.
    private var isRefreshing = false

    /// Set once by `checkForUpdates` when a newer release exists; `refreshMenu` re-appends the
    /// "New version available" item on every rebuild (removeAllItems would otherwise eat it).
    private var latestReleaseURL: URL?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        migrateStatusOrderIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(AppDelegate.windowClosed), name: NSWindow.willCloseNotification, object: nil)
        guard let statusButton = statusBarItem.button else { return }
        let icon = NSImage(named: "mark-gradient-white-jira")
        // 16pt matches Apple's menu-bar-extras guidance and keeps the icon+count pair narrow.
        icon?.size = NSSize(width: 16, height: 16)
        icon?.isTemplate = true
        statusButton.image = icon
        statusButton.imagePosition = NSControl.ImagePosition.imageLeft
        // Snug the image and title together — the default 5pt gap between imageLeft and title
        // eats visible menu-bar real estate for no visual benefit.
        statusButton.imageHugsTitle = true
        
        statusBarItem.menu = menu

        scheduleRefreshTimer()

        NSApp.setActivationPolicy(.accessory)

        checkForUpdates()
    }

    /// (Re)creates the refresh timer. Constructed unscheduled and added to the run loop exactly
    /// once, in `.common` mode, so refreshes keep firing while a menu is held open — the old
    /// scheduledTimer + add(.common) pair registered the timer twice at launch and the
    /// post-Preferences reschedule dropped `.common` entirely.
    private func scheduleRefreshTimer() {
        timer?.invalidate()
        let t = Timer(
            timeInterval: Double(refreshRate * 60),
            target: self,
            selector: #selector(refreshMenu),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(t, forMode: .common)
        timer = t
        t.fire()
    }

    /// Moves any entries the user had under the legacy `statusOrder` [String] key into the
    /// richer `statusDisplay` array (one-time, when the new key is still empty).
    private func migrateStatusOrderIfNeeded() {
        if statusDisplay.isEmpty && !statusOrder.isEmpty {
            statusDisplay = statusOrder.map { StatusDisplay(name: $0) }
            statusOrder = []
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

}

extension AppDelegate {
    @objc
    func refreshMenu() {
        guard !isRefreshing else { return }
        isRefreshing = true
        NSLog("Refreshing menu")
        self.menu.removeAllItems()
        self.submenuDelegates.removeAll()

        // PRs Without Tickets section: the GitHub search runs in parallel with the Jira fetch, and the
        // per-issue PR collection below feeds the exclusion set (a PR already rendered under
        // a ticket must not repeat here). All of it joins on myPRsGroup.
        let myPRsEnabled = self.showMyPRsSection
            && !self.gitHubToken.trimmingCharacters(in: .whitespaces).isEmpty
        // Runs concurrently with the main search below — see startTodoFetch.
        let todoPending = self.startTodoFetch()
        let myPRsGroup = DispatchGroup()
        let collectedURLsQueue = DispatchQueue(label: "myPRs.collectedURLs")
        var collectedPRURLs = Set<String>()
        var myPRsResults: [JiraPullRequest] = []

        if myPRsEnabled {
            let orgs = self.githubSearchOrgs
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            myPRsGroup.enter()
            GithubClient().searchMyPRs(orgs: orgs, token: self.gitHubToken.trimmingCharacters(in: .whitespaces)) { prs in
                myPRsResults = prs
                myPRsGroup.leave()
            }
        }

        jiraClient.getIssuesByJql() { resp, ranks in
            self.isRefreshing = false
            if let issues = resp.issues {
                self.lastIssues = issues
                self.statusBarItem.button?.title = String(issues.count)
                let display = self.statusDisplay
                let positionFor: (String) -> Int = { name in
                    display.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? Int.max
                }
                let colorFor: (String) -> NSColor? = { name in
                    display.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.nsColor
                }
                let issuesByStatus = Dictionary(grouping: issues) { $0.fields.status.name }
                    .sorted { lhs, rhs in
                        let a = positionFor(lhs.key)
                        let b = positionFor(rhs.key)
                        if a != b { return a < b }
                        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                    }

                for (status, issuess) in issuesByStatus {
                    self.menu.addItem(.separator())
                    let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                    if let color = colorFor(status) {
                        statusItem.attributedTitle = NSAttributedString(
                            string: status,
                            attributes: [.foregroundColor: color]
                        )
                    }
                    self.menu.addItem(statusItem)

                    // Sort tickets within each status by Lexorank ascending (board order). Unranked
                    // issues drop to the bottom of the group, alphabetical by key as a tiebreaker.
                    let sortedIssues = issuess.sorted { lhs, rhs in
                        let lr = ranks[lhs.key] ?? ""
                        let rr = ranks[rhs.key] ?? ""
                        if !lr.isEmpty && !rr.isEmpty { return lr < rr }
                        if lr.isEmpty && rr.isEmpty {
                            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                        }
                        return !lr.isEmpty
                    }

                    for issue in sortedIssues {
                        let issueItem = self.makeIssueRow(for: issue)

                        // Balanced by the leave in onPRsCollected — every client completion
                        // fires on success and failure alike.
                        if myPRsEnabled { myPRsGroup.enter() }
                        self.attachIssueSubmenu(to: issueItem, issue: issue, onPRsCollected: myPRsEnabled ? { merged in
                            collectedURLsQueue.async {
                                collectedPRURLs.formUnion(merged.map(\.url))
                                myPRsGroup.leave()
                            }
                        } : nil)

                        self.menu.addItem(issueItem)
                    }
                }
            }
            else {
                self.statusBarItem.button?.title = String(0)
            }

            if let todoPending { self.appendTodoSection(todoPending) }

            // PRs Without Tickets sits between the status groups and the utility items. Its submenu is
            // attached (or the whole section removed) once the searches and the per-issue PR
            // collection both finish; the item doubles as the staleness marker — if a newer
            // refresh rebuilt the menu, it's gone and the late results are dropped. It has no
            // action of its own: until the real submenu lands it shows the "Waiting on data…" row
            // makeSectionHeader gives it, which is also what keeps it from greying out for good.
            // This is the longest of the async sections to fill in — it joins on the per-issue PR
            // collection as well as the search — so it's the one that row exists for.
            if myPRsEnabled {
                let separator = NSMenuItem.separator()
                let myPRsItem = AppDelegate.makeSectionHeader(
                    title: "PRs Without Tickets",
                    symbolName: "arrow.triangle.pull"
                )
                self.menu.addItem(separator)
                self.menu.addItem(myPRsItem)
                myPRsGroup.notify(queue: .main) {
                    self.populateMyPRsSubmenu(
                        results: myPRsResults,
                        excludedURLs: collectedPRURLs,
                        item: myPRsItem,
                        separator: separator
                    )
                }
            }

            self.menu.addItem(.separator())
            let refreshItem = NSMenuItem(title: "Refresh", action: #selector(self.refreshMenu), keyEquivalent: "")
            refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            self.menu.addItem(refreshItem)
            
            let openSearchResultsItem = NSMenuItem(title: "Open Search results", action: #selector(self.openSearchResults), keyEquivalent: "")
            openSearchResultsItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            self.menu.addItem(openSearchResultsItem)

            if !self.allIssuesJQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let openAllItem = NSMenuItem(title: "Open All Issues", action: #selector(self.openAllIssues), keyEquivalent: "")
                openAllItem.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
                self.menu.addItem(openAllItem)
            }

            if let url = self.resolveExternalURL(self.dashboardURL) {
                let openDashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(self.openDashboard), keyEquivalent: "")
                openDashboardItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
                openDashboardItem.representedObject = url
                self.menu.addItem(openDashboardItem)
            }

            if let url = self.resolveExternalURL(self.myDashboardURL) {
                let openMyDashboardItem = NSMenuItem(title: "Open My Dashboard", action: #selector(self.openDashboard), keyEquivalent: "")
                openMyDashboardItem.image = NSImage(systemSymbolName: "person.crop.rectangle.stack", accessibilityDescription: nil)
                openMyDashboardItem.representedObject = url
                self.menu.addItem(openMyDashboardItem)
            }
            
            let createNewItem = NSMenuItem(title: "Create issue", action: #selector(self.openCreateNewIssue), keyEquivalent: "")
            createNewItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            self.menu.addItem(createNewItem)

            if !self.lastIssues.isEmpty {
                let moveManyItem = NSMenuItem(title: "Move Multiple Issues…", action: #selector(self.openBulkMove), keyEquivalent: "")
                moveManyItem.image = NSImage(systemSymbolName: "arrow.left.arrow.right.square", accessibilityDescription: nil)
                self.menu.addItem(moveManyItem)
            }

            self.menu.addItem(.separator())
            self.menu.addItem(withTitle: "Preferences...", action: #selector(self.openPrefecencesWindow), keyEquivalent: "")
            self.menu.addItem(withTitle: "About JiraBar", action: #selector(self.openAboutWindow), keyEquivalent: "")
            self.menu.addItem(withTitle: "Quit", action: #selector(self.quit), keyEquivalent: "")
            self.appendUpdateItemIfNeeded()
        }
    }
    
    
    /// Starts the TODO backlog search, returning the handle `appendTodoSection` renders from —
    /// nil when no TODO JQL is configured, which is how the caller knows to skip the section.
    ///
    /// Fired at the top of a refresh, alongside the main JQL search and the GitHub PR search,
    /// rather than from inside the main search's completion. The TODO rows don't depend on the
    /// main result in any way, so waiting for it only widened the window where the section has
    /// nothing to show — by the full cost of the primary search (~0.3–0.5s against the author's
    /// instance, visible in the unified log as one Jira request wave strictly following another).
    private func startTodoFetch() -> PendingSection<[Issue]>? {
        let query = todoJQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let pending = PendingSection<[Issue]>()
        jiraClient.getIssuesByJql(jql: query, maxResults: todoMaxResults) { resp, ranks in
            pending.deliver(AppDelegate.orderedByRank(resp.issues ?? [], ranks: ranks))
        }
        return pending
    }

    /// Adds the TODO section — a backlog rollup whose submenu lists the tickets matching the
    /// user's TODO JQL in board order, each carrying the same submenu it would have in the main
    /// ticket list.
    ///
    /// Only the ticket rows are built up front; their submenus are populated the first time the
    /// TODO menu is opened (see `LazyMenuDelegate`). Removes the section when the query comes
    /// back empty, and drops results whose item a newer refresh already discarded.
    private func appendTodoSection(_ pending: PendingSection<[Issue]>) {
        let separator = NSMenuItem.separator()
        let todoItem = AppDelegate.makeSectionHeader(title: "TODO", symbolName: "checklist.unchecked")
        menu.addItem(separator)
        menu.addItem(todoItem)

        pending.onReady { [weak self] issues in
            guard let self else { return }
            guard self.menu.index(of: todoItem) != -1 else { return }
            guard !issues.isEmpty else {
                self.menu.removeItem(todoItem)
                if self.menu.index(of: separator) != -1 { self.menu.removeItem(separator) }
                return
            }

            let todoMenu = NSMenu()
            var rows: [(NSMenuItem, Issue)] = []
            for issue in issues {
                let row = self.makeIssueRow(for: issue)
                todoMenu.addItem(row)
                rows.append((row, issue))
            }
            let delegate = LazyMenuDelegate {
                for (row, issue) in rows {
                    self.attachIssueSubmenu(to: row, issue: issue, onPRsCollected: nil)
                }
            }
            todoMenu.delegate = delegate
            self.submenuDelegates.append(delegate)
            todoItem.submenu = todoMenu
        }
    }

    /// Builds the header item for a section whose rows arrive asynchronously (TODO, PRs Without
    /// Tickets), carrying a placeholder submenu with a single disabled "Waiting on data…" row.
    ///
    /// That placeholder submenu is load-bearing, not decoration. NSMenu's automatic enabling
    /// latches: an item with no action and no submenu is disabled by the first enabling pass —
    /// which AppKit runs when the menu is opened — and attaching a submenu afterwards does *not*
    /// bring it back, no matter how many enabling passes follow. So a section header added bare
    /// and filled in from a network completion renders greyed out and stays that way for the rest
    /// of that menu's life whenever the user reopens the menu before the data lands, which is
    /// exactly what happens on a manual Refresh (the click closes the menu; they reopen it right
    /// away). Shipping the header with a submenu already attached keeps it enabled through every
    /// enabling pass, and turns the wait into visible "Waiting on data…" instead of a dead label.
    ///
    /// Callers replace `submenu` wholesale once their data arrives; the item stays enabled across
    /// the swap. A section with nothing to show still has to remove its header — leaving an empty
    /// submenu behind would render an enabled header that opens onto nothing.
    ///
    /// The row is deliberately static text rather than a spinner. An open NSMenu runs a modal
    /// tracking run loop (`NSEventTrackingRunLoopMode`), and NSProgressIndicator does not animate
    /// in it: measured 1 distinct frame across 28 samples over ~2.2s of tracking, unchanged by
    /// `usesThreadedAnimation` or by forcing the view layer-backed. A spinner stopped mid-frame
    /// reads as a hung app — strictly worse than saying nothing is wrong. Motion *is* achievable
    /// by driving it ourselves from a Timer registered in `.common` mode (a `.default` timer never
    /// fires while tracking: 0 ticks vs 18 in the same window), but that means either a custom
    /// `NSMenuItem.view`, which doesn't pick up standard menu row metrics or highlighting and so
    /// wouldn't match the real rows it's replaced by, or a live repeating timer whose lifetime has
    /// to be tied to a placeholder that exists for barely a second. Neither is worth it for a wait
    /// this short; the honest fix for the wait is to shorten it, not to decorate it.
    static func makeSectionHeader(title: String, symbolName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let placeholder = NSMenu()
        let waitingRow = NSMenuItem(title: "Waiting on data…", action: nil, keyEquivalent: "")
        waitingRow.isEnabled = false
        placeholder.addItem(waitingRow)
        item.submenu = placeholder
        return item
    }

    /// Builds the two-line ticket row: truncated summary, then `#KEY · assignee · type`.
    /// Clicking opens the ticket in the browser. The submenu is attached separately by
    /// `attachIssueSubmenu` so callers can decide when to pay for it.
    private func makeIssueRow(for issue: Issue) -> NSMenuItem {
        let issueItem = NSMenuItem(title: "", action: #selector(self.openLink), keyEquivalent: "")
        issueItem.attributedTitle = NSMutableAttributedString(string: "")
            .appendString(string: issue.fields.summary.trunc(length: 50))
            .appendNewLine()
            .appendIcon(iconName: "hash", color: NSColor.gray)
            .appendString(string: issue.key, color: "#888888")
            .appendSeparator()
            .appendString(string: issue.fields.assignee?.displayName ?? "Unassign", color: "#888888")
            .appendSeparator()
            .appendString(string: issue.fields.issuetype.name, color: "#888888")
        issueItem.representedObject = URL(string: "\(self.baseUrl)/browse/\(issue.key)")
        return issueItem
    }

    /// Fetches the ticket's transitions and linked PRs, then hangs the full per-issue submenu
    /// off `item`: transitions, the copy shortcuts, comment/flag/upload, the configured
    /// user-field shortcuts (whose current values load lazily on hover), and PR rows.
    ///
    /// `onPRsCollected` receives the merged PR list so the main-menu path can feed the
    /// PRs Without Tickets exclusion set. It's nil for TODO rows, which are built lazily and
    /// may never be opened — that section can't wait on work that might not happen.
    private func attachIssueSubmenu(
        to item: NSMenuItem,
        issue: Issue,
        onPRsCollected: (([JiraPullRequest]) -> Void)?
    ) {
        jiraClient.getTransitionsByIssueKey(issueKey: issue.key) { transitions in
            let issueMenu = NSMenu()
            item.submenu = issueMenu
            if !transitions.isEmpty {
                let header = NSMenuItem(title: "Transition to...", action: nil, keyEquivalent: "")
                issueMenu.addItem(header)
                for transition in transitions {
                    let transitionItem = NSMenuItem(title: transition.name, action: #selector(self.transitionIssue), keyEquivalent: "")
                    transitionItem.representedObject = [issue.key, transition.id, transition.name]
                    issueMenu.addItem(transitionItem)
                }
                issueMenu.addItem(.separator())
            }

            let copyKeyItem = NSMenuItem(title: "Copy Key", action: #selector(self.copyToClipboard), keyEquivalent: "")
            copyKeyItem.representedObject = issue.key
            issueMenu.addItem(copyKeyItem)

            let copyURLItem = NSMenuItem(title: "Copy URL", action: #selector(self.copyToClipboard), keyEquivalent: "")
            copyURLItem.representedObject = "\(self.baseUrl)/browse/\(issue.key)"
            issueMenu.addItem(copyURLItem)

            let copyTitleItem = NSMenuItem(title: "Copy Title", action: #selector(self.copyToClipboard), keyEquivalent: "")
            copyTitleItem.representedObject = issue.fields.summary
            issueMenu.addItem(copyTitleItem)

            let copyBranchItem = NSMenuItem(title: "Copy Branch Name", action: #selector(self.copyToClipboard), keyEquivalent: "")
            copyBranchItem.representedObject = AppDelegate.branchName(forKey: issue.key, title: issue.fields.summary)
            issueMenu.addItem(copyBranchItem)

            let copyPRItem = NSMenuItem(title: "Copy PR Name", action: #selector(self.copyToClipboard), keyEquivalent: "")
            copyPRItem.representedObject = "[\(issue.key)] \(issue.fields.summary)"
            issueMenu.addItem(copyPRItem)

            issueMenu.addItem(.separator())

            let addCommentItem = NSMenuItem(title: "Add Comment", action: #selector(self.addCommentToIssue), keyEquivalent: "")
            addCommentItem.representedObject = issue.key
            issueMenu.addItem(addCommentItem)

            if !self.flagFieldId.trimmingCharacters(in: .whitespaces).isEmpty {
                let addFlagItem = NSMenuItem(title: "Add Flag", action: #selector(self.addFlagToIssue), keyEquivalent: "")
                addFlagItem.representedObject = issue.key
                issueMenu.addItem(addFlagItem)
            }

            let uploadItem = NSMenuItem(title: "Upload Files", action: #selector(self.openUploadFiles), keyEquivalent: "")
            uploadItem.representedObject = issue.key
            issueMenu.addItem(uploadItem)

            let shortcuts = self.userFieldShortcuts.filter {
                !$0.label.trimmingCharacters(in: .whitespaces).isEmpty &&
                !$0.fieldId.trimmingCharacters(in: .whitespaces).isEmpty
            }
            let colorForStatus: (String) -> NSColor? = { [weak self] name in
                self?.statusDisplay.first {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }?.nsColor
            }
            var shortcutTargets: [IssueSubmenuDelegate.Target] = []
            for shortcut in shortcuts {
                let shortcutItem = NSMenuItem(title: shortcut.label, action: #selector(self.openUserFieldChange), keyEquivalent: "")
                shortcutItem.representedObject = IssueShortcutTarget(issueKey: issue.key, shortcut: shortcut)
                issueMenu.addItem(shortcutItem)
                // Per-shortcut override — e.g. always show "Change Reviewer" users
                // in the Review status color regardless of what status the ticket
                // is currently in.
                let overrideName = shortcut.colorFromStatus.trimmingCharacters(in: .whitespaces)
                let overrideColor = overrideName.isEmpty ? nil : colorForStatus(overrideName)
                shortcutTargets.append(.init(
                    fieldId: shortcut.fieldId,
                    label: shortcut.label,
                    color: overrideColor,
                    item: shortcutItem
                ))
            }
            if !shortcutTargets.isEmpty {
                let fallbackColor = colorForStatus(issue.fields.status.name)
                let delegate = IssueSubmenuDelegate(
                    issueKey: issue.key,
                    targets: shortcutTargets,
                    fallbackColor: fallbackColor,
                    jiraClient: self.jiraClient
                )
                issueMenu.delegate = delegate
                self.submenuDelegates.append(delegate)
            }

            self.jiraClient.getIssuePullRequests(issueId: issue.id) { prs in
                self.prsWithGithubFallback(prs, issueKey: issue.key) { merged in
                    onPRsCollected?(merged)
                    guard !merged.isEmpty else { return }
                    self.fetchGithubStatuses(for: merged) { statusByURL in
                        DispatchQueue.main.async {
                            issueMenu.addItem(.separator())
                            for pr in merged {
                                self.addPRMenuItem(pr: pr, ghStatus: statusByURL[pr.url], to: issueMenu)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Orders backlog tickets the way the board does: by Lexorank ascending when a rank field
    /// is configured. Unranked tickets sink below ranked ones, and ties keep the order Jira
    /// returned — so with no rank field set at all, any `ORDER BY` in the user's TODO JQL
    /// survives untouched.
    static func orderedByRank(_ issues: [Issue], ranks: [String: String]) -> [Issue] {
        issues.enumerated().sorted { lhs, rhs in
            let lr = ranks[lhs.element.key] ?? ""
            let rr = ranks[rhs.element.key] ?? ""
            if lr.isEmpty != rr.isEmpty { return !lr.isEmpty }
            if !lr.isEmpty && lr != rr { return lr < rr }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    @objc
    func transitionIssue(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count >= 2 else { return }
        let issueKey = parts[0]
        let transitionId = parts[1]
        let transitionName = parts.count >= 3 ? parts[2] : ""

        if let config = transitionPrompts.first(where: { $0.matches(transitionName: transitionName) }) {
            presentTransitionDialog(
                issueKey: issueKey,
                transitionId: transitionId,
                transitionName: transitionName,
                config: config
            )
            return
        }

        jiraClient.transitionIssue(issueKey: issueKey, to: transitionId) {
            self.refreshMenu()
        }
    }

    @objc
    func openBulkMove(_ sender: NSMenuItem) {
        presentBulkMoveDialog()
    }

    /// Shared presenter for the transient SwiftUI dialogs (bulk-move, upload, flag,
    /// user-field, comment, transition): closes any previous instance, hosts the view in a
    /// fresh non-released window stored at `keyPath`, and brings it frontmost. Preferences
    /// and About keep their own presenters — different lifecycle (IUO windows, no onCancel
    /// plumbing) and a documented CA-commit workaround.
    private func presentDialog<V: View>(
        _ view: V,
        title: String,
        size: NSSize,
        window keyPath: ReferenceWritableKeyPath<AppDelegate, NSWindow?>
    ) {
        self[keyPath: keyPath]?.close()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()

        self[keyPath: keyPath] = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentBulkMoveDialog() {
        let view = BulkMoveDialog(
            issues: self.lastIssues,
            transitionPrompts: self.transitionPrompts,
            statusOrder: self.statusDisplay,
            showMirrorFor: { [weak self] fieldId in
                self?.shouldShowGithubMirrorCheckbox(forJiraFieldId: fieldId) ?? false
            },
            onSubmit: { [weak self] successfulKeys, users, failure, updateGithub in
                DispatchQueue.main.async {
                    let success = successfulKeys.count
                    let message: String
                    if failure == 0 {
                        message = "Moved \(success) issue\(success == 1 ? "" : "s")"
                    } else if success == 0 {
                        message = "Move failed for all \(failure) issue\(failure == 1 ? "" : "s")"
                    } else {
                        message = "Moved \(success), failed \(failure)"
                    }
                    sendNotification(body: message)
                    self?.bulkMoveWindow?.close()
                    self?.bulkMoveWindow = nil
                    self?.refreshMenu()

                    if updateGithub, let self {
                        // Fan out the GitHub mirror after the bulk move commits — one call per
                        // successfully-transitioned issue, each posting its own summary
                        // notification (issues without a linked PR are already handled gracefully
                        // by `mirrorReviewersToGithub`).
                        for key in successfulKeys {
                            self.mirrorReviewersToGithub(issueKey: key, jiraReviewers: users)
                        }
                    }
                }
            },
            onCancel: { [weak self] in
                self?.bulkMoveWindow?.close()
                self?.bulkMoveWindow = nil
            }
        )
        presentDialog(view, title: "Move Multiple Issues", size: NSSize(width: 600, height: 700), window: \.bulkMoveWindow)
    }

    @objc
    func addCommentToIssue(_ sender: NSMenuItem) {
        guard let issueKey = sender.representedObject as? String else { return }
        presentCommentDialog(issueKey: issueKey)
    }

    @objc
    func openUploadFiles(_ sender: NSMenuItem) {
        guard let issueKey = sender.representedObject as? String else { return }
        presentUploadDialog(issueKey: issueKey)
    }

    private func presentUploadDialog(issueKey: String) {
        let view = UploadFilesDialog(
            issueKey: issueKey,
            onSubmit: { [weak self] urls, comment, done in
                self?.jiraClient.uploadAttachments(
                    issueKey: issueKey,
                    files: urls,
                    comment: comment.isEmpty ? nil : comment
                ) { success in
                    DispatchQueue.main.async {
                        if success {
                            self?.uploadWindow?.close()
                            self?.uploadWindow = nil
                            self?.refreshMenu()
                        }
                        done(success)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.uploadWindow?.close()
                self?.uploadWindow = nil
            }
        )
        presentDialog(view, title: "Upload: \(issueKey)", size: NSSize(width: 520, height: 540), window: \.uploadWindow)
    }

    @objc
    func addFlagToIssue(_ sender: NSMenuItem) {
        guard let issueKey = sender.representedObject as? String else { return }
        presentFlagDialog(issueKey: issueKey)
    }

    private func presentFlagDialog(issueKey: String) {
        let view = FlagDialog(
            issueKey: issueKey,
            onSubmit: { [weak self] comment, done in
                guard let self else { done(false); return }
                self.jiraClient.flagIssue(
                    issueKey: issueKey,
                    flagFieldId: self.flagFieldId,
                    comment: comment.isEmpty ? nil : comment
                ) { success in
                    DispatchQueue.main.async {
                        if success {
                            self.flagWindow?.close()
                            self.flagWindow = nil
                            self.refreshMenu()
                        }
                        done(success)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.flagWindow?.close()
                self?.flagWindow = nil
            }
        )
        presentDialog(view, title: "Flag: \(issueKey)", size: NSSize(width: 480, height: 260), window: \.flagWindow)
    }

    @objc
    func openUserFieldChange(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? IssueShortcutTarget else { return }
        presentUserFieldDialog(issueKey: target.issueKey, shortcut: target.shortcut)
    }

    private func presentUserFieldDialog(issueKey: String, shortcut: UserFieldShortcut) {
        let showMirror = shouldShowGithubMirrorCheckbox(forJiraFieldId: shortcut.fieldId)
        let view = UserFieldDialog(
            issueKey: issueKey,
            shortcut: shortcut,
            showGithubMirrorCheckbox: showMirror,
            onSubmit: { [weak self] users, updateGithub, done in
                self?.jiraClient.setIssueUsers(
                    issueKey: issueKey,
                    fieldId: shortcut.fieldId,
                    users: users,
                    multi: shortcut.allowsMultiple
                ) { success in
                    DispatchQueue.main.async {
                        if success {
                            self?.userFieldWindow?.close()
                            self?.userFieldWindow = nil
                            self?.refreshMenu()
                            if updateGithub {
                                self?.mirrorReviewersToGithub(issueKey: issueKey, jiraReviewers: users)
                            }
                        }
                        done(success)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.userFieldWindow?.close()
                self?.userFieldWindow = nil
            }
        )
        presentDialog(view, title: "\(shortcut.label): \(issueKey)", size: NSSize(width: 520, height: 440), window: \.userFieldWindow)
    }

    private func presentCommentDialog(issueKey: String) {
        let view = CommentDialog(
            issueKey: issueKey,
            onSubmit: { [weak self] comment, done in
                self?.jiraClient.addComment(issueKey: issueKey, comment: comment) { success in
                    DispatchQueue.main.async {
                        if success {
                            self?.commentWindow?.close()
                            self?.commentWindow = nil
                            self?.refreshMenu()
                        }
                        done(success)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.commentWindow?.close()
                self?.commentWindow = nil
            }
        )
        presentDialog(view, title: "Comment: \(issueKey)", size: NSSize(width: 520, height: 280), window: \.commentWindow)
    }

    private func presentTransitionDialog(
        issueKey: String,
        transitionId: String,
        transitionName: String,
        config: TransitionPromptConfig
    ) {
        let showMirror = config.hasUserField
            && shouldShowGithubMirrorCheckbox(forJiraFieldId: config.userFieldId)
        let prStatus = PRActionsStatus()
        if config.hasPRActions {
            populatePRActionsStatus(prStatus, issueKey: issueKey)
        } else {
            prStatus.loading = false
        }
        let view = TransitionDialog(
            issueKey: issueKey,
            transitionName: transitionName,
            config: config,
            showGithubMirrorCheckbox: showMirror,
            prStatus: prStatus,
            onSubmit: { [weak self] comment, users, freeText, selectValue, updateGithub, prActions, done in
                self?.submitTransition(
                    issueKey: issueKey,
                    transitionId: transitionId,
                    config: config,
                    comment: comment,
                    users: users,
                    freeText: freeText,
                    selectValue: selectValue,
                    updateGithub: updateGithub,
                    prActions: prActions,
                    prStatus: prStatus,
                    completion: done
                )
            },
            onCancel: { [weak self] in
                self?.transitionWindow?.close()
                self?.transitionWindow = nil
            }
        )
        presentDialog(view, title: "Transition: \(transitionName)", size: NSSize(width: 520, height: 480), window: \.transitionWindow)
    }

    private func submitTransition(
        issueKey: String,
        transitionId: String,
        config: TransitionPromptConfig,
        comment: String,
        users: [JiraUser],
        freeText: String,
        selectValue: String,
        updateGithub: Bool,
        prActions: PRActionChoices,
        prStatus: PRActionsStatus,
        completion: @escaping (TransitionSubmitOutcome) -> Void
    ) {
        let updates = config.fieldUpdates(users: users, freeText: freeText, selectValue: selectValue)

        let effectiveComment = config.includeComment ? comment : nil
        // Pinned now, not read at completion time: the batch can outlive this dialog being replaced.
        let submittedFrom = transitionWindow

        jiraClient.transitionIssue(
            issueKey: issueKey,
            to: transitionId,
            comment: effectiveComment,
            fieldUpdates: updates
        ) { [weak self] result in
            DispatchQueue.main.async {
                if case .failed(let message, let fieldsWritten) = result {
                    // Jira refused, or was unreachable. The window stays up carrying the server's
                    // own words — a message like "Testers are required before moving into QA." is
                    // only useful where it can be read.
                    completion(.jiraRefused(
                        message: message ?? "Jira rejected the transition and gave no reason.",
                        fieldsWritten: fieldsWritten
                    ))
                    return
                }
                self?.refreshMenu()
                if updateGithub, config.hasUserField {
                    self?.mirrorReviewersToGithub(issueKey: issueKey, jiraReviewers: users)
                }
                guard prActions.hasWork else {
                    self?.closeTransitionWindow(submittedFrom)
                    completion(.applied)
                    return
                }
                // The window deliberately stays open until the PR actions land. Closing here is
                // what used to make a failed review invisible: the ticket had moved, the window
                // had gone, and only a notification carried the bad news.
                self?.applyPRActions(issueKey: issueKey, actions: prActions, prStatus: prStatus) { tally in
                    switch tally.report {
                    case .clean:
                        self?.closeTransitionWindow(submittedFrom)
                        completion(.applied)
                    case .nothingRan(let reason):
                        completion(.prActionsDidNotRun(reason: reason))
                    case .failures(let lines):
                        completion(.prActionsIncomplete(lines: lines))
                    }
                }
            }
        }
    }

    /// Closes the transition window only if it is still the one that submitted. The window now
    /// stays up for the whole GitHub batch, so "submit A, reopen the menu, start B" is reachable —
    /// and A's completion must not close B's half-filled dialog.
    private func closeTransitionWindow(_ expected: NSWindow?) {
        guard let expected, transitionWindow === expected else { return }
        transitionWindow?.close()
        transitionWindow = nil
    }
    
    @objc
    func openSearchResults() {
        guard let encoded = jql.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseUrl)/issues?jql=" + encoded)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    func openAllIssues() {
        let trimmed = allIssuesJQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseUrl)/issues?jql=" + encoded)
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Turns a user-supplied URL preference into an openable URL.
    /// Accepts an absolute `http(s)://…` URL, or a path that's appended to the Jira base URL.
    /// Empty / whitespace-only input returns nil so the corresponding menu entry can be skipped.
    private func resolveExternalURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return URL(string: baseUrl + path)
    }

    @objc
    func openDashboard(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc
    func openCreateNewIssue() {
        guard let url = URL(string: "\(baseUrl)/secure/CreateIssue!default.jspa") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc
    func copyToClipboard(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    @objc
    func openPrefecencesWindow(_: NSStatusBarButton?) {
        NSLog("Open preferences window")
        if preferencesWindow != nil {
            preferencesWindow.close()
        }
        // Size the window up-front to match PreferencesView's frame; otherwise the hosting view
        // resizes the window mid-layout and AppKit logs a layout-recursion warning.
        preferencesWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 760),
            styleMask: [.closable, .titled],
            backing: .buffered,
            defer: false
        )
        // Keep the window alive across close so reopening doesn't fight a released window —
        // the previous default (isReleasedWhenClosed = true) was a source of CA-commit warnings
        // on the second open.
        preferencesWindow.isReleasedWhenClosed = false
        preferencesWindow.title = "Preferences"
        preferencesWindow.contentView = NSHostingView(rootView: PreferencesView())
        preferencesWindow.center()

        NSApplication.shared.activate(ignoringOtherApps: true)
        preferencesWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc
    func openAboutWindow(_: NSStatusBarButton?) {
        NSLog("Open about window")
        if aboutWindow != nil {
            aboutWindow.close()
        }
        aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 340),
            styleMask: [.closable, .titled],
            backing: .buffered,
            defer: false
        )
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.title = "About"
        aboutWindow.contentView = NSHostingView(rootView: AboutView())
        aboutWindow.center()

        NSApplication.shared.activate(ignoringOtherApps: true)
        aboutWindow.makeKeyAndOrderFront(nil)
    }
    
    /// Builds a git-safe branch name like `PROJ-1234-fix-flaky-login`. Title is lowercased,
    /// non-alphanumerics become hyphens, runs collapse, leading/trailing hyphens stripped,
    /// title slug is capped so the full branch stays under ~60 chars.
    static func branchName(forKey key: String, title: String, maxSlugLength: Int = 50) -> String {
        var chars: [Character] = []
        for ch in title.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                chars.append(ch)
            } else {
                chars.append("-")
            }
        }
        var slug = String(chars)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > maxSlugLength {
            slug = String(slug.prefix(maxSlugLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug.isEmpty ? key : "\(key)-\(slug)"
    }

    /// True when the mirror-to-GitHub checkbox should appear for a dialog editing this Jira
    /// field. Requires: the field is the configured "PR reviewer" Jira field, a GitHub token,
    /// and a mapping file path — the mirror can't do anything useful without all three.
    private func shouldShowGithubMirrorCheckbox(forJiraFieldId fieldId: String) -> Bool {
        let target = self.githubPRReviewerJiraFieldId.trimmingCharacters(in: .whitespaces)
        let candidate = fieldId.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, target == candidate else { return false }
        guard !self.gitHubToken.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !self.jiraGithubUserMapPath.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return true
    }

    /// Mirrors the Jira reviewer picker onto the linked GitHub PR(s): adds me (looked up in
    /// the mapping file via my own Jira accountId) to the PR assignees, and adds the selected
    /// Jira users as requested reviewers. Fire-and-forget with a notification summary — the
    /// Jira update has already committed by the time this runs, so we degrade gracefully on
    /// any failure. Only touches OPEN PRs on github.com.
    private func mirrorReviewersToGithub(issueKey: String, jiraReviewers: [JiraUser]) {
        let token = self.gitHubToken.trimmingCharacters(in: .whitespaces)
        let mapPath = self.jiraGithubUserMapPath.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty,
              let map = JiraGithubUserMap.load(fromPath: mapPath, bookmark: self.jiraGithubUserMapBookmark)
        else {
            sendNotification(body: "GitHub PR update skipped: mapping file not loaded.")
            return
        }

        let reviewerLogins: [String] = jiraReviewers.compactMap { user in
            guard let accountId = user.accountId, !accountId.isEmpty else { return nil }
            return map.githubLogin(forJiraAccountId: accountId)
        }
        let unmappedReviewers = jiraReviewers.filter { user in
            guard let accountId = user.accountId, !accountId.isEmpty else { return true }
            return map.githubLogin(forJiraAccountId: accountId) == nil
        }

        // Resolve "me" via my own Jira accountId → GitHub login (same map).
        jiraClient.getCurrentUser { [weak self] me in
            guard let self else { return }
            let myGithub: String? = {
                guard let accountId = me?.accountId, !accountId.isEmpty else { return nil }
                return map.githubLogin(forJiraAccountId: accountId)
            }()

            self.jiraClient.getIssueId(byKey: issueKey) { issueId in
                guard let issueId else {
                    sendNotification(body: "GitHub PR update skipped: could not look up \(issueKey).")
                    return
                }
                self.jiraClient.getIssuePullRequests(issueId: issueId) { prs in
                    self.prsWithGithubFallback(prs, issueKey: issueKey) { merged in
                        let openGithubPRs = merged.filter {
                            $0.status.uppercased() == "OPEN" && $0.url.contains("github.com")
                        }
                        guard !openGithubPRs.isEmpty else {
                            sendNotification(body: "GitHub PR update skipped: no open PR linked to \(issueKey).")
                            return
                        }
                        self.applyGithubMirror(
                            prs: openGithubPRs,
                            myGithubLogin: myGithub,
                            desiredReviewerLogins: reviewerLogins,
                            knownGithubLogins: map.knownGithubLogins,
                            unmappedReviewerNames: unmappedReviewers.map(\.displayName),
                            token: token,
                            issueKey: issueKey
                        )
                    }
                }
            }
        }
    }

    /// Second half of the mirror flow — syncs each open PR to match the Jira reviewer set.
    /// Reviewers already on the PR that aren't in the mapping file are left alone so
    /// external contributors aren't accidentally removed. Posts one summary notification.
    private func applyGithubMirror(
        prs: [JiraPullRequest],
        myGithubLogin: String?,
        desiredReviewerLogins: [String],
        knownGithubLogins: Set<String>,
        unmappedReviewerNames: [String],
        token: String,
        issueKey: String
    ) {
        let client = GithubClient()
        let group = DispatchGroup()
        let syncQueue = DispatchQueue(label: "githubMirror.sync")
        var assignFailures = 0
        var addFailures = 0
        var removeFailures = 0
        // Reviewer changes are per-PR (they depend on that PR's current state), so use max
        // (union of add+remove attempts) rather than assuming every PR has both.
        var reviewerAttempted = 0
        // PRs whose current reviewer list couldn't be read — sync is skipped for those
        // entirely, because diffing against an unknown state would remove people on any
        // auth/network failure.
        var reviewerFetchFailures = 0

        // Case-fold both sides — GitHub API comparisons are case-insensitive on logins.
        let desiredSet = Set(desiredReviewerLogins.map { $0.lowercased() })

        for pr in prs {
            if let me = myGithubLogin {
                group.enter()
                client.addPRAssignees(url: pr.url, assignees: [me], token: token) { ok in
                    syncQueue.async {
                        if !ok { assignFailures += 1 }
                        group.leave()
                    }
                }
            }

            group.enter()
            client.getPRRequestedReviewers(url: pr.url, token: token) { current in
                guard let current else {
                    syncQueue.async {
                        reviewerFetchFailures += 1
                        group.leave()
                    }
                    return
                }
                let currentSet = Set(current.map { $0.lowercased() })
                // Add anyone in the ticket's list who isn't already requested on the PR.
                let toAdd = desiredReviewerLogins.filter { !currentSet.contains($0.lowercased()) }
                // Remove anyone requested on the PR who's in our mapping (i.e. "ours to touch")
                // but isn't on the ticket right now. Anyone outside the map stays.
                let toRemove = current.filter { login in
                    let lc = login.lowercased()
                    return knownGithubLogins.contains(lc) && !desiredSet.contains(lc)
                }

                var didAttempt = false

                if !toAdd.isEmpty {
                    didAttempt = true
                    group.enter()
                    client.requestPRReviewers(url: pr.url, reviewers: toAdd, token: token) { ok in
                        syncQueue.async {
                            if !ok { addFailures += 1 }
                            group.leave()
                        }
                    }
                }
                if !toRemove.isEmpty {
                    didAttempt = true
                    group.enter()
                    client.removePRReviewers(url: pr.url, reviewers: toRemove, token: token) { ok in
                        syncQueue.async {
                            if !ok { removeFailures += 1 }
                            group.leave()
                        }
                    }
                }

                syncQueue.async {
                    if didAttempt { reviewerAttempted += 1 }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            var parts: [String] = []
            if myGithubLogin != nil {
                let ok = prs.count - assignFailures
                parts.append("assigned \(ok)/\(prs.count)")
            } else {
                parts.append("no GitHub login for you in map — assignee skipped")
            }
            if reviewerAttempted > 0 {
                let failures = addFailures + removeFailures
                parts.append("reviewers synced on \(reviewerAttempted - min(failures, reviewerAttempted))/\(reviewerAttempted)")
            } else if !prs.isEmpty && reviewerFetchFailures == 0 {
                parts.append("reviewers already in sync")
            }
            if reviewerFetchFailures > 0 {
                parts.append("couldn't read reviewers on \(reviewerFetchFailures) PR\(reviewerFetchFailures == 1 ? "" : "s") — sync skipped")
            }
            if !unmappedReviewerNames.isEmpty {
                parts.append("unmapped: \(unmappedReviewerNames.joined(separator: ", "))")
            }
            sendNotification(body: "GitHub PR update for \(issueKey): \(parts.joined(separator: "; ")).")
        }
    }

    /// Populates the transition dialog's PR-actions status view-model: resolves the ticket's
    /// linked open GitHub PRs, enriches each via GraphQL (approval state, current assignees,
    /// repo merge-methods), and reports whether the Jira ticket's assignee is the current user.
    /// All updates land on the main thread since `PRActionsStatus` drives SwiftUI.
    private func populatePRActionsStatus(_ status: PRActionsStatus, issueKey: String) {
        let token = self.gitHubToken.trimmingCharacters(in: .whitespaces)

        // Jira side: assignee display + is-me check. Independent of GitHub, fires in parallel.
        // A failed read (nil) renders the same as unassigned — display-only here.
        jiraClient.getIssueFieldUsers(issueKey: issueKey, fieldId: "assignee") { [weak self] assignees in
            guard let self else { return }
            let assignee = assignees?.first
            self.jiraClient.getCurrentUser { me in
                DispatchQueue.main.async {
                    status.jiraAssigneeName = assignee?.displayName
                    if let a = assignee?.accountId, let m = me?.accountId, !a.isEmpty, !m.isEmpty {
                        status.jiraAssignedToMe = (a == m)
                    } else if let a = assignee?.name, let m = me?.name, !a.isEmpty, !m.isEmpty {
                        status.jiraAssignedToMe = (a == m)
                    } else {
                        status.jiraAssignedToMe = false
                    }
                }
            }
        }

        // GitHub side: linked PRs + enrichment. Everything below no-ops without a token.
        jiraClient.getIssueId(byKey: issueKey) { [weak self] issueId in
            guard let self else { return }
            guard let issueId else {
                DispatchQueue.main.async { status.loading = false }
                return
            }
            self.jiraClient.getIssuePullRequests(issueId: issueId) { prs in
                self.prsWithGithubFallback(prs, issueKey: issueKey) { merged in
                    let openGithub = merged.filter {
                        $0.status.uppercased() == "OPEN" && $0.url.contains("github.com")
                    }
                    guard !token.isEmpty, !openGithub.isEmpty else {
                        DispatchQueue.main.async {
                            status.openPRs = []
                            status.loading = false
                        }
                        return
                    }
                    let group = DispatchGroup()
                    let syncQueue = DispatchQueue(label: "prActions.status")
                    var results: [String: PRActionsStatus.LinkedPR] = [:]
                    let client = GithubClient()
                    for pr in openGithub {
                        group.enter()
                        client.fetchPRStatus(url: pr.url, token: token) { gh in
                            let entry = PRActionsStatus.LinkedPR(
                                url: pr.url,
                                label: "\(pr.repoSlug) #\(pr.numberOnly)",
                                isMerged: gh?.isMerged ?? false,
                                viewerApproved: gh?.viewerLatestReviewState == "APPROVED",
                                viewerRequestedChanges: gh?.viewerLatestReviewState == "CHANGES_REQUESTED",
                                assignees: gh?.assignees ?? [],
                                mergeCommitAllowed: gh?.mergeCommitAllowed ?? false,
                                squashMergeAllowed: gh?.squashMergeAllowed ?? false,
                                rebaseMergeAllowed: gh?.rebaseMergeAllowed ?? false
                            )
                            syncQueue.async {
                                results[pr.url] = entry
                                group.leave()
                            }
                        }
                    }
                    group.notify(queue: .main) {
                        status.openPRs = openGithub.compactMap { results[$0.url] }
                        status.loading = false
                    }
                }
            }
        }
    }

    /// Runs the transition dialog's PR-actions choices against every open linked PR: submits the
    /// chosen review (APPROVE or REQUEST_CHANGES), merges using the chosen method (skipping any
    /// repo that disallows it), and sets the Jira Assignee as PR Assignee when the PR has none.
    /// Uses the dialog's already-enriched `PRActionsStatus` so we don't re-fetch per action.
    ///
    /// Posts a single summary notification when the batch is done, and hands the same outcome to
    /// `completion` on the main queue so the still-open dialog can show which PRs failed. The Jira
    /// transition has already been applied by the time this runs, so a failure here can't be left
    /// to a notification the user may never look at.
    private func applyPRActions(
        issueKey: String,
        actions: PRActionChoices,
        prStatus: PRActionsStatus,
        completion: @escaping (PRActionTally) -> Void
    ) {
        let token = self.gitHubToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            sendNotification(body: "PR actions skipped for \(issueKey): no GitHub token set.")
            completion(PRActionTally(blockedReason: "No GitHub token is set, so no PR action ran."))
            return
        }
        let candidates = prStatus.openPRs.filter { !$0.isMerged }
        guard !candidates.isEmpty else {
            sendNotification(body: "PR actions skipped for \(issueKey): no open linked PRs.")
            completion(PRActionTally(blockedReason: "No open linked PRs were found, so no PR action ran."))
            return
        }

        let client = GithubClient()
        let group = DispatchGroup()
        // Every mutation of `tally` goes through this queue, and the final read is a `sync`
        // barrier on it — otherwise the skip counters, which no dispatch group waits on, can
        // still be in flight when the summary is built.
        let syncQueue = DispatchQueue(label: "prActions.apply")
        var tally = PRActionTally()
        // The denominator for the review summary: every candidate except the ones where the
        // review would add nothing. Empty when no review is going out at all, including the
        // blank-mandatory-comment case `reviewEvent` withholds.
        let reviewTargets: [PRActionsStatus.LinkedPR] = actions.reviewEvent == nil
            ? []
            : candidates.filter { !prStatus.resubmissionIsRedundant(actions.review, on: $0) }

        // Assignee sync needs the mapped GitHub login of the Jira assignee. Look it up once and
        // reuse across all PRs.
        let mapPath = self.jiraGithubUserMapPath.trimmingCharacters(in: .whitespaces)
        let map = JiraGithubUserMap.load(fromPath: mapPath, bookmark: self.jiraGithubUserMapBookmark)

        if let event = actions.reviewEvent {
            for pr in reviewTargets {
                group.enter()
                client.submitPRReview(url: pr.url, event: event, body: actions.trimmedReviewComment, token: token) { ok in
                    syncQueue.async {
                        if ok { tally.reviewOK += 1 } else { tally.reviewFailed.append(pr.label) }
                        group.leave()
                    }
                }
            }
        }

        // Reviews go out first; assignee sync + merges follow so they don't race a stale
        // "you haven't approved" merge-eligibility check on the GitHub side.
        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            let secondPassGroup = DispatchGroup()

            // Look up the Jira Assignee once (fresh — avoids a stale prStatus snapshot) and
            // reuse the mapped GitHub login across all eligible PRs.
            secondPassGroup.enter()
            self.jiraClient.getIssueFieldUsers(issueKey: issueKey, fieldId: "assignee") { assignees in
                if assignees == nil && actions.syncAssignee {
                    // Couldn't read the Jira assignee — sync degrades to a no-op, but the
                    // summary must say so rather than claim "already assigned".
                    syncQueue.async { tally.assigneeLookupFailed = true }
                }
                let mappedLogin: String? = {
                    guard actions.syncAssignee,
                          let map,
                          let accountId = assignees?.first?.accountId,
                          !accountId.isEmpty
                    else { return nil }
                    return map.githubLogin(forJiraAccountId: accountId)
                }()

                for pr in candidates {
                    if actions.syncAssignee {
                        if pr.assignees.isEmpty, let me = mappedLogin {
                            secondPassGroup.enter()
                            client.addPRAssignees(url: pr.url, assignees: [me], token: token) { ok in
                                syncQueue.async {
                                    if ok { tally.assignSet += 1 } else { tally.assignFailed.append(pr.label) }
                                    secondPassGroup.leave()
                                }
                            }
                        } else {
                            // Already assigned, or no login could be resolved for the
                            // Jira Assignee — nothing attempted.
                            syncQueue.async { tally.assignNotTouched += 1 }
                        }
                    }

                    if actions.merge {
                        if prStatus.allowsMergeMethod(actions.mergeMethod, on: pr) {
                            secondPassGroup.enter()
                            client.mergePR(url: pr.url, method: actions.mergeMethod, token: token) { ok in
                                syncQueue.async {
                                    if ok { tally.mergeOK += 1 } else { tally.mergeFailed.append(pr.label) }
                                    secondPassGroup.leave()
                                }
                            }
                        } else {
                            syncQueue.async { tally.mergeSkipped += 1 }
                        }
                    }
                }
                secondPassGroup.leave()
            }

            secondPassGroup.notify(queue: .main) {
                // Barrier read: drains every pending mutation before anything reports.
                let final = syncQueue.sync { tally }
                sendNotification(body: AppDelegate.prActionsSummaryBody(
                    issueKey: issueKey,
                    actions: actions,
                    candidateCount: candidates.count,
                    reviewTargetCount: reviewTargets.count,
                    tally: final
                ))
                completion(final)
            }
        }
    }

    /// What one `applyPRActions` batch actually did. Split out from the notification text so the
    /// wording — in particular that a failure never reads like a skip — is testable without a
    /// network round trip.
    struct PRActionTally {
        var reviewOK = 0
        var mergeOK = 0, mergeSkipped = 0
        var assignSet = 0, assignNotTouched = 0
        var assigneeLookupFailed = false
        /// Labels ("owner/repo #12") of the PRs each action was attempted on and failed. Labels
        /// rather than counts because the dialog has to name which PR of the three didn't take.
        var reviewFailed: [String] = []
        var mergeFailed: [String] = []
        var assignFailed: [String] = []
        /// Set when the batch never started — no token, no open PRs. Not a failure of an action;
        /// the dialog reports it as a reason nothing ran.
        var blockedReason: String?

        var reviewFail: Int { reviewFailed.count }
        var mergeFail: Int { mergeFailed.count }
        var assignFail: Int { assignFailed.count }

        /// Actions that were attempted against GitHub and came back refused or unreachable.
        /// Deliberately excludes the skip counters: not attempting something is not failing at it.
        var failureCount: Int { reviewFail + mergeFail + assignFail }

        /// One line per failed action, naming the PR. This is what the dialog lists, so the
        /// partial case — three linked PRs, the second one fails — points at the right PR.
        var failureLines: [String] {
            reviewFailed.map { "Review not submitted on \($0)" }
                + mergeFailed.map { "Merge failed on \($0)" }
                + assignFailed.map { "Assignee not set on \($0)" }
        }

        /// How this batch should be reported. A pure function so the distinction that matters —
        /// "nothing ran" is not "something failed" — is decided in one tested place rather than by
        /// whoever assembles the strings.
        enum Report: Equatable {
            /// Everything asked for landed.
            case clean
            /// The batch never started. Worth saying, but it is not a failure.
            case nothingRan(reason: String)
            /// Actions were attempted and did not land, one line each.
            case failures([String])
        }

        var report: Report {
            if let blockedReason { return .nothingRan(reason: blockedReason) }
            let lines = failureLines
            return lines.isEmpty ? .clean : .failures(lines)
        }
    }

    /// The body of the one summary notification a PR-actions batch posts.
    ///
    /// Leads with the failure count when anything failed. This runs only after the Jira transition
    /// has already succeeded, so a failed action means the ticket moved and GitHub did not follow —
    /// and every client's error path otherwise only `print`s, making this notification the sole
    /// place that shows up. Banners truncate, so the failure can't trail behind a success ratio.
    static func prActionsSummaryBody(
        issueKey: String,
        actions: PRActionChoices,
        candidateCount: Int,
        reviewTargetCount: Int,
        tally: PRActionTally
    ) -> String {
        var parts: [String] = []
        if actions.review != .none {
            if actions.reviewBlockedForEmptyComment {
                // Never silent: the review was withheld on purpose, not attempted and lost.
                parts.append("request changes skipped: a comment is required")
            } else {
                if reviewTargetCount > 0 {
                    let verb = actions.review == .requestChanges ? "requested changes on" : "approved"
                    parts.append("\(verb) \(tally.reviewOK)/\(reviewTargetCount)")
                    if tally.reviewFail > 0 { parts.append("\(tally.reviewFail) review failed") }
                }
                // Approvals are the only review we skip as redundant, so this can only
                // ever be an already-approved count.
                let alreadyApproved = candidateCount - reviewTargetCount
                if alreadyApproved > 0 { parts.append("\(alreadyApproved) already approved") }
            }
        }
        if actions.merge {
            let mergeAttempted = candidateCount - tally.mergeSkipped
            if mergeAttempted > 0 {
                parts.append("merged \(tally.mergeOK)/\(mergeAttempted) via \(actions.mergeMethod)")
                if tally.mergeFail > 0 { parts.append("\(tally.mergeFail) merge failed") }
            }
            if tally.mergeSkipped > 0 { parts.append("\(tally.mergeSkipped) skipped (method not allowed)") }
        }
        if actions.syncAssignee {
            parts.append("assignee set on \(tally.assignSet) PR\(tally.assignSet == 1 ? "" : "s")")
            if tally.assignFail > 0 { parts.append("\(tally.assignFail) assignee failed") }
            if tally.assignNotTouched > 0 {
                parts.append("\(tally.assignNotTouched) already assigned or unmapped")
            }
            if tally.assigneeLookupFailed { parts.append("Jira assignee lookup failed") }
        }
        let summary = parts.isEmpty ? "no changes" : parts.joined(separator: "; ")
        guard tally.failureCount > 0 else {
            return "PR actions for \(issueKey): \(summary)."
        }
        return "PR actions for \(issueKey): \(tally.failureCount) FAILED — "
            + "ticket moved, GitHub did not. \(summary)."
    }

    /// Generic Jira issue-key pattern (e.g. ABC-123). Deliberately not tied to any specific
    /// project keys — configs are user-supplied, nothing org-specific lives in source. Matched
    /// case-sensitively, mirroring how Jira's own integrations link branches/titles to tickets.
    private static let issueKeyRegex = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]+-[0-9]+\b"#)

    /// True when the string contains something that looks like a Jira issue key.
    static func containsIssueKey(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return AppDelegate.issueKeyRegex.firstMatch(in: s, options: [], range: range) != nil
    }

    /// Hangs the surviving "PRs Without Tickets" rows off the section item as a submenu, once the search
    /// and the per-issue PR collection have both finished. A PR counts as "ticketed" — and is
    /// dropped — when its URL already rendered under a visible issue, or when a Jira issue key
    /// appears in its title or head branch (the ticket may simply be outside the current JQL
    /// window). The branch check needs the GraphQL enrichment, so it runs as a second pass.
    /// Removes the section when nothing survives, which is also what makes the item's presence
    /// meaningful: it only appears when there's at least one PR behind it. Drops stale results
    /// whose item a newer refresh already discarded.
    private func populateMyPRsSubmenu(
        results: [JiraPullRequest],
        excludedURLs: Set<String>,
        item: NSMenuItem,
        separator: NSMenuItem
    ) {
        let removeSection = {
            if self.menu.index(of: item) != -1 { self.menu.removeItem(item) }
            if self.menu.index(of: separator) != -1 { self.menu.removeItem(separator) }
        }
        guard menu.index(of: item) != -1 else { return }

        let candidates = results.filter { pr in
            !excludedURLs.contains(pr.url) && !AppDelegate.containsIssueKey(pr.name)
        }
        guard !candidates.isEmpty else {
            removeSection()
            return
        }

        fetchGithubStatuses(for: candidates) { statusByURL in
            guard self.menu.index(of: item) != -1 else { return }
            let survivors = candidates.filter { pr in
                guard let branch = statusByURL[pr.url]?.headRefName else { return true }
                return !AppDelegate.containsIssueKey(branch)
            }
            guard !survivors.isEmpty else {
                removeSection()
                return
            }
            let submenu = NSMenu()
            for pr in survivors {
                self.addPRMenuItem(pr: pr, ghStatus: statusByURL[pr.url], to: submenu)
            }
            item.submenu = submenu
        }
    }

    /// When Jira's dev-status API returns no PRs for an issue, fall back to searching GitHub
    /// for PRs whose title contains the issue key (Jira only links PRs when the key is in the
    /// branch name on some integration configs). Deduped by URL before returning so a PR that
    /// somehow appeared in both sources renders once.
    private func prsWithGithubFallback(
        _ jiraPRs: [JiraPullRequest],
        issueKey: String,
        completion: @escaping ([JiraPullRequest]) -> Void
    ) {
        let dedup: ([JiraPullRequest]) -> [JiraPullRequest] = { prs in
            var seen = Set<String>()
            return prs.filter { seen.insert($0.url).inserted }
        }

        let orgs = self.githubSearchOrgs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let token = self.gitHubToken.trimmingCharacters(in: .whitespaces)

        guard jiraPRs.isEmpty, !orgs.isEmpty, !token.isEmpty else {
            completion(dedup(jiraPRs))
            return
        }

        GithubClient().searchPRsForIssueKey(issueKey, orgs: orgs, token: token) { fallbackPRs in
            completion(dedup(jiraPRs + fallbackPRs))
        }
    }

    /// Fires a GitHub GraphQL fetch per open PR (in parallel) when a token is configured.
    /// Merges results into a [url: status] dict for the renderer. Empty result if no token
    /// or the fetches all fail — callers still render the base 2-line row.
    private func fetchGithubStatuses(
        for prs: [JiraPullRequest],
        completion: @escaping ([String: GithubPRStatus]) -> Void
    ) {
        let token = gitHubToken.trimmingCharacters(in: .whitespaces)
        // Fetch for OPEN and DRAFT (review/CI info, and the isDraft flag itself — GitHub
        // reports drafts as open, so the search path can't tell them apart without this) and
        // MERGED (release/releasing info). DECLINED is skipped to save API calls.
        let candidates = prs.filter {
            let status = $0.status.uppercased()
            return (status == "OPEN" || status == "DRAFT" || status == "MERGED") && $0.url.contains("github.com")
        }
        guard !token.isEmpty, !candidates.isEmpty else {
            completion([:])
            return
        }

        let group = DispatchGroup()
        let syncQueue = DispatchQueue(label: "githubStatus.sync")
        var results: [String: GithubPRStatus] = [:]
        let client = GithubClient()

        for pr in candidates {
            group.enter()
            client.fetchPRStatus(url: pr.url, token: token) { status in
                syncQueue.async {
                    if let status { results[pr.url] = status }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(results)
        }
    }

    /// Builds one PR row and appends it to the given menu — a ticket's submenu, or the
    /// "PRs Without Tickets" submenu. Renders 3 lines when GitHub data is available (approval /
    /// unresolved / CI on line 3), otherwise 2 lines with the legacy Jira-derived indicator.
    private func addPRMenuItem(pr: JiraPullRequest, ghStatus: GithubPRStatus?, to menu: NSMenu) {
        let title = NSMutableAttributedString(string: "")
            .appendString(string: pr.name.trunc(length: 50))
            .appendNewLine()

        let slug = pr.repoSlug.isEmpty ? "PR" : pr.repoSlug
        title.appendString(string: "\(slug) #\(pr.numberOnly) · ", color: "#888888")

        let state = AppDelegate.prStateLabel(status: pr.status, ghStatus: ghStatus)
        title.appendString(string: state.text, color: state.colorHex)

        if let ghStatus {
            switch pr.status.uppercased() {
            case "OPEN":
                appendLine3(status: ghStatus, into: title)
            case "MERGED":
                appendMergedRelease(status: ghStatus, into: title)
            default:
                break
            }
        } else if pr.status.uppercased() == "OPEN" && pr.isApproved {
            // Fallback when GitHub data isn't available but Jira has an approved flag.
            title.appendString(string: " - ", color: "#888888")
            title.appendString(string: "approved", color: "#2DA44E")
        }

        let urlString = pr.url
        let prItem = NSMenuItem()
        prItem.view = PRMenuItemView(
            attributedTitle: title,
            icon: NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil),
            onLeftClick: { modifiers in
                if modifiers.contains(.shift) {
                    if let number = AppDelegate.prNumber(from: urlString) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(number, forType: .string)
                        sendNotification(body: "Copied PR #\(number)")
                    }
                    return
                }
                let target = AppDelegate.targetURL(forPR: urlString, modifiers: modifiers)
                if let url = URL(string: target) {
                    NSWorkspace.shared.open(url)
                }
            },
            onRightClick: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
                sendNotification(body: "Copied PR URL")
            }
        )
        menu.addItem(prItem)
    }

    /// Chooses the URL to open for a modifier-click on a PR row.
    /// - plain: the PR itself
    /// - ⌘: Create Release page for the repo
    /// - ⌥: Actions tab
    /// - ⌃: repo homepage
    /// Falls back to the PR URL if the repo base can't be parsed (non-standard host / path).
    static func targetURL(forPR prURL: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard let base = repoBaseURL(from: prURL) else { return prURL }
        if modifiers.contains(.command) { return "\(base)/releases/new" }
        if modifiers.contains(.option)  { return "\(base)/actions" }
        if modifiers.contains(.control) { return base }
        return prURL
    }

    /// Extracts the PR number from a URL like https://github.com/owner/repo/pull/269.
    /// Returns nil if the path isn't a /pull/<n> shape.
    static func prNumber(from prURL: String) -> String? {
        guard let number = ForgePRURL(prURL)?.pullNumber else { return nil }
        return String(number)
    }

    /// Turns a PR URL like https://github.com/owner/repo/pull/42 into
    /// https://github.com/owner/repo — nil if the path isn't at least two segments deep.
    static func repoBaseURL(from prURL: String) -> String? {
        ForgePRURL(prURL)?.repoBase
    }

    /// Adds "approved · N unresolved · CI ✓" (or a subset) as a third line. Elements without
    /// signal are omitted along with their separator.
    private func appendLine3(status: GithubPRStatus, into title: NSMutableAttributedString) {
        var pieces: [(String, String)] = []  // (text, hex color)

        switch status.reviewDecision {
        case "APPROVED":
            pieces.append(("approved", "#2DA44E"))
        case "CHANGES_REQUESTED":
            pieces.append(("changes requested", "#CF222E"))
        default:
            break // REVIEW_REQUIRED / nil — no signal worth showing
        }

        let unresolved = status.unresolvedThreads
        let unresolvedColor = unresolved > 0 ? "#BF6900" : "#888888"
        pieces.append(("\(unresolved) unresolved", unresolvedColor))

        if let ci = status.ciState {
            switch ci {
            case "SUCCESS":
                pieces.append(("CI ✓", "#2DA44E"))
            case "FAILURE", "ERROR":
                pieces.append(("CI ✗", "#CF222E"))
            case "PENDING", "EXPECTED":
                pieces.append(("CI …", "#888888"))
            default:
                break
            }
        }

        guard !pieces.isEmpty else { return }
        title.appendNewLine()
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                title.appendString(string: " · ", color: "#888888")
            }
            title.appendString(string: piece.0, color: piece.1)
        }
    }

    /// For merged PRs, appends a third line indicating whether the change has shipped
    /// ("released" — a release was published after this PR merged) or is currently in flight
    /// ("releasing" — the default branch's HEAD commit has checks in flight, i.e. actions running).
    /// Both are heuristics; nothing rendered when neither signal is present.
    private func appendMergedRelease(status: GithubPRStatus, into title: NSMutableAttributedString) {
        guard status.isMerged else { return }

        // "released" wins over "releasing" — if a release is already out, further running
        // workflows are irrelevant to the display.
        if let releasedAt = status.latestReleasePublishedAt,
           let mergedAt = status.mergedAt,
           releasedAt > mergedAt {
            title.appendNewLine()
            title.appendString(string: "released", color: "#2DA44E")
            return
        }

        if let ci = status.defaultBranchCIState, ci == "PENDING" || ci == "EXPECTED" {
            title.appendNewLine()
            title.appendString(string: "releasing", color: "#DAA520")
        }
    }

    private static func ciStateIsFailure(_ state: String?) -> Bool {
        guard let state else { return false }
        return state == "FAILURE" || state == "ERROR"
    }

    /// The state word for a PR row's second line, with its color. GitHub reports drafts as
    /// open, so `isDraft` from the GraphQL enrichment is the only thing that distinguishes
    /// them; Jira's dev-status can also report "DRAFT" directly, and both render the same.
    /// A failed CI run on an open PR outranks the draft marker — it's the more actionable
    /// signal, and it's the precedence the row already used before drafts were surfaced.
    static func prStateLabel(status: String, ghStatus: GithubPRStatus?) -> (text: String, colorHex: String) {
        let upper = status.uppercased()
        if upper == "OPEN" && ciStateIsFailure(ghStatus?.ciState) {
            return ("error", "#CF222E")
        }
        if upper == "OPEN" && ghStatus?.isDraft == true {
            return ("draft", prStatusColorHex("DRAFT"))
        }
        return (status.lowercased(), prStatusColorHex(status))
    }

    /// Color hex for a PR status badge in the menu. Falls back to a neutral gray for
    /// anything outside the four standard dev-status values.
    static func prStatusColorHex(_ status: String) -> String {
        switch status.uppercased() {
        case "MERGED":   return "#2DA44E" // green
        case "OPEN":     return "#DAA520" // goldenrod — readable yellow on light + dark menus
        case "DECLINED": return "#CF222E" // red
        case "DRAFT":    return "#DAA520" // yellow — same as open per user preference
        default:         return "#888888"
        }
    }

    @objc
    func quit(_: NSStatusBarButton) {
        NSLog("User click Quit")
        NSApplication.shared.terminate(self)
    }
    
    @objc
    func windowClosed(notification: NSNotification) {
        let window = notification.object as? NSWindow
        if let windowTitle = window?.title {
            if (windowTitle == "Preferences") {
                // Recreate rather than just fire — the refresh rate may have changed.
                scheduleRefreshTimer()
            }
        }
    }

    @objc
    func checkForUpdates() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        GithubClient().getLatestRelease { latestRelease in
            if let latestRelease = latestRelease {
                let versionComparison = currentVersion.compare(latestRelease.name.replacingOccurrences(of: "v", with: ""), options: .numeric)
                if versionComparison == .orderedAscending {
                    self.latestReleaseURL = URL(string: latestRelease.htmlUrl)
                    self.appendUpdateItemIfNeeded()
                }
            }
        }
    }

    /// Appends the "New version available" item unless it's already present. Called from
    /// `checkForUpdates` (so it shows even before the next refresh) and at the end of every
    /// `refreshMenu` rebuild (which starts from removeAllItems).
    private func appendUpdateItemIfNeeded() {
        guard let url = latestReleaseURL,
              !menu.items.contains(where: { $0.title == "New version available" })
        else { return }
        let newVersionItem = NSMenuItem(title: "New version available", action: #selector(openLink), keyEquivalent: "")
        newVersionItem.representedObject = url
        menu.addItem(newVersionItem)
    }
}
