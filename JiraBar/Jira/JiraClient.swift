import Foundation
import Alamofire
import Defaults
import UserNotifications
import KeychainAccess
import UniformTypeIdentifiers


public class JiraClient {
    @Default(.instanceType) var instanceType
    @Default(.serverAuthType) var serverAuthType
    @Default(.orgName) var orgName
    @Default(.jiraHost) var jiraHost
    @Default(.jiraUsername) var jiraUsername
    @Default(.jiraServerUsername) var jiraServerUsername
    @Default(.jql) var jql
    @Default(.maxResults) var maxResults
    @Default(.rankFieldId) var rankFieldId
    @Default(.flagFieldId) var flagFieldId

    @FromKeychain(.jiraToken) var jiraToken
    @FromKeychain(.jiraServerToken) var jiraServerToken

    // MARK: - URL helpers

    /// Base URL for all API calls, derived from the selected instance type.
    private var baseUrl: String {
        switch instanceType {
        case .cloud:
            return "https://\(orgName).atlassian.net"
        case .server:
            // Trim any trailing slash the user may have typed.
            return jiraHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    /// False before the instance has been set up at all — no Cloud org, or no Server host, so
    /// `baseUrl` would come out as something like `https://.atlassian.net`.
    ///
    /// Only `getIssuesByJql` consults this, because it is the only request an unconfigured session
    /// actually makes: every other notifying call hangs off a menu row, and the rows are built from
    /// the search's own results, so with no issues there is nothing to click. A blank-instance guard
    /// on the others would be unreachable code.
    var isConfigured: Bool {
        JiraClient.isConfigured(instanceType: instanceType, orgName: orgName, jiraHost: jiraHost)
    }

    /// The pure half, so it can be tested without reading whatever is in the running machine's
    /// preferences. A test that instantiates `JiraClient` inherits the developer's real settings —
    /// and with them the risk of firing a real authenticated request.
    static func isConfigured(instanceType: JiraInstanceType, orgName: String, jiraHost: String) -> Bool {
        switch instanceType {
        case .cloud:  return !orgName.trimmingCharacters(in: .whitespaces).isEmpty
        case .server: return !jiraHost.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Jira Server/Data Center only supports REST API v2.
    /// Cloud supports both v2 and v3; we use v3 for richer field types on Cloud.
    private var apiVersion: String {
        switch instanceType {
        case .cloud:  return "3"
        case .server: return "2"
        }
    }

    // MARK: - Auth header

    private var activeUsername: String {
        switch instanceType {
        case .cloud:  return jiraUsername
        case .server: return jiraServerUsername
        }
    }

    private var activeToken: String {
        switch instanceType {
        case .cloud:  return jiraToken
        case .server: return jiraServerToken
        }
    }

    private func authHeaders() -> HTTPHeaders {
        var headers: HTTPHeaders = [.accept("application/json")]
        switch instanceType {
        case .cloud:
            // Cloud always uses Basic auth: email + API token
            if !activeToken.isEmpty {
                headers.add(.authorization(username: activeUsername, password: activeToken))
            }
        case .server:
            switch serverAuthType {
            case .basic:
                // Older Jira Server (pre-8.14): Basic auth with username + password
                if !activeToken.isEmpty {
                    headers.add(.authorization(username: activeUsername, password: activeToken))
                }
            case .pat:
                // Jira Server 8.14+ / Data Center: Bearer token (PAT)
                if !activeToken.isEmpty {
                    headers.add(.authorization(bearerToken: activeToken))
                }
            }
        }
        return headers
    }

    // MARK: - API calls

    /// The per-issue values a search carries that the typed `Issue` struct cannot hold, because
    /// their JSON keys are user-configured `customfield_XXXXX` ids rather than fixed names.
    struct IssueExtras {
        /// Lexorank strings, keyed by issue key. A missing key is unranked.
        var ranks: [String: String] = [:]

        /// Flag state, keyed by issue key. **A missing key means unknown, not unflagged** — no field
        /// id is configured, the field is not on that issue's screen, or the search failed outright.
        /// Rendering unknown as unflagged would put "Add Flag" on a flagged ticket.
        var flags: [String: Bool] = [:]
    }

    /// Runs a JQL search. Defaults to the user's configured query and result cap; callers can
    /// override both to run a secondary search (e.g. the TODO backlog section).
    func getIssuesByJql(
        jql overrideJQL: String? = nil,
        maxResults overrideMaxResults: String? = nil,
        completion: @escaping ((JiraResponse, IssueExtras) -> Void)
    ) {
        // An unconfigured instance has nothing to search. Returning empty beats firing a DNS failure
        // at the user as a notification banner — which is exactly what a fresh install, and this
        // app's own test host, used to do on every refresh.
        guard isConfigured else {
            completion(JiraResponse(), IssueExtras())
            return
        }
        // Cloud introduced the /search/jql endpoint; Server only supports /search
        let searchPath = instanceType == .cloud ? "search/jql" : "search"
        let url = "\(baseUrl)/rest/api/\(apiVersion)/\(searchPath)"

        let rankId = rankFieldId.trimmingCharacters(in: .whitespaces)
        let flagId = flagFieldId.trimmingCharacters(in: .whitespaces)
        var fieldList = "id,assignee,summary,status,issuetype,project"
        if !rankId.isEmpty {
            fieldList += ",\(rankId)"
        }
        // Asked for here rather than per issue on hover: the flag decides how a row renders, so it
        // has to be in hand before the row is built, and the search is already fetching every issue.
        if !flagId.isEmpty {
            fieldList += ",\(flagId)"
        }

        let parameters: [String: Any] = [
            "jql": overrideJQL ?? jql,
            "fields": fieldList,
            "maxResults": overrideMaxResults ?? maxResults
        ]

        AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success(let data):
                    let decoded: JiraResponse
                    do {
                        decoded = try JSONDecoder().decode(JiraResponse.self, from: data)
                    } catch {
                        print("\(url):  decode error \(error)")
                        completion(JiraResponse(), IssueExtras())
                        sendNotification(body: error.localizedDescription)
                        return
                    }
                    completion(decoded, JiraClient.extractIssueExtras(
                        from: data, rankFieldId: rankId, flagFieldId: flagId
                    ))
                case .failure(let error):
                    print("\(url):  \(error)")
                    completion(JiraResponse(), IssueExtras())
                    sendNotification(body: error.localizedDescription)
                }
            }
    }

    /// Second pass over the search response for the two custom fields the typed Issue/Fields struct
    /// can't decode, because their keys are dynamic `customfield_XXXXX` ids. An empty field id
    /// short-circuits that half to nothing.
    static func extractIssueExtras(
        from data: Data,
        rankFieldId: String,
        flagFieldId: String
    ) -> IssueExtras {
        guard
            !(rankFieldId.isEmpty && flagFieldId.isEmpty),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let issues = json["issues"] as? [[String: Any]]
        else {
            return IssueExtras()
        }
        var extras = IssueExtras()
        for issue in issues {
            guard
                let key = issue["key"] as? String,
                let fields = issue["fields"] as? [String: Any]
            else { continue }
            if !rankFieldId.isEmpty, let rank = fields[rankFieldId] as? String {
                extras.ranks[key] = rank
            }
            // Only a known answer is recorded — see `IssueExtras.flags`.
            if !flagFieldId.isEmpty, let flagged = JiraClient.isFlagged(fields: fields, fieldId: flagFieldId) {
                extras.flags[key] = flagged
            }
        }
        return extras
    }

    /// Whether one issue's Flagged field holds a flag, or nil when that can't be established.
    ///
    /// Jira's Flagged field is a multi-checkbox. Verified against a live Cloud instance: flagged
    /// reads back as a one-element array of option objects, `[{"value": "Impediment", "id": ...}]`;
    /// unflagged reads back as an explicit `null`, including straight after a clear that was
    /// *written* as `[]`. Both are answers, and the write and read shapes differ, so both the empty
    /// array and the null have to count as not-flagged.
    ///
    /// Unknown (nil) is reserved for the field being *absent* from `fields` — which is how Jira
    /// reports a field that is not on the issue's screen, and also what a wrong field id in
    /// Preferences produces — and for a value in a shape we don't recognise, including the bare
    /// option object a single-select field would return. That last one is deliberately unknown
    /// rather than flagged: `flagFieldPayload` only ever writes an array, so reading a single-select
    /// field as flagged would offer a "Remove Flag" whose write that field cannot accept.
    static func isFlagged(fields: [String: Any], fieldId: String) -> Bool? {
        guard let raw = fields[fieldId] else { return nil }
        if raw is NSNull { return false }
        if let options = raw as? [Any] { return !options.isEmpty }
        return nil
    }

    func getTransitionsByIssueKey(issueKey: String, completion: @escaping (([Transition]) -> Void)) -> Void {
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)/transitions"

        AF.request(url, method: .get, parameters: nil, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseDecodable(of: TransitionsResponse.self) { response in
                switch response.result {
                case .success(let response):
                    completion(response.transitions)
                case .failure(let error):
                    print("\(url):  \(error)")
                    completion([Transition]())
                    sendNotification(body: error.localizedDescription)
                }
            }
    }
    
    /// Describes a custom field update sent alongside a transition.
    enum TransitionFieldUpdate {
        /// User-picker custom field. `multi` controls array vs single-object encoding.
        case users(fieldId: String, users: [JiraUser], multi: Bool)
        /// Plain text custom field (single-line or multi-line — same JSON shape).
        case text(fieldId: String, value: String)
        /// Select/dropdown field (e.g. `resolution`, custom select-list). Sent as `{fieldId: {"id": value}}`.
        case select(fieldId: String, value: String)
    }

    /// Field ids Jira's own transition screen marks `required: true` for one transition, or nil when
    /// the metadata couldn't be read.
    ///
    /// nil is deliberately distinct from an empty set: "nothing is required" and "we don't know what
    /// is required" must not collapse, or a failed fetch silently unlocks a submit Jira will refuse.
    /// Callers treat nil as fail-closed.
    ///
    /// Only ever called for a single transition when its dialog opens. It must NOT be folded into
    /// the transitions call that builds the issue submenu — that one runs per issue on every menu
    /// rebuild, and `expand=transitions.fields` inflates each response with field metadata for every
    /// transition on the workflow.
    func getRequiredFieldIds(
        issueKey: String,
        transitionId: String,
        completion: @escaping (Set<String>?) -> Void
    ) {
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)/transitions"
        let parameters: [String: Any] = [
            "expand": "transitions.fields",
            "transitionId": transitionId
        ]
        AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success(let data):
                    completion(JiraClient.requiredFieldIds(from: data, transitionId: transitionId))
                case .failure(let error):
                    print("\(url):  \(error)")
                    completion(nil)
                }
            }
    }

    /// Parses the `expand=transitions.fields` payload into the ids that transition marks required, or
    /// nil when the answer can't be established. Split out from the request the same way
    /// `extractErrorMessage` is: the nil-vs-empty-set distinction is the whole design and it needs to
    /// be pinned by tests rather than reasoned about.
    ///
    /// nil (unknown, fail closed) for: unparseable JSON, a missing `transitions` array, the requested
    /// transition absent from it, or a field entry whose `required` isn't a bool. Empty set (known,
    /// nothing required) for: a transition present with no screen fields.
    static func requiredFieldIds(from data: Data?, transitionId: String) -> Set<String>? {
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let transitions = json["transitions"] as? [[String: Any]]
        else { return nil }

        // `transitionId` is a server-side filter, not a guarantee of one element — match it back.
        // Absent means the transition is no longer offered, which is not an answer about its fields.
        guard let match = transitions.first(where: { ($0["id"] as? String) == transitionId }) else {
            return nil
        }
        // Present with no fields at all is a real answer: nothing on the screen to require.
        guard let fields = match["fields"] as? [String: Any] else { return [] }

        var required: Set<String> = []
        for (key, value) in fields {
            guard let meta = value as? [String: Any] else { return nil }
            // Absent `required` is Jira omitting it, which the docs treat as false. A value that
            // won't read as a bool at all is a shape we don't understand — unknown, so fail closed
            // rather than quietly treating it as not-required. (JSON numbers still bridge to Bool
            // via NSNumber, so `1`/`0` are read, not rejected; Jira sends booleans.)
            switch meta["required"] {
            case nil:
                continue
            case let flag as Bool:
                if flag { required.insert(key) }
            default:
                return nil
            }
        }
        return required
    }

    /// Outcome of a transition attempt.
    ///
    /// `fieldsAlreadyWritten` exists because the field values go out as a separate PUT *before* the
    /// transition POST (see `transitionIssue`). A refusal after that PUT succeeded has already
    /// persisted the reviewers/notes/resolution, so a caller must not tell the user nothing changed.
    enum TransitionResult {
        case success
        case failed(message: String?, fieldsAlreadyWritten: Bool)
    }

    func transitionIssue(issueKey: String, to: String, completion: @escaping (() -> Void)) -> Void {
        transitionIssue(issueKey: issueKey, to: to, comment: nil, fieldUpdates: []) { _ in
            completion()
        }
    }

    func transitionIssue(
        issueKey: String,
        to transitionId: String,
        comment: String?,
        fieldUpdates: [TransitionFieldUpdate],
        completion: @escaping (TransitionResult) -> Void
    ) {
        // Build the fields payload once. We send it via a separate PUT to /issue/{key}
        // because Jira's transitions endpoint rejects fields that aren't on the workflow's
        // transition screen ("Field X cannot be set. It is not on the appropriate screen, or unknown.").
        // The Edit Issue screen is normally more permissive.
        var fields: [String: Any] = [:]
        for update in fieldUpdates {
            switch update {
            case .users(let fieldId, let users, let multi):
                // Empty `users` is intentional — clear the field (empty array for multi,
                // null for single). Callers pre-populate from the current issue value,
                // so an empty picker means "remove the existing users".
                //
                // Same shape rule as `setIssueUsers`, and for the same reason: a transition prompt
                // targeting `assignee` would otherwise write an array that Jira accepts and drops.
                let refs = users.compactMap(userReference(for:))
                fields[fieldId] = JiraClient.userFieldPayload(
                    references: refs,
                    multi: JiraClient.isMultiValuedUserField(fieldId: fieldId, configuredMultiple: multi)
                )
            case .text(let fieldId, let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    fields[fieldId] = trimmed
                }
            case .select(let fieldId, let value):
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    fields[fieldId] = ["id": trimmed]
                }
            }
        }

        let runTransition: (Bool) -> Void = { [self] fieldsWritten in
            performTransition(
                issueKey: issueKey,
                transitionId: transitionId,
                comment: comment,
                fieldsAlreadyWritten: fieldsWritten,
                completion: completion
            )
        }

        if fields.isEmpty {
            runTransition(false)
        } else {
            updateIssueFields(issueKey: issueKey, fields: fields) { success, message in
                if success {
                    runTransition(true)
                } else {
                    completion(.failed(message: message, fieldsAlreadyWritten: false))
                }
            }
        }
    }

    private func performTransition(
        issueKey: String,
        transitionId: String,
        comment: String?,
        fieldsAlreadyWritten: Bool,
        completion: @escaping (TransitionResult) -> Void
    ) {
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)/transitions"

        var body: [String: Any] = [
            "transition": ["id": transitionId]
        ]

        if let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            body["update"] = [
                "comment": [["add": ["body": trimmed]]]
            ]
        }

        var headers = authHeaders()
        headers.add(.contentType("application/json"))

        AF.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success:
                    sendNotification(body: "Successfully transitioned issue")
                    completion(.success)
                case .failure(let error):
                    let bodyText = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("\(url):  \(error)\n  body: \(bodyText)")
                    let message = JiraClient.extractErrorMessage(from: response.data) ?? error.localizedDescription
                    sendNotification(body: "Transition failed: \(message)")
                    completion(.failed(message: message, fieldsAlreadyWritten: fieldsAlreadyWritten))
                }
            }
    }

    private func updateIssueFields(
        issueKey: String,
        fields: [String: Any],
        completion: @escaping (Bool, String?) -> Void
    ) {
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)"
        let body: [String: Any] = ["fields": fields]

        var headers = authHeaders()
        headers.add(.contentType("application/json"))

        AF.request(url, method: .put, parameters: body, encoding: JSONEncoding.default, headers: headers)
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success:
                    completion(true, nil)
                case .failure(let error):
                    let bodyText = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("\(url):  \(error)\n  body: \(bodyText)")
                    let message = JiraClient.extractErrorMessage(from: response.data) ?? error.localizedDescription
                    sendNotification(body: "Field update failed: \(message)")
                    completion(false, message)
                }
            }
    }

    /// Pulls a human-readable message out of Jira's `{errorMessages: [...], errors: {field: msg}}` response shape.
    static func extractErrorMessage(from data: Data?) -> String? {
        guard
            let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let messages = json["errorMessages"] as? [String], let first = messages.first, !first.isEmpty {
            return first
        }
        if let errors = json["errors"] as? [String: String], let first = errors.first {
            return "\(first.key): \(first.value)"
        }
        return nil
    }

    /// Builds a JSON-friendly user reference for a custom field update.
    /// Cloud expects `{"accountId": ...}`; Server/DC expects `{"name": ...}` (or `{"key": ...}` on legacy versions).
    private func userReference(for user: JiraUser) -> [String: String]? {
        switch instanceType {
        case .cloud:
            if let accountId = user.accountId, !accountId.isEmpty {
                return ["accountId": accountId]
            }
        case .server:
            if let name = user.name, !name.isEmpty {
                return ["name": name]
            }
            if let key = user.key, !key.isEmpty {
                return ["key": key]
            }
        }
        return nil
    }

    /// Uploads one or more files to a Jira issue as attachments. Optionally posts a comment afterward.
    /// Uses multipart/form-data with the `X-Atlassian-Token: no-check` header that Jira requires
    /// for attachment uploads. Field name is `file` per attachment.
    func uploadAttachments(
        issueKey: String,
        files: [URL],
        comment: String?,
        completion: @escaping (Bool) -> Void
    ) {
        guard !files.isEmpty else {
            completion(false)
            return
        }
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)/attachments"

        var headers = authHeaders()
        headers.add(name: "X-Atlassian-Token", value: "no-check")
        // Intentionally don't set Content-Type — Alamofire fills in the multipart boundary.

        AF.upload(multipartFormData: { form in
            for fileURL in files {
                // Security-scoped reads aren't required when the URL came from NSOpenPanel or a drop
                // in the current process — Alamofire reads via the URL synchronously on enqueue.
                let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                form.append(fileURL, withName: "file", fileName: fileURL.lastPathComponent, mimeType: mime)
            }
        }, to: url, method: .post, headers: headers)
        .validate(statusCode: 200..<300)
        .responseData { [self] response in
            switch response.result {
            case .success:
                if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    addComment(issueKey: issueKey, comment: comment) { commentOK in
                        if commentOK {
                            sendNotification(body: "Uploaded \(files.count) file(s) to \(issueKey)")
                        }
                        completion(commentOK)
                    }
                } else {
                    sendNotification(body: "Uploaded \(files.count) file(s) to \(issueKey)")
                    completion(true)
                }
            case .failure(let error):
                let bodyText = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                print("\(url):  \(error)\n  body: \(bodyText)")
                let message = JiraClient.extractErrorMessage(from: response.data) ?? error.localizedDescription
                sendNotification(body: "Upload failed: \(message)")
                completion(false)
            }
        }
    }

    /// The value to write to the Flagged field. An array of one option to raise a flag; an empty
    /// array to clear it.
    ///
    /// Empty array rather than `null`, and not a coin toss: `PUT {"fields":{"<flagId>":[]}}` was run
    /// against a live Cloud instance and the field read back as `null`, so `[]` genuinely clears.
    /// It is also the type-correct empty for an array-valued field, and the same choice
    /// `userFieldPayload` makes for a multi-valued clear.
    static func flagFieldPayload(flagged: Bool, optionValue: String) -> [[String: String]] {
        flagged ? [["value": optionValue]] : []
    }

    /// Whether a flag write should be reported as having landed, given what reading the field back
    /// returned and what was asked for.
    ///
    /// A nil read-back is not a failure. The field is not on the issue at all, or the GET itself
    /// failed — neither is evidence the write was discarded, and claiming failure on no evidence is
    /// its own kind of lie. Same call, and the same reasoning, as `setIssueUsers`.
    static func flagWriteLanded(readBack: Bool?, wanted: Bool) -> Bool {
        guard let readBack else { return true }
        return readBack == wanted
    }

    /// Raises or clears Jira's Flagged custom field, then reads it back before reporting success.
    /// Posts an optional comment afterward. `flagFieldId` is user-configurable because the Flagged
    /// field's id varies per install.
    func setFlag(
        issueKey: String,
        flagFieldId: String,
        flagged: Bool,
        optionValue: String = "Impediment",
        comment: String? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        let fieldId = flagFieldId.trimmingCharacters(in: .whitespaces)
        guard !fieldId.isEmpty else {
            sendNotification(body: "\(flagged ? "Flag" : "Unflag") failed: no field id configured")
            completion(false)
            return
        }

        let fields: [String: Any] = [
            fieldId: JiraClient.flagFieldPayload(flagged: flagged, optionValue: optionValue)
        ]

        updateIssueFields(issueKey: issueKey, fields: fields) { [self] success, _ in
            guard success else {
                completion(false)
                return
            }
            // A 2xx from Jira means the request was accepted, not that the field changed — the
            // assignee bug in 9c7d420 was exactly that, and a clear is the shape most likely to be
            // quietly dropped. Reading it back is the only way to know. See `flagWriteLanded`.
            getIssueFlag(issueKey: issueKey, fieldId: fieldId) { [self] readBack in
                guard JiraClient.flagWriteLanded(readBack: readBack, wanted: flagged) else {
                    sendNotification(
                        body: "\(issueKey): Jira accepted the change but the flag did not update."
                    )
                    completion(false)
                    return
                }
                finishFlag(issueKey: issueKey, flagged: flagged, comment: comment, completion: completion)
            }
        }
    }

    private func finishFlag(
        issueKey: String,
        flagged: Bool,
        comment: String?,
        completion: @escaping (Bool) -> Void
    ) {
        let done = flagged ? "Flagged \(issueKey)" : "Removed flag from \(issueKey)"
        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addComment(issueKey: issueKey, comment: comment) { commentOK in
                if commentOK {
                    sendNotification(body: done)
                }
                completion(commentOK)
            }
        } else {
            sendNotification(body: done)
            completion(true)
        }
    }

    /// The flag state of one issue, or nil when it can't be established — see `isFlagged`.
    func getIssueFlag(issueKey: String, fieldId: String, completion: @escaping (Bool?) -> Void) {
        fetchIssueFields(issueKey: issueKey, fieldIds: fieldId) { fields in
            guard let fields else {
                completion(nil)
                return
            }
            completion(JiraClient.isFlagged(fields: fields, fieldId: fieldId))
        }
    }

    /// Posts a comment to an issue. The v2 endpoint takes a wiki-markup string on both Cloud and
    /// Server, which is what lets an @-mention be `[~accountid:…]` inside the body instead of
    /// forcing the whole comment format over to v3/ADF.
    ///
    /// Any mention in the body is read back afterwards and checked for a real ADF `mention` node: a
    /// 2xx here means Jira accepted the string, not that it resolved anybody, and a mention that did
    /// not resolve is a comment whose recipient was never notified.
    ///
    /// The ids come out of the body about to be posted rather than being passed in alongside it, so
    /// no caller of *this* can post a mention it never checks. Note that a transition's comment does
    /// not come through here at all — `performTransition` posts it inside the transition payload,
    /// where there is no comment id to read back, so those mentions go unverified.
    func addComment(issueKey: String, comment: String, completion: @escaping (Bool) -> Void) {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(false)
            return
        }
        let mentionIds = MentionText.mentionedAccountIds(inWiki: trimmed)
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)/comment"
        let body: [String: Any] = ["body": trimmed]

        var headers = authHeaders()
        headers.add(.contentType("application/json"))

        AF.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
            .validate(statusCode: 200..<300)
            .responseData { [self] response in
                switch response.result {
                case .success(let data):
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    verifyMentions(
                        issueKey: issueKey,
                        commentId: json?["id"] as? String,
                        expected: mentionIds
                    ) { unresolved in
                        if unresolved.isEmpty {
                            sendNotification(body: "Comment added to \(issueKey)")
                        } else {
                            // Reported as posted, because it was: telling the caller this failed
                            // would reopen the dialog and invite a duplicate comment. What it must
                            // not do is call it a success, because nobody was notified.
                            sendNotification(
                                body: "\(issueKey): comment posted, but \(unresolved.count) "
                                    + "mention(s) did not resolve — those people were not notified."
                            )
                        }
                        completion(true)
                    }
                case .failure(let error):
                    let bodyText = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("\(url):  \(error)\n  body: \(bodyText)")
                    let message = JiraClient.extractErrorMessage(from: response.data) ?? error.localizedDescription
                    sendNotification(body: "Comment failed: \(message)")
                    completion(false)
                }
            }
    }

    /// Reads a just-posted comment back and reports which of the expected mentions Jira did *not*
    /// turn into a real mention.
    ///
    /// An empty result means everything landed — including the cases where there was nothing to
    /// check and where the check itself could not run. A failed read-back is not evidence the
    /// mention was dropped, and claiming failure on no evidence is its own kind of lie: same call,
    /// and the same reasoning, as `flagWriteLanded`.
    private func verifyMentions(
        issueKey: String,
        commentId: String?,
        expected: [String],
        completion: @escaping ([String]) -> Void
    ) {
        // Only Cloud has ADF. Reading a Server comment back through v2 returns the same wiki string
        // we just sent, so there would be nothing in it to check the mention against.
        guard instanceType == .cloud, !expected.isEmpty, let commentId else {
            completion([])
            return
        }
        let url = "\(baseUrl)/rest/api/3/issue/\(issueKey)/comment/\(commentId)"
        AF.request(url, method: .get, parameters: nil, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseData { response in
                guard
                    case .success(let data) = response.result,
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else {
                    print("\(url):  mention read-back failed")
                    completion([])
                    return
                }
                completion(
                    JiraClient.unresolvedMentionIds(
                        expected: expected,
                        found: JiraClient.mentionIds(inADF: json["body"])
                    )
                )
            }
    }

    /// Every account id carried by an ADF `mention` node, at any depth.
    ///
    /// The distinction that matters: Jira stores `[~accountid:…]` as a `mention` node with the id in
    /// `attrs.id`, and leaves an unrecognised `@Name` as a plain `text` node. Finding the id here is
    /// therefore the difference between a notification and a string.
    static func mentionIds(inADF node: Any?) -> Set<String> {
        switch node {
        case let dict as [String: Any]:
            var ids: Set<String> = []
            if dict["type"] as? String == "mention",
               let attrs = dict["attrs"] as? [String: Any],
               let id = attrs["id"] as? String, !id.isEmpty {
                ids.insert(id)
            }
            for value in dict.values {
                ids.formUnion(mentionIds(inADF: value))
            }
            return ids
        case let array as [Any]:
            return array.reduce(into: Set<String>()) { $0.formUnion(mentionIds(inADF: $1)) }
        default:
            return []
        }
    }

    /// Which expected account ids the stored comment does not actually mention, deduplicated and in
    /// the order they were asked for.
    static func unresolvedMentionIds(expected: [String], found: Set<String>) -> [String] {
        expected.reduce(into: (seen: Set<String>(), missing: [String]())) { result, id in
            guard !id.isEmpty, !found.contains(id), result.seen.insert(id).inserted else { return }
            result.missing.append(id)
        }.missing
    }

    /// Users matching a free-text query, for @-mention autocomplete.
    ///
    /// `/user/search` rather than the `/user/assignable/search` the pickers use: mentioning somebody
    /// is not assigning them the ticket, and the assignable set hides stakeholders who are perfectly
    /// mentionable. It also matches server-side across every word of a display name, surname
    /// included, so the client never has to hold a directory in memory.
    func searchUsers(query: String, completion: @escaping ([JiraUser]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }
        let url = "\(baseUrl)/rest/api/\(apiVersion)/user/search"
        // Cloud takes `query`; Server/DC takes `username`. Kept disjoint for the same reason
        // `getAssignableUsers` keeps them disjoint — stricter installs reject unknown params.
        var parameters: [String: Any] = ["maxResults": 20]
        switch instanceType {
        case .cloud:  parameters["query"] = trimmed
        case .server: parameters["username"] = trimmed
        }

        AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseDecodable(of: [JiraUser].self) { response in
                switch response.result {
                case .success(let users):
                    completion(JiraClient.mentionableUsers(users))
                case .failure(let error):
                    // Autocomplete is ambient — a failed lookup shows no rows rather than a banner
                    // over the comment the user is in the middle of writing.
                    print("\(url):  \(error)")
                    completion([])
                }
            }
    }

    /// Drops the accounts nobody means to @-mention.
    ///
    /// Not cosmetic: `/user/search` returns add-ons (`app`) and Service Desk portal customers
    /// (`customer`) alongside people, and on a real instance they outnumber the colleagues badly —
    /// portal accounts arrive as bare email addresses and bury the name being typed. `accountType` is
    /// Cloud-only, so a missing one is kept: on Server/DC every result is a user. A missing `active`
    /// is kept for the same reason, since only Cloud reliably sends it.
    static func mentionableUsers(_ users: [JiraUser]) -> [JiraUser] {
        users.filter { user in
            guard user.active != false else { return false }
            guard let accountType = user.accountType else { return true }
            return accountType == "atlassian"
        }
    }

    /// Fetches GitHub pull requests linked to an issue via Jira's dev-status backing API
    /// (the same one that powers the Development panel in Jira's UI). Requires the numeric
    /// issue id, not the key.
    func getIssuePullRequests(issueId: String, completion: @escaping ([JiraPullRequest]) -> Void) {
        let url = "\(baseUrl)/rest/dev-status/1.0/issue/detail"
        let parameters: [String: Any] = [
            "issueId": issueId,
            "applicationType": "GitHub",
            "dataType": "pullrequest"
        ]
        AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseDecodable(of: JiraDevStatusResponse.self) { response in
                switch response.result {
                case .success(let payload):
                    completion(payload.detail.flatMap { $0.pullRequests })
                case .failure(let error):
                    // dev-status returns 200 with empty detail when there's no integration —
                    // any non-2xx is genuinely unexpected, log and degrade silently.
                    print("\(url):  \(error)")
                    completion([])
                }
            }
    }

    /// Fetches the current value(s) of a single user-picker field on an issue.
    /// Returns an empty array when the field is present and holds nobody, and nil when its value is
    /// unknown — the request failed, or the field is not on this issue at all — because callers that
    /// pre-populate pickers, diff against the current value, or offer to "add" must not mistake an
    /// unknown value for an empty one.
    /// Works for both single-user fields (assignee) and multi-user custom fields.
    func getIssueFieldUsers(issueKey: String, fieldId: String, completion: @escaping ([JiraUser]?) -> Void) {
        fetchIssueFields(issueKey: issueKey, fieldIds: fieldId) { fields in
            guard let fields else {
                completion(nil)
                return
            }
            completion(JiraClient.fieldUsers(from: fields, fieldId: fieldId))
        }
    }

    /// The raw `fields` object for one issue, restricted to `fieldIds` (comma-separated), or nil when
    /// the request or the parse failed. Note that a nil here is *only* about the request — a field
    /// Jira omits because it isn't on the issue is a present dictionary with the key absent, which is
    /// the distinction `fieldUsers` and `isFlagged` are built on.
    private func fetchIssueFields(
        issueKey: String,
        fieldIds: String,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)"
        AF.request(url, method: .get, parameters: ["fields": fieldIds], headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success(let data):
                    guard
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let fields = json["fields"] as? [String: Any]
                    else {
                        completion(nil)
                        return
                    }
                    completion(fields)
                case .failure(let error):
                    print("\(url):  \(error)")
                    completion(nil)
                }
            }
    }

    /// Sets a user-picker field on an issue. Empty `users` clears the field
    /// (empty array for multi-user fields, JSON null for single-user fields).
    /// Jira's own user fields, which are single-valued no matter what a shortcut is configured to say.
    ///
    /// The shape of these cannot be left to configuration, because getting it wrong is not an error.
    /// Verified against a live Cloud instance: `PUT {"fields":{"assignee":[{...}]}}` returns **204 No
    /// Content** and silently discards the value — the issue stays unassigned. A *custom* field rejects
    /// the same mistake loudly (`400 "data was not an array"`), so only the system fields fail quietly,
    /// which is exactly why this went unnoticed.
    static let singleValuedUserFields: Set<String> = ["assignee", "reporter"]

    /// Whether a user field takes an array, given what the shortcut claims. A shortcut may not claim
    /// multi for a field Jira defines as single.
    static func isMultiValuedUserField(fieldId: String, configuredMultiple: Bool) -> Bool {
        if singleValuedUserFields.contains(fieldId.trimmingCharacters(in: .whitespaces).lowercased()) {
            return false
        }
        return configuredMultiple
    }

    /// The value to write for a user field: an array for multi-valued fields, a bare object for single
    /// ones, and empty/null to clear.
    static func userFieldPayload(references: [[String: String]], multi: Bool) -> Any {
        multi ? references : (references.first ?? NSNull())
    }

    func setIssueUsers(
        issueKey: String,
        fieldId: String,
        users: [JiraUser],
        multi: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let refs = users.compactMap(userReference(for:))
        let multi = JiraClient.isMultiValuedUserField(fieldId: fieldId, configuredMultiple: multi)
        let value = JiraClient.userFieldPayload(references: refs, multi: multi)

        updateIssueFields(issueKey: issueKey, fields: [fieldId: value]) { [self] success, _ in
            guard success else {
                completion(false)
                return
            }
            // A 204 from Jira means "request accepted", not "field written" — see
            // `singleValuedUserFields`. The only way to know a user-field write landed is to read it
            // back, and this is a user-initiated action, so one extra GET is worth not lying to them.
            getIssueFieldUsers(issueKey: issueKey, fieldId: fieldId) { readBack in
                guard let readBack else {
                    // The field is not on the issue's screen, or the read itself failed. That is not
                    // evidence the write was dropped, and claiming failure on no evidence would be its
                    // own kind of lie.
                    completion(true)
                    return
                }
                let wanted = Set(users.map(\.id))
                let got = Set(readBack.map(\.id))
                guard wanted == got else {
                    sendNotification(
                        body: "\(issueKey): Jira accepted the change but \(fieldId) did not update."
                    )
                    completion(false)
                    return
                }
                completion(true)
            }
        }
    }

    /// The users held by one field, or nil when the field's value is unknown.
    ///
    /// A field absent from `fields` is unknown, not empty: Jira omits the key entirely for a field that
    /// is not on the issue's screen (verified against a live instance — asking for three field ids
    /// returned only the two that applied, with no null for the third). An explicit null is a real
    /// answer and yields no users.
    static func fieldUsers(from fields: [String: Any], fieldId: String) -> [JiraUser]? {
        guard let raw = fields[fieldId] else { return nil }
        if raw is NSNull { return [] }
        if let arr = raw as? [[String: Any]] { return arr.compactMap(parseUser) }
        if let obj = raw as? [String: Any] { return [parseUser(obj)].compactMap { $0 } }
        return nil
    }

    private static func parseUser(_ dict: [String: Any]) -> JiraUser? {
        var user = JiraUser(displayName: (dict["displayName"] as? String) ?? "")
        user.accountId = dict["accountId"] as? String
        user.name = dict["name"] as? String
        user.key = dict["key"] as? String
        user.emailAddress = dict["emailAddress"] as? String
        user.active = dict["active"] as? Bool
        if user.displayName.isEmpty && user.accountId == nil && user.name == nil && user.key == nil {
            return nil
        }
        return user
    }

    /// Looks up the numeric issue id for a Jira key. Needed by `getIssuePullRequests`, whose
    /// backing dev-status API takes an id rather than a key. Returns nil on any failure so
    /// callers can degrade silently.
    func getIssueId(byKey key: String, completion: @escaping (String?) -> Void) {
        let url = "\(baseUrl)/rest/api/\(apiVersion)/issue/\(key)"
        AF.request(url, method: .get, parameters: ["fields": "summary"], headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseData { response in
                guard
                    let data = response.data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let id = json["id"] as? String
                else {
                    completion(nil)
                    return
                }
                completion(id)
            }
    }

    /// Returns the authenticated user (Cloud: accountId-bearing; Server: name-bearing). `nil` on failure.
    ///
    /// Guarded like `getIssuesByJql`: this now runs on every refresh for the TODO filter, so an
    /// unconfigured instance would otherwise fire a doomed request on the timer forever.
    func getCurrentUser(completion: @escaping (JiraUser?) -> Void) {
        guard isConfigured else {
            completion(nil)
            return
        }
        let url = "\(baseUrl)/rest/api/\(apiVersion)/myself"
        AF.request(url, method: .get, parameters: nil, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseDecodable(of: JiraUser.self) { response in
                switch response.result {
                case .success(let user):
                    completion(user)
                case .failure(let error):
                    print("\(url):  \(error)")
                    completion(nil)
                }
            }
    }

    /// Result type for assignable-user lookups so callers can show a message instead of an empty list.
    enum AssignableUsersResult {
        case success([JiraUser])
        case failure(String)
    }

    /// Fetches users assignable to the given issue. Loaded once per dialog; the UI filters client-side.
    func getAssignableUsers(issueKey: String, completion: @escaping (AssignableUsersResult) -> Void) {
        let url = "\(baseUrl)/rest/api/\(apiVersion)/user/assignable/search"
        // Cloud's `/user/assignable/search` accepts `query` (empty allowed when `issueKey` is set);
        // Server uses `username` and rejects unknown params on stricter installs, so keep them disjoint.
        var parameters: [String: Any] = [
            "issueKey": issueKey,
            "maxResults": 50
        ]
        switch instanceType {
        case .cloud:
            parameters["query"] = ""
        case .server:
            parameters["username"] = "."
        }

        AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseDecodable(of: [JiraUser].self) { response in
                switch response.result {
                case .success(let users):
                    completion(.success(users))
                case .failure(let error):
                    print("\(url):  \(error)")
                    let bodyHint: String
                    if let data = response.data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        bodyHint = text.prefix(200).description
                    } else {
                        bodyHint = error.localizedDescription
                    }
                    completion(.failure("Failed to load users: \(bodyHint)"))
                }
            }
    }
    
    func validateCredentials(completion: @escaping (Bool) -> Void) {
        switch instanceType {
        case .cloud:
            // Cloud: /myself is a reliable auth probe
            let url = "\(baseUrl)/rest/api/\(apiVersion)/myself"
            AF.request(url, method: .get, parameters: nil, headers: authHeaders())
                .validate(statusCode: 200..<300)
                .response { response in
                    switch response.result {
                    case .success:  completion(true)
                    case .failure(let error):
                        print(error)
                        completion(false)
                    }
                }
        case .server:
            // /myself returns 401 on some Server instances even with valid PATs.
            // Validate via a lightweight search and require a non-anonymous user context.
            let url = "\(baseUrl)/rest/api/2/search"
            let parameters: [String: Any] = ["jql": "reporter = currentUser()", "maxResults": 1]
            AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
                .validate(statusCode: 200..<300)
                .responseData { response in
                    switch response.result {
                    case .success:
                        let usernameHeader = response.response?
                            .value(forHTTPHeaderField: "X-AUSERNAME")?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        if let usernameHeader, !usernameHeader.isEmpty {
                            completion(usernameHeader != "anonymous")
                        } else {
                            completion(true)
                        }
                    case .failure(let error):
                        print(error)
                        completion(false)
                    }
                }
        }
    }
}


