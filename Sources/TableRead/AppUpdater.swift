import Foundation
import AppKit

// MARK: - Data types

struct UpdateInfo: Sendable, Equatable {
    /// Clean version string, e.g. "0.1.5"
    let version: String
    /// Direct URL of the zip asset (or the HTML release page if no zip asset exists yet)
    let downloadURL: URL
    /// HTML URL for the GitHub release page (used as fallback / "view release notes")
    let htmlURL: URL
    /// Markdown body from the GitHub release
    let releaseNotes: String
    /// True when downloadURL points to an actual zip asset (vs. the release page)
    let hasZipAsset: Bool
}

enum UpdateDownloadState: Equatable, Sendable {
    case idle
    case downloading(Double)   // 0.0 – 1.0
    case extracting
    case installing
    case failed(String)
}

// MARK: - AppUpdater

/// Handles version checking, downloading, and self-installation from GitHub Releases.
actor AppUpdater {
    static let shared = AppUpdater()

    private let owner     = "averywhitted"
    private let repo      = "script-to-audio-app"
    private let assetName = "TableRead.zip"

    // MARK: — Version comparison

    /// Returns true if `candidate` is a higher version than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
             .split(separator: ".").compactMap { Int($0) }
        }
        let a = parts(candidate)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false   // equal
    }

    // MARK: — Check for updates

    /// Fetches the latest GitHub release and returns an `UpdateInfo` if a newer version exists.
    /// Returns `nil` when already up-to-date, when there are no releases yet, or on network error.
    func checkForUpdates() async -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
        else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json",   forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28",                    forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("TableRead/\(currentVersion)",   forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }

        guard let json      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag       = json["tag_name"]  as? String,
              let htmlStr   = json["html_url"]  as? String,
              let htmlURL   = URL(string: htmlStr)
        else { return nil }

        guard AppUpdater.isNewer(tag, than: currentVersion) else { return nil }

        let notes  = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assets = json["assets"] as? [[String: Any]] ?? []
        let asset  = assets.first { ($0["name"] as? String) == assetName }

        if let downloadStr = asset?["browser_download_url"] as? String,
           let downloadURL = URL(string: downloadStr) {
            return UpdateInfo(
                version:      tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                downloadURL:  downloadURL,
                htmlURL:      htmlURL,
                releaseNotes: notes,
                hasZipAsset:  true
            )
        } else {
            // Release exists but zip hasn't been uploaded yet — direct user to the page
            return UpdateInfo(
                version:      tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                downloadURL:  htmlURL,
                htmlURL:      htmlURL,
                releaseNotes: notes,
                hasZipAsset:  false
            )
        }
    }

    // MARK: — Download & extract

    /// Downloads the zip asset and extracts it to a temp directory.
    /// Returns the URL of the extracted `TableRead.app`.
    func downloadAndExtract(
        info: UpdateInfo,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableReadUpdate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let zipURL = tmpDir.appendingPathComponent("TableRead.zip")

        // --- Download ---
        let helper = DownloadHelper(destination: zipURL, onProgress: onProgress)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: helper,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let destZipURL: URL = try await withCheckedThrowingContinuation { cont in
            helper.continuation = cont
            session.downloadTask(with: info.downloadURL).resume()
        }

        // --- Unzip ---
        let unzip = Process()
        unzip.launchPath  = "/usr/bin/unzip"
        unzip.arguments   = ["-q", "-o", destZipURL.path, "-d", tmpDir.path]
        unzip.launch()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }

        // Locate the .app bundle inside the extracted folder
        let items = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        guard let appURL = items.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appBundleNotFound
        }
        return appURL
    }

    // MARK: — Install

    /// Replaces the current running bundle with `newAppURL` via a detached helper script,
    /// then terminates this instance.
    func installUpdate(from newAppURL: URL) throws {
        let currentApp = Bundle.main.bundleURL
        let safeNew     = shell(newAppURL.path)
        let safeCurrent = shell(currentApp.path)

        let script = """
        #!/bin/bash
        sleep 1.5
        rm -rf \(safeCurrent)
        cp -R \(safeNew) \(safeCurrent)
        xattr -cr \(safeCurrent)
        open \(safeCurrent)
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tableread_update_\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )
        let p = Process()
        p.launchPath  = "/bin/bash"
        p.arguments   = [scriptURL.path]
        p.launch()

        // Quit this instance — the script will reopen us after the copy completes
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    // MARK: — Helpers

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Shell-safe single-quoted path escaping.
    private func shell(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Download helper delegate

private final class DownloadHelper: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onProgress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress  = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten written: Int64,
        totalBytesExpectedToWrite expected: Int64
    ) {
        guard expected > 0 else { return }
        onProgress(Double(written) / Double(expected))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - Update errors

enum UpdateError: LocalizedError {
    case extractionFailed
    case appBundleNotFound

    var errorDescription: String? {
        switch self {
        case .extractionFailed:   return "Failed to extract the update archive."
        case .appBundleNotFound:  return "Could not locate TableRead.app inside the downloaded archive."
        }
    }
}
