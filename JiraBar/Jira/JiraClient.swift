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

    func getIssuesByJql(completion: @escaping ((JiraResponse, [String: String]) -> Void)) {
        // Cloud introduced the /search/jql endpoint; Server only supports /search
        let searchPath = instanceType == .cloud ? "search/jql" : "search"
        let url = "\(baseUrl)/rest/api/\(apiVersion)/\(searchPath)"

        var fieldList = "id,assignee,summary,status,issuetype,project"
        let rankId = rankFieldId.trimmingCharacters(in: .whitespaces)
        if !rankId.isEmpty {
            fieldList += ",\(rankId)"
        }

        let parameters: [String: Any] = [
            "jql": jql,
            "fields": fieldList,
            "maxResults": maxResults
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
                        completion(JiraResponse(), [:])
                        sendNotification(body: error.localizedDescription)
                        return
                    }
                    let ranks = JiraClient.extractRanks(from: data, fieldId: rankId)
                    completion(decoded, ranks)
                case .failure(let error):
                    print("\(url):  \(error)")
                    completion(JiraResponse(), [:])
                    sendNotification(body: error.localizedDescription)
                }
            }
    }

    /// Parses just the rank field out of the search response. Returns [issueKey: rankString].
    /// The typed Issue/Fields struct can't decode a dynamic customfield_XXXXX key, so we do
    /// a second pass with JSONSerialization. Empty `fieldId` short-circuits to an empty dict.
    private static func extractRanks(from data: Data, fieldId: String) -> [String: String] {
        guard !fieldId.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issues = json["issues"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: String] = [:]
        for issue in issues {
            if let key = issue["key"] as? String,
               let fields = issue["fields"] as? [String: Any],
               let rank = fields[fieldId] as? String {
                result[key] = rank
            }
        }
        return result
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
        completion: @escaping (Bool) -> Void
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
                let refs = users.compactMap(userReference(for:))
                if multi {
                    fields[fieldId] = refs
                } else if let first = refs.first {
                    fields[fieldId] = first
                } else {
                    fields[fieldId] = NSNull()
                }
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

        let runTransition: () -> Void = { [self] in
            performTransition(
                issueKey: issueKey,
                transitionId: transitionId,
                comment: comment,
                completion: completion
            )
        }

        if fields.isEmpty {
            runTransition()
        } else {
            updateIssueFields(issueKey: issueKey, fields: fields) { success in
                if success {
                    runTransition()
                } else {
                    completion(false)
                }
            }
        }
    }

    private func performTransition(
        issueKey: String,
        transitionId: String,
        comment: String?,
        completion: @escaping (Bool) -> Void
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
                    completion(true)
                case .failure(let error):
                    let bodyText = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("\(url):  \(error)\n  body: \(bodyText)")
                    let message = JiraClient.extractErrorMessage(from: response.data) ?? error.localizedDescription
                    sendNotification(body: "Transition failed: \(message)")
                    completion(false)
                }
            }
    }

    private func updateIssueFields(
        issueKey: String,
        fields: [String: Any],
        completion: @escaping (Bool) -> Void
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
                    completion(true)
                case .failure(let error):
                    let bodyText = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("\(url):  \(error)\n  body: \(bodyText)")
                    let message = JiraClient.extractErrorMessage(from: response.data) ?? error.localizedDescription
                    sendNotification(body: "Field update failed: \(message)")
                    completion(false)
                }
            }
    }

    /// Pulls a human-readable message out of Jira's `{errorMessages: [...], errors: {field: msg}}` response shape.
    private static func extractErrorMessage(from data: Data?) -> String? {
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

    /// Flags an issue by setting Jira's Flagged custom field to a single option (default "Impediment",
    /// the standard label across Jira Cloud and Server). Posts an optional comment afterward.
    /// `flagFieldId` is user-configurable because the Flagged field's id varies per install.
    func flagIssue(
        issueKey: String,
        flagFieldId: String,
        optionValue: String = "Impediment",
        comment: String?,
        completion: @escaping (Bool) -> Void
    ) {
        let fieldId = flagFieldId.trimmingCharacters(in: .whitespaces)
        guard !fieldId.isEmpty else {
            sendNotification(body: "Flag failed: no field id configured")
            completion(false)
            return
        }

        let fields: [String: Any] = [
            fieldId: [["value": optionValue]]
        ]

        updateIssueFields(issueKey: issueKey, fields: fields) { [self] success in
            guard success else {
                completion(false)
                return
            }
            if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addComment(issueKey: issueKey, comment: comment) { commentOK in
                    if commentOK {
                        sendNotification(body: "Flagged \(issueKey)")
                    }
                    completion(commentOK)
                }
            } else {
                sendNotification(body: "Flagged \(issueKey)")
                completion(true)
            }
        }
    }

    /// Posts a comment to an issue. v2 endpoint accepts plain text on both Cloud and Server.
    func addComment(issueKey: String, comment: String, completion: @escaping (Bool) -> Void) {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(false)
            return
        }
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)/comment"
        let body: [String: Any] = ["body": trimmed]

        var headers = authHeaders()
        headers.add(.contentType("application/json"))

        AF.request(url, method: .post, parameters: body, encoding: JSONEncoding.default, headers: headers)
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success:
                    sendNotification(body: "Comment added to \(issueKey)")
                    completion(true)
                case .failure(let error):
                    let bodyText = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
                    print("\(url):  \(error)\n  body: \(bodyText)")
                    let message = JiraClient.extractErrorMessage(from: response.data) ?? error.localizedDescription
                    sendNotification(body: "Comment failed: \(message)")
                    completion(false)
                }
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
    /// Returns an empty array if the field is null, missing, or fails to parse.
    /// Works for both single-user fields (assignee) and multi-user custom fields.
    func getIssueFieldUsers(issueKey: String, fieldId: String, completion: @escaping ([JiraUser]) -> Void) {
        let url = "\(baseUrl)/rest/api/2/issue/\(issueKey)"
        let parameters: [String: Any] = ["fields": fieldId]
        AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseData { response in
                guard
                    let data = response.data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let fields = json["fields"] as? [String: Any]
                else {
                    completion([])
                    return
                }
                let raw = fields[fieldId]
                if let arr = raw as? [[String: Any]] {
                    completion(arr.compactMap(JiraClient.parseUser))
                } else if let obj = raw as? [String: Any] {
                    completion([JiraClient.parseUser(obj)].compactMap { $0 })
                } else {
                    completion([])
                }
            }
    }

    /// Sets a user-picker field on an issue. Empty `users` clears the field
    /// (empty array for multi-user fields, JSON null for single-user fields).
    func setIssueUsers(
        issueKey: String,
        fieldId: String,
        users: [JiraUser],
        multi: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let refs = users.compactMap(userReference(for:))
        let value: Any
        if multi {
            value = refs
        } else {
            value = refs.first ?? NSNull()
        }
        updateIssueFields(issueKey: issueKey, fields: [fieldId: value], completion: completion)
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

    /// Returns the authenticated user (Cloud: accountId-bearing; Server: name-bearing). `nil` on failure.
    func getCurrentUser(completion: @escaping (JiraUser?) -> Void) {
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


func sendNotification(body: String = "") {
  let content = UNMutableNotificationContent()
  content.title = "JiraBar Error"

  if body.count > 0 {
    content.body = body
  }

  let uuidString = UUID().uuidString
  let request = UNNotificationRequest(
    identifier: uuidString,
    content: content, trigger: nil)

  let notificationCenter = UNUserNotificationCenter.current()
  notificationCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  notificationCenter.add(request)
}
