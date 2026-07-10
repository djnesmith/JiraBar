//
//  GithubClient.swift
//  jiraBar
//
//  Created by Pavel Makhov on 2023-10-29.
//

import Foundation
import Alamofire

/// Enriched pull request data pulled from GitHub's GraphQL API, layered on top of Jira's
/// (often stale) dev-status view. All fields are optional / defaulted so a partial response
/// still renders something useful.
struct GithubPRStatus {
    /// "APPROVED" / "CHANGES_REQUESTED" / "REVIEW_REQUIRED" — nil if GitHub hasn't computed one.
    var reviewDecision: String?
    var unresolvedThreads: Int
    var totalThreads: Int
    /// "SUCCESS" / "FAILURE" / "PENDING" / "ERROR" / "EXPECTED" — nil if there are no checks.
    var ciState: String?
}

public class GithubClient {

    func getLatestRelease(completion:@escaping (((LatestRelease?) -> Void))) -> Void {
             let headers: HTTPHeaders = [
                 .contentType("application/json"),
                 .accept("application/json")
             ]
             AF.request("https://api.github.com/repos/menubar-apps/JiraBar/releases/latest",
                        method: .get,
                        encoding: JSONEncoding.default,
                        headers: headers)
                 .validate(statusCode: 200..<300)
                 .responseDecodable(of: LatestRelease.self) { response in
                     switch response.result {
                     case .success(let latestRelease):
                         completion(latestRelease)
                     case .failure(let error):
                         completion(nil)
                         if let data = response.data {
                             let json = String(data: data, encoding: String.Encoding.utf8)
                         }
                         sendNotification(body: error.localizedDescription)
                     }
                 }
         }

    /// One GraphQL call per PR: fetches reviewDecision, unresolved-thread count, and the
    /// latest commit's CI rollup state. Falls back to nil on any parse / auth failure so
    /// callers can degrade to just the Jira dev-status view.
    func fetchPRStatus(url urlString: String, token: String, completion: @escaping (GithubPRStatus?) -> Void) {
        guard !token.isEmpty,
              let (owner, repo, number) = GithubClient.parsePRURL(urlString)
        else {
            completion(nil)
            return
        }

        // Parameterized query — passing owner/repo/number as variables (rather than interpolating
        // into the query text) avoids any GraphQL-injection risk from a hostile PR URL that
        // slipped through path validation.
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewDecision
              reviewThreads(first: 100) { nodes { isResolved } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            }
          }
        }
        """
        let body: [String: Any] = [
            "query": query,
            "variables": [
                "owner": owner,
                "name": repo,
                "number": number
            ]
        ]
        var headers: HTTPHeaders = [
            .authorization(bearerToken: token),
            .accept("application/json"),
            .contentType("application/json"),
            .userAgent("JiraBar")
        ]

        AF.request("https://api.github.com/graphql",
                   method: .post,
                   parameters: body,
                   encoding: JSONEncoding.default,
                   headers: headers)
            .validate(statusCode: 200..<300)
            .responseData { response in
                switch response.result {
                case .success(let data):
                    guard
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let dataDict = json["data"] as? [String: Any],
                        let repoDict = dataDict["repository"] as? [String: Any],
                        let prDict = repoDict["pullRequest"] as? [String: Any]
                    else {
                        completion(nil)
                        return
                    }

                    let reviewDecision = prDict["reviewDecision"] as? String

                    let threadNodes = ((prDict["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                    let unresolved = threadNodes.reduce(0) { acc, node in
                        let resolved = (node["isResolved"] as? Bool) ?? false
                        return acc + (resolved ? 0 : 1)
                    }

                    let commitNodes = ((prDict["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                    let ciState = commitNodes.last
                        .flatMap { ($0["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any] }?["state"] as? String

                    completion(GithubPRStatus(
                        reviewDecision: reviewDecision,
                        unresolvedThreads: unresolved,
                        totalThreads: threadNodes.count,
                        ciState: ciState
                    ))
                case .failure(let error):
                    print("github graphql: \(error)")
                    completion(nil)
                }
            }
    }

    /// Extracts (owner, repo, number) from a github.com PR URL. Returns nil for anything else
    /// (e.g. Bitbucket, GitLab) so the caller can skip the GraphQL call.
    private static func parsePRURL(_ raw: String) -> (String, String, Int)? {
        guard let url = URL(string: raw), url.host?.contains("github.com") == true else { return nil }
        let parts = url.pathComponents
        // Expected: ["/", "owner", "repo", "pull", "<number>"]
        guard parts.count >= 5, parts[3] == "pull", let number = Int(parts[4]) else { return nil }
        return (parts[1], parts[2], number)
    }
}
