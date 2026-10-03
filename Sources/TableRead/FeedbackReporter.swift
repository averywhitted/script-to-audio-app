import Foundation
import AppKit

/// Routes user-submitted feedback (bug reports, parser corrections) to the
/// project's issue tracker.
///
/// This deliberately does not post anything itself. The previous version
/// embedded a GitHub personal access token in the source and POSTed straight
/// to the issues API. That shipped a working credential inside every copy of
/// the app, where anyone could extract it from the binary, and it published
/// whatever the user submitted — including lines of their screenplay — as a
/// public issue while the UI described it as being "sent to the developer".
///
/// Opening GitHub's own prefilled form instead fixes both halves: the app
/// carries no secret, and nothing is published until the user has read the
/// filled-in issue on github.com and pressed Submit themselves.
enum FeedbackReporter {
    private static let repoOwner = "averywhitted"
    private static let repoName  = "script-to-audio-app"

    /// Long query strings get rejected, so keep clear of the URL length limit.
    private static let maxBodyLength = 6000

    /// Shown in the UI so the user knows where their text is going before
    /// they commit to sending it.
    static let destinationDescription = "a public issue on github.com/\(repoOwner)/\(repoName)"

    /// A prefilled "new issue" URL, or nil if one cannot be built.
    static func issueURL(subject: String, body: String, labels: [String] = []) -> URL? {
        var text = body
        if text.count > maxBodyLength {
            text = String(text.prefix(maxBodyLength))
                 + "\n\n…truncated. Use Export… in Settings to save the full data to a file."
        }
        var components = URLComponents(
            string: "https://github.com/\(repoOwner)/\(repoName)/issues/new")
        var items = [
            URLQueryItem(name: "title", value: subject),
            URLQueryItem(name: "body",  value: text),
        ]
        if !labels.isEmpty {
            items.append(URLQueryItem(name: "labels", value: labels.joined(separator: ",")))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Opens the prefilled form in the user's browser. Submitting is up to them.
    @discardableResult
    static func openIssueForm(subject: String, body: String, labels: [String] = []) -> Bool {
        guard let url = issueURL(subject: subject, body: body, labels: labels) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
