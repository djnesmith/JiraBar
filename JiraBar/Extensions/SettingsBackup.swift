import Foundation
import Defaults

/// Full snapshot of user-configurable Defaults — used for the "Export All / Import All"
/// settings backup buttons in Preferences. Secrets (Keychain-stored API tokens) are intentionally
/// excluded; users re-enter the token on import. Every property is Optional so older files
/// that don't include newer fields still load cleanly.
struct AppSettings: Codable {
    var version: Int = 1

    // Connection
    var instanceType: String?
    var serverAuthType: String?
    var orgName: String?
    var jiraHost: String?
    var jiraUsername: String?
    var jiraServerUsername: String?

    // Query / display
    var jql: String?
    var maxResults: String?
    var refreshRate: Int?
    var dashboardURL: String?

    // Field ids
    var flagFieldId: String?
    var rankFieldId: String?

    // Lists
    var statusOrder: [String]?
    var statusDisplay: [StatusDisplay]?
    var userFieldShortcuts: [UserFieldShortcut]?
    var transitionPrompts: [TransitionPromptConfig]?

    /// Reads every currently-stored Defaults value into a snapshot. Empty strings/arrays stay as-is
    /// so re-importing produces the same state.
    static func snapshot() -> AppSettings {
        AppSettings(
            version: 1,
            instanceType: Defaults[.instanceType].rawValue,
            serverAuthType: Defaults[.serverAuthType].rawValue,
            orgName: Defaults[.orgName],
            jiraHost: Defaults[.jiraHost],
            jiraUsername: Defaults[.jiraUsername],
            jiraServerUsername: Defaults[.jiraServerUsername],
            jql: Defaults[.jql],
            maxResults: Defaults[.maxResults],
            refreshRate: Defaults[.refreshRate],
            dashboardURL: Defaults[.dashboardURL],
            flagFieldId: Defaults[.flagFieldId],
            rankFieldId: Defaults[.rankFieldId],
            statusOrder: Defaults[.statusOrder],
            statusDisplay: Defaults[.statusDisplay],
            userFieldShortcuts: Defaults[.userFieldShortcuts],
            transitionPrompts: Defaults[.transitionPrompts]
        )
    }

    /// Writes any non-nil field back to Defaults. Invalid enum raw values are skipped rather
    /// than crashing the import.
    func apply() {
        if let raw = instanceType, let value = JiraInstanceType(rawValue: raw) { Defaults[.instanceType] = value }
        if let raw = serverAuthType, let value = JiraServerAuthType(rawValue: raw) { Defaults[.serverAuthType] = value }
        if let value = orgName { Defaults[.orgName] = value }
        if let value = jiraHost { Defaults[.jiraHost] = value }
        if let value = jiraUsername { Defaults[.jiraUsername] = value }
        if let value = jiraServerUsername { Defaults[.jiraServerUsername] = value }
        if let value = jql { Defaults[.jql] = value }
        if let value = maxResults { Defaults[.maxResults] = value }
        if let value = refreshRate { Defaults[.refreshRate] = value }
        if let value = dashboardURL { Defaults[.dashboardURL] = value }
        if let value = flagFieldId { Defaults[.flagFieldId] = value }
        if let value = rankFieldId { Defaults[.rankFieldId] = value }
        if let value = statusOrder { Defaults[.statusOrder] = value }
        if let value = statusDisplay { Defaults[.statusDisplay] = value }
        if let value = userFieldShortcuts { Defaults[.userFieldShortcuts] = value }
        if let value = transitionPrompts { Defaults[.transitionPrompts] = value }
    }
}
