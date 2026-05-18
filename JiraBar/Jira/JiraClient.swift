import Foundation
import Alamofire
import Defaults
import UserNotifications
import KeychainAccess


public class JiraClient {
    @Default(.instanceType) var instanceType
    @Default(.serverAuthType) var serverAuthType
    @Default(.orgName) var orgName
    @Default(.jiraHost) var jiraHost
    @Default(.jiraUsername) var jiraUsername
    @Default(.jiraServerUsername) var jiraServerUsername
    @Default(.jql) var jql
    @Default(.maxResults) var maxResults
    
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

    func getIssuesByJql(completion: @escaping ((JiraResponse) -> Void)) -> Void {
        // Cloud introduced the /search/jql endpoint; Server only supports /search
        let searchPath = instanceType == .cloud ? "search/jql" : "search"
        let url = "\(baseUrl)/rest/api/\(apiVersion)/\(searchPath)"
        let parameters: [String: Any] = [
            "jql": jql,
            "fields": "id,assignee,summary,status,issuetype,project",
            "maxResults": maxResults
        ]

        AF.request(url, method: .get, parameters: parameters, headers: authHeaders())
            .validate(statusCode: 200..<300)
            .responseDecodable(of: JiraResponse.self) { response in
                switch response.result {
                case .success(let response):
                    completion(response)
                case .failure(let error):
                    print("\(url):  \(error)")
                    completion(JiraResponse())
                    sendNotification(body: error.localizedDescription)
                }
            }
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
                let refs = users.compactMap(userReference(for:))
                guard !refs.isEmpty else { continue }
                fields[fieldId] = multi ? refs : refs.first as Any
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
