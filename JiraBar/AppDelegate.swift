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
    
    var unknownPersonAvatar: NSImage!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        migrateStatusOrderIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(AppDelegate.windowClosed), name: NSWindow.willCloseNotification, object: nil)
        guard let statusButton = statusBarItem.button else { return }
        let icon = NSImage(named: "mark-gradient-white-jira")
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        statusButton.image = icon
        statusButton.imagePosition = NSControl.ImagePosition.imageLeft
        
        statusBarItem.menu = menu
        
        timer = Timer.scheduledTimer(
            timeInterval: Double(refreshRate * 60),
            target: self,
            selector: #selector(refreshMenu),
            userInfo: nil,
            repeats: true
        )
        timer?.fire()
        RunLoop.main.add(timer!, forMode: .common)
        
        NSApp.setActivationPolicy(.accessory)
        
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        unknownPersonAvatar = NSImage(systemSymbolName: "person.crop.circle.badge.questionmark", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        checkForUpdates()
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
        NSLog("Refreshing menu")
        self.menu.removeAllItems()
        
        jiraClient.getIssuesByJql() { resp, ranks in
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
                        let issueItem = NSMenuItem(title: "", action: #selector(self.openLink), keyEquivalent: "")
                        
                        let issueItemTitle = NSMutableAttributedString(string: "")
                            .appendString(string: issue.fields.summary.trunc(length: 50))
                            .appendNewLine()
                            .appendIcon(iconName: "hash", color: NSColor.gray)
                            .appendString(string: issue.key, color: "#888888")
                            .appendSeparator()
                            .appendIcon(iconName: "project", color: NSColor.gray)
                            .appendString(string: issue.fields.assignee?.displayName ?? "Unassign", color: "#888888")
                            .appendSeparator()
                            .appendString(string: issue.fields.issuetype.name, color: "#888888")
                        
                        
                        issueItem.attributedTitle = issueItemTitle
                        issueItem.representedObject = URL(string: "\(self.baseUrl)/browse/\(issue.key)")
                        
                        self.jiraClient.getTransitionsByIssueKey(issueKey: issue.key) { transitions in
                            let issueMenu = NSMenu()
                            issueItem.submenu = issueMenu
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
                            for shortcut in shortcuts {
                                let item = NSMenuItem(title: shortcut.label, action: #selector(self.openUserFieldChange), keyEquivalent: "")
                                item.representedObject = IssueShortcutTarget(issueKey: issue.key, shortcut: shortcut)
                                issueMenu.addItem(item)
                            }

                            self.jiraClient.getIssuePullRequests(issueId: issue.id) { prs in
                                self.prsWithGithubFallback(prs, issueKey: issue.key) { merged in
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
                        
                        self.menu.addItem(issueItem)
                    }
                }
            }
            else {
                self.statusBarItem.button?.title = String(0)
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
        }
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

    private func presentBulkMoveDialog() {
        bulkMoveWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Move Multiple Issues"
        window.isReleasedWhenClosed = false

        let view = BulkMoveDialog(
            issues: self.lastIssues,
            transitionPrompts: self.transitionPrompts,
            statusOrder: self.statusDisplay,
            onSubmit: { [weak self] success, failure in
                DispatchQueue.main.async {
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
                }
            },
            onCancel: { [weak self] in
                self?.bulkMoveWindow?.close()
                self?.bulkMoveWindow = nil
            }
        )
        window.contentView = NSHostingView(rootView: view)
        window.center()

        bulkMoveWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        uploadWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Upload: \(issueKey)"
        window.isReleasedWhenClosed = false

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
        window.contentView = NSHostingView(rootView: view)
        window.center()

        uploadWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc
    func addFlagToIssue(_ sender: NSMenuItem) {
        guard let issueKey = sender.representedObject as? String else { return }
        presentFlagDialog(issueKey: issueKey)
    }

    private func presentFlagDialog(issueKey: String) {
        flagWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Flag: \(issueKey)"
        window.isReleasedWhenClosed = false

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
        window.contentView = NSHostingView(rootView: view)
        window.center()

        flagWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc
    func openUserFieldChange(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? IssueShortcutTarget else { return }
        presentUserFieldDialog(issueKey: target.issueKey, shortcut: target.shortcut)
    }

    private func presentUserFieldDialog(issueKey: String, shortcut: UserFieldShortcut) {
        userFieldWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(shortcut.label): \(issueKey)"
        window.isReleasedWhenClosed = false

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
        window.contentView = NSHostingView(rootView: view)
        window.center()

        userFieldWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentCommentDialog(issueKey: String) {
        commentWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Comment: \(issueKey)"
        window.isReleasedWhenClosed = false

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
        window.contentView = NSHostingView(rootView: view)
        window.center()

        commentWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentTransitionDialog(
        issueKey: String,
        transitionId: String,
        transitionName: String,
        config: TransitionPromptConfig
    ) {
        transitionWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transition: \(transitionName)"
        window.isReleasedWhenClosed = false

        let showMirror = config.hasUserField
            && shouldShowGithubMirrorCheckbox(forJiraFieldId: config.userFieldId)
        let view = TransitionDialog(
            issueKey: issueKey,
            transitionName: transitionName,
            config: config,
            showGithubMirrorCheckbox: showMirror,
            onSubmit: { [weak self] comment, users, freeText, selectValue, updateGithub, done in
                self?.submitTransition(
                    issueKey: issueKey,
                    transitionId: transitionId,
                    config: config,
                    comment: comment,
                    users: users,
                    freeText: freeText,
                    selectValue: selectValue,
                    updateGithub: updateGithub,
                    completion: done
                )
            },
            onCancel: { [weak self] in
                self?.transitionWindow?.close()
                self?.transitionWindow = nil
            }
        )
        window.contentView = NSHostingView(rootView: view)
        window.center()

        transitionWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        completion: @escaping (Bool) -> Void
    ) {
        var updates: [JiraClient.TransitionFieldUpdate] = []
        if config.hasUserField, !users.isEmpty {
            updates.append(.users(
                fieldId: config.userFieldId.trimmingCharacters(in: .whitespaces),
                users: users,
                multi: config.userFieldAllowsMultiple
            ))
        }
        if config.hasTextField, !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updates.append(.text(
                fieldId: config.textFieldId.trimmingCharacters(in: .whitespaces),
                value: freeText
            ))
        }
        if config.hasSelectField, !selectValue.trimmingCharacters(in: .whitespaces).isEmpty {
            updates.append(.select(
                fieldId: config.selectFieldId.trimmingCharacters(in: .whitespaces),
                value: selectValue
            ))
        }

        let effectiveComment = config.includeComment ? comment : nil

        jiraClient.transitionIssue(
            issueKey: issueKey,
            to: transitionId,
            comment: effectiveComment,
            fieldUpdates: updates
        ) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.transitionWindow?.close()
                    self?.transitionWindow = nil
                    self?.refreshMenu()
                    if updateGithub, config.hasUserField {
                        self?.mirrorReviewersToGithub(issueKey: issueKey, jiraReviewers: users)
                    }
                }
                completion(success)
            }
        }
    }
    
    @objc
    func openSearchResults() {
        let encodedPath = jql.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        NSWorkspace.shared.open(URL(string: "\(baseUrl)/issues?jql=" + encodedPath!)!)
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
        NSWorkspace.shared.open(URL(string: "\(baseUrl)/secure/CreateIssue!default.jspa")!)
    }
    
    @objc
    func openLink(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(sender.representedObject as! URL)
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
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 720),
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

    /// Mirrors the Jira reviewer picker onto the linked GitHub PR(s): sets me (looked up in
    /// the mapping file via my own Jira accountId) as the PR assignee, and adds the selected
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

        // Case-fold both sides — GitHub API comparisons are case-insensitive on logins.
        let desiredSet = Set(desiredReviewerLogins.map { $0.lowercased() })

        for pr in prs {
            if let me = myGithubLogin {
                group.enter()
                client.setPRAssignees(url: pr.url, assignees: [me], token: token) { ok in
                    syncQueue.async {
                        if !ok { assignFailures += 1 }
                        group.leave()
                    }
                }
            }

            group.enter()
            client.getPRRequestedReviewers(url: pr.url, token: token) { current in
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
            } else if !prs.isEmpty {
                parts.append("reviewers already in sync")
            }
            if !unmappedReviewerNames.isEmpty {
                parts.append("unmapped: \(unmappedReviewerNames.joined(separator: ", "))")
            }
            sendNotification(body: "GitHub PR update for \(issueKey): \(parts.joined(separator: "; ")).")
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
        // Fetch for OPEN (review/CI info) and MERGED (release/releasing info) — the two states
        // where the extra GitHub signals matter. DECLINED / DRAFT are ignored to save API calls.
        let candidates = prs.filter {
            let status = $0.status.uppercased()
            return (status == "OPEN" || status == "MERGED") && $0.url.contains("github.com")
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

    /// Builds one PR row and appends it to the ticket's submenu. Renders 3 lines when GitHub
    /// data is available (approval / unresolved / CI on line 3), otherwise 2 lines with the
    /// legacy Jira-derived approved indicator.
    private func addPRMenuItem(pr: JiraPullRequest, ghStatus: GithubPRStatus?, to menu: NSMenu) {
        let title = NSMutableAttributedString(string: "")
            .appendString(string: pr.name.trunc(length: 50))
            .appendNewLine()

        let slug = pr.repoSlug.isEmpty ? "PR" : pr.repoSlug
        title.appendString(string: "\(slug) #\(pr.numberOnly) · ", color: "#888888")

        let ciFailed = AppDelegate.ciStateIsFailure(ghStatus?.ciState)
        if pr.status.uppercased() == "OPEN" && ciFailed {
            // Elevate the row's status word to "error" so the CI break is visible at a glance.
            title.appendString(string: "error", color: "#CF222E")
        } else {
            title.appendString(string: pr.status.lowercased(), color: AppDelegate.prStatusColorHex(pr.status))
        }

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
        guard let u = URL(string: prURL) else { return nil }
        let parts = u.pathComponents
        // ["/", "owner", "repo", "pull", "<n>"]
        guard parts.count >= 5, parts[3] == "pull", Int(parts[4]) != nil else { return nil }
        return parts[4]
    }

    /// Turns a PR URL like https://github.com/owner/repo/pull/42 into
    /// https://github.com/owner/repo — nil if the path isn't at least two segments deep.
    private static func repoBaseURL(from prURL: String) -> String? {
        guard let u = URL(string: prURL),
              let scheme = u.scheme,
              let host = u.host else { return nil }
        let parts = u.pathComponents
        guard parts.count >= 3 else { return nil }
        return "\(scheme)://\(host)/\(parts[1])/\(parts[2])"
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
                timer?.invalidate()
                timer = Timer.scheduledTimer(
                    timeInterval: Double(refreshRate * 60),
                    target: self,
                    selector: #selector(refreshMenu),
                    userInfo: nil,
                    repeats: true
                )
                timer?.fire()
            }
        }
    }
    
    @objc
    func checkForUpdates() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        GithubClient().getLatestRelease { latestRelease in
            if let latestRelease = latestRelease {
                let versionComparison = currentVersion.compare(latestRelease.name.replacingOccurrences(of: "v", with: ""), options: .numeric)
                if versionComparison == .orderedAscending {
                    let newVersionItem = NSMenuItem(title: "New version available", action: #selector(self.openLink), keyEquivalent: "")
                    newVersionItem.representedObject = URL(string: latestRelease.htmlUrl)
                    self.menu.addItem(newVersionItem)
                }
            }
        }
    }
}