/// The single seam every user-facing notification goes through.
///
/// `deliver` is substitutable so a test can record what would have been posted instead of posting
/// it. That is not only hygiene: this app is hosted inside its own test bundle, so anything reaching
/// a process-global — the notification centre, the pasteboard, the login-item registry — reaches the
/// real one on the developer's machine. It also buys a better assertion than a boolean: the exact
/// body text and the number of notifications.
///
/// Deliberately not gated on "are we running tests". A build flag or an `isRunningTests` check would
/// leave the production path unexercised and hide the fact that the dependency was never injected.
enum UserNotice {
    /// Replaced by tests with a recorder; restored in `tearDown`.
    static var deliver: (String) -> Void = postToNotificationCentre

    static func postToNotificationCentre(_ body: String) {
        let content = UNMutableNotificationContent()
        // Neutral title — body text already conveys success vs failure (e.g. "Comment failed:" /
        // "Copied PR URL"). Previously hardcoded as "JiraBar Error" which mislabeled success cases.
        content.title = "JiraBar"
        if !body.isEmpty {
            content.body = body
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        let notificationCentre = UNUserNotificationCenter.current()
        notificationCentre.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        notificationCentre.add(request)
    }
}

func sendNotification(body: String = "") {
    UserNotice.deliver(body)
}
