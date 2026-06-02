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
                        if issue.fields.summary.count > 50 {
                            issueItem.toolTip = issue.fields.summary
                        }
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
                                guard !prs.isEmpty else { return }
                                issueMenu.addItem(.separator())
                                for pr in prs {
                                    let prItem = NSMenuItem(title: "", action: #selector(self.openLink), keyEquivalent: "")
                                    let title = NSMutableAttributedString(string: "")
                                        .appendString(string: pr.name.trunc(length: 50))
                                        .appendNewLine()
                                    let slug = pr.repoSlug.isEmpty ? "PR" : pr.repoSlug
                                    title.appendString(string: "\(slug) #\(pr.numberOnly) · ", color: "#888888")
                                    title.appendString(string: pr.status.lowercased(), color: AppDelegate.prStatusColorHex(pr.status))
                                    prItem.attributedTitle = title
                                    prItem.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)
                                    if pr.name.count > 50 {
                                        prItem.toolTip = pr.name
                                    }
                                    if let url = URL(string: pr.url) {
                                        prItem.representedObject = url
                                    }
                                    issueMenu.addItem(prItem)
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

            if let url = self.resolvedDashboardURL() {
                let openDashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(self.openDashboard), keyEquivalent: "")
                openDashboardItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
                openDashboardItem.representedObject = url
                self.menu.addItem(openDashboardItem)
            }
            
            let createNewItem = NSMenuItem(title: "Create issue", action: #selector(self.openCreateNewIssue), keyEquivalent: "")
            createNewItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            self.menu.addItem(createNewItem)
            
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

        let view = UserFieldDialog(
            issueKey: issueKey,
            shortcut: shortcut,
            onSubmit: { [weak self] users, done in
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

        let view = TransitionDialog(
            issueKey: issueKey,
            transitionName: transitionName,
            config: config,
            onSubmit: { [weak self] comment, users, freeText, selectValue, done in
                self?.submitTransition(
                    issueKey: issueKey,
                    transitionId: transitionId,
                    config: config,
                    comment: comment,
                    users: users,
                    freeText: freeText,
                    selectValue: selectValue,
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

    /// Resolves the user's `dashboardURL` setting into an openable URL.
    /// Accepts an absolute `http(s)://…` URL, or a path that's appended to the Jira base URL.
    private func resolvedDashboardURL() -> URL? {
        let raw = dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return URL(string: raw)
        }
        let path = raw.hasPrefix("/") ? raw : "/" + raw
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
    
    /// Builds a git-safe branch name like `DATA-1518-fix-flaky-login`. Title is lowercased,
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
