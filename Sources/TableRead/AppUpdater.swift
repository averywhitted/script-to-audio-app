import Foundation
import AppKit

// MARK: - Update logger

/// Appends timestamped entries to a persistent log file in Application Support.
/// The file survives app restarts so post-mortem analysis is possible even
/// after the install script relaunches a new version.
enum UpdateLogger {
    static var logURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TableRead")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("update_log.txt")
    }

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: logURL)
    }
}

// MARK: - Data types

enum UpdateChannel: String, CaseIterable, Sendable {
    case stable = "stable"
    case beta   = "beta"

    var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .beta:   return "Beta"
        }
    }

    var description: String {
        switch self {
        case .stable: return "Tested, production-ready releases only."
        case .beta:   return "Includes pre-releases with new features that may have rough edges."
        }
    }
}

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

    /// Fetches the appropriate GitHub release for the given channel and returns an
    /// `UpdateInfo` if a newer version exists.  Returns `nil` when already
    /// up-to-date, when there are no releases yet, or on network error.
    ///
    /// - **stable**: queries `/releases/latest` — GitHub returns the most recent
    ///   non-prerelease, non-draft release.
    /// - **beta**: queries `/releases?per_page=1` — returns the most recently
    ///   published release regardless of prerelease status.
    func checkForUpdates(channel: UpdateChannel = .beta) async -> UpdateInfo? {
        let endpoint: String
        switch channel {
        case .stable:
            endpoint = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        case .beta:
            endpoint = "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=1"
        }
        guard let url = URL(string: endpoint) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github+json",   forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28",                    forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("TableRead/\(currentVersion)",   forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }

        // Beta uses the list endpoint (returns a JSON array); stable uses the
        // single-object endpoint.  Normalise both to a single release dict.
        let json: [String: Any]?
        if channel == .beta {
            let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            json = arr?.first
        } else {
            json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        guard let release  = json,
              let tag      = release["tag_name"] as? String,
              let htmlStr  = release["html_url"]  as? String,
              let htmlURL  = URL(string: htmlStr)
        else { return nil }

        guard AppUpdater.isNewer(tag, than: currentVersion) else { return nil }

        let notes  = (release["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assets = release["assets"] as? [[String: Any]] ?? []
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
    func installUpdate(from newAppURL: URL) async throws {
        let currentApp = Bundle.main.bundleURL
        UpdateLogger.log("installUpdate: begin")
        UpdateLogger.log("  currentApp = \(currentApp.path)")
        UpdateLogger.log("  newAppURL  = \(newAppURL.path)")

        let safeNew     = shell(newAppURL.path)
        let safeCurrent = shell(currentApp.path)

        let logPath = UpdateLogger.logURL.path
        let script = """
        #!/bin/bash
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] script: started, pid=$$" >> \(shell(logPath))
        sleep 2
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] script: removing old app" >> \(shell(logPath))
        rm -rf \(safeCurrent) 2>>/tmp/tableread_update_err.txt
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] script: copying new app (exit $?)" >> \(shell(logPath))
        cp -R \(safeNew) \(safeCurrent) 2>>/tmp/tableread_update_err.txt
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] script: xattr (exit $?)" >> \(shell(logPath))
        xattr -cr \(safeCurrent) 2>>/tmp/tableread_update_err.txt
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] script: opening new app (exit $?)" >> \(shell(logPath))
        open \(safeCurrent)
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] script: done (exit $?)" >> \(shell(logPath))
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tableread_update_\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )
        UpdateLogger.log("  scriptURL  = \(scriptURL.path)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments     = [scriptURL.path]
        try p.run()
        UpdateLogger.log("  bash script launched (pid \(p.processIdentifier))")

        // Brief pause so the script process is definitely running before we exit.
        try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms

        UpdateLogger.log("  calling NSApplication.terminate")
        await MainActor.run { NSApplication.shared.terminate(nil) }

        // Hard fallback — exit(0) is synchronous and cannot be blocked.
        UpdateLogger.log("  terminate returned — calling exit(0)")
        exit(0)
    }

    // MARK: — Dry-run test

    /// Exercises the full install flow using a copy of the running app as the
    /// "new" version.  Intended for use from the Debug menu only.
    /// The app will quit and relaunch — test in a regular build, not Xcode.
    func testInstall() async {
        UpdateLogger.clear()
        UpdateLogger.log("testInstall: begin — version \(currentVersion)")
        do {
            let src = Bundle.main.bundleURL
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("TableReadTestUpdate_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let copy = tmp.appendingPathComponent("TableRead.app")
            UpdateLogger.log("testInstall: copying bundle to \(copy.path)")
            try FileManager.default.copyItem(at: src, to: copy)
            UpdateLogger.log("testInstall: copy done, calling installUpdate")
            try await installUpdate(from: copy)
        } catch {
            UpdateLogger.log("testInstall: FAILED — \(error)")
        }
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
