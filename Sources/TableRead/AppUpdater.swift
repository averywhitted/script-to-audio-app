import Foundation
import AppKit
import CryptoKit

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
    /// URL of the zip's detached Ed25519 signature (`TableRead.zip.sig`).
    /// A release without one is offered as a manual download only.
    var signatureURL: URL? = nil
}

/// An extracted update whose archive passed the Ed25519 signature check.
/// Only `AppUpdater` can create one, so `installUpdate` can't be handed an
/// app that skipped verification.
struct VerifiedUpdate: Sendable {
    let appURL: URL
    fileprivate init(appURL: URL) { self.appURL = appURL }
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
    private let signatureAssetName = "TableRead.zip.sig"

    /// Ed25519 public key for update archives. The matching private key lives
    /// in the release machine's Keychain; see scripts/update_signing.swift.
    /// This is the trust anchor for in-app updates — release builds are
    /// ad-hoc signed, so there is no Apple Team ID to check against (#58).
    static let updatePublicKey = "VVVOeTsKN4JVSQ5oGhu2DcXpNOq8l7SqZcP8IGuoOGw="

    /// True when `signature` (base64) is a valid signature of `data` by the
    /// holder of `updatePublicKey`.
    static func isValidUpdateSignature(_ signature: String, for data: Data,
                                       publicKey: String = updatePublicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sigData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return key.isValidSignature(sigData, for: data)
    }

    // MARK: — Download source

    /// The asset URL arrives inside API JSON, and whatever it points at gets
    /// unpacked and executed by `installUpdate`. Restrict it to GitHub's own
    /// hosts so a tampered or redirected URL cannot aim the self-installer at
    /// an arbitrary server. An untrusted URL falls back to opening the release
    /// page, which only ever hands the user a link.
    static func isTrustedDownloadHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

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
        func assetURL(named name: String) -> URL? {
            guard let asset = assets.first(where: { ($0["name"] as? String) == name }),
                  let str = asset["browser_download_url"] as? String,
                  let url = URL(string: str),
                  AppUpdater.isTrustedDownloadHost(url)
            else { return nil }
            return url
        }

        // In-app install needs both the zip and its signature; a release
        // missing either is offered as a manual download from the release page.
        if let downloadURL = assetURL(named: assetName),
           let signatureURL = assetURL(named: signatureAssetName) {
            return UpdateInfo(
                version:      tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                downloadURL:  downloadURL,
                htmlURL:      htmlURL,
                releaseNotes: notes,
                hasZipAsset:  true,
                signatureURL: signatureURL
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

    /// Downloads the zip asset, verifies its Ed25519 signature, and extracts it
    /// to a temp directory. Nothing is unpacked until the signature checks out.
    func downloadAndExtract(
        info: UpdateInfo,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> VerifiedUpdate {
        guard let signatureURL = info.signatureURL,
              AppUpdater.isTrustedDownloadHost(signatureURL) else {
            throw UpdateError.signatureVerificationFailed("this release has no update signature.")
        }
        var sigReq = URLRequest(url: signatureURL, timeoutInterval: 30)
        sigReq.setValue("TableRead/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (sigData, sigResponse) = try await URLSession.shared.data(for: sigReq)
        guard (sigResponse as? HTTPURLResponse)?.statusCode == 200,
              let signature = String(data: sigData, encoding: .utf8) else {
            throw UpdateError.signatureVerificationFailed("the update signature could not be downloaded.")
        }

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

        // --- Verify ---
        guard let zipData = FileManager.default.contents(atPath: destZipURL.path),
              AppUpdater.isValidUpdateSignature(signature, for: zipData) else {
            UpdateLogger.log("downloadAndExtract: REFUSED — signature does not match")
            throw UpdateError.signatureVerificationFailed(
                "the download's signature does not match. It may be corrupted or not from this project.")
        }
        UpdateLogger.log("downloadAndExtract: archive signature verified")

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
        return VerifiedUpdate(appURL: appURL)
    }

    // MARK: — Install

    /// Replaces the current running bundle with the verified update via a
    /// detached helper script, then terminates this instance.
    func installUpdate(_ update: VerifiedUpdate) async throws {
        let newAppURL = update.appURL
        let currentApp = Bundle.main.bundleURL
        UpdateLogger.log("installUpdate: begin")
        UpdateLogger.log("  currentApp = \(currentApp.path)")
        UpdateLogger.log("  newAppURL  = \(newAppURL.path)")

        // `Bundle.main.bundleURL` returns the *containing directory* when the
        // executable is not inside a bundle (a bare binary, a `swift build`
        // product). The script below runs `rm -rf` on this path, so without
        // this guard an app launched that way would delete the folder it sits
        // in — a Desktop, a Documents folder, a user's working directory.
        guard currentApp.pathExtension == "app",
              FileManager.default.fileExists(
                  atPath: currentApp.appendingPathComponent("Contents/MacOS").path)
        else {
            UpdateLogger.log("  REFUSED: \(currentApp.path) is not an .app bundle")
            throw UpdateError.notAnAppBundle
        }

        // Provenance was established by the archive's Ed25519 signature
        // (`VerifiedUpdate`). This adds the code-signature checks on top.
        try verifySignature(of: newAppURL, againstRunning: currentApp)
        UpdateLogger.log("  code signature verified")

        let safeNew     = shell(newAppURL.path)
        let safeCurrent = shell(currentApp.path)
        // Sibling paths on the same volume, so each `mv` is a rename rather than
        // a copy. The new app is copied in BEFORE the old one is touched: if the
        // copy fails (full disk, permissions), the installed app is left intact.
        let safeStaged   = shell(currentApp.path + ".updating")
        let safePrevious = shell(currentApp.path + ".previous")

        let logPath = shell(UpdateLogger.logURL.path)
        let script = """
        #!/bin/bash
        log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] script: $1" >> \(logPath); }
        log "started, pid=$$"
        sleep 2
        rm -rf \(safeStaged) \(safePrevious)
        if ! cp -R \(safeNew) \(safeStaged) 2>>/tmp/tableread_update_err.txt; then
            log "copy failed; installed app left untouched"
            rm -rf \(safeStaged)
            open \(safeCurrent)
            exit 1
        fi
        xattr -cr \(safeStaged) 2>>/tmp/tableread_update_err.txt
        if ! mv \(safeCurrent) \(safePrevious); then
            log "could not move old app aside; installed app left untouched"
            rm -rf \(safeStaged)
            open \(safeCurrent)
            exit 1
        fi
        if ! mv \(safeStaged) \(safeCurrent); then
            log "could not move new app into place; restoring old app"
            mv \(safePrevious) \(safeCurrent)
            open \(safeCurrent)
            exit 1
        fi
        rm -rf \(safePrevious)
        log "opening new app"
        open \(safeCurrent)
        log "done (exit $?)"
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
            try await installUpdate(VerifiedUpdate(appURL: copy))
        } catch {
            UpdateLogger.log("testInstall: FAILED — \(error)")
        }
    }

    // MARK: — Signature verification

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe   // codesign writes its details to stderr
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return CommandResult(status: proc.terminationStatus,
                             output: String(data: data, encoding: .utf8) ?? "")
    }

    /// Team ID from the bundle's signature, or nil when unsigned / ad-hoc.
    private func teamIdentifier(of appURL: URL) throws -> String? {
        let result = try run("/usr/bin/codesign", ["-d", "--verbose=4", appURL.path])
        guard result.status == 0 else { return nil }
        for line in result.output.components(separatedBy: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = String(line.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    /// Requires an intact code signature on the downloaded bundle. When the
    /// running app carries a Team ID (Developer ID signed, #8), the update must
    /// carry the same one. Ad-hoc builds have no Team ID; for those the
    /// archive's Ed25519 signature is the trust anchor, checked before unzip.
    private func verifySignature(of newAppURL: URL, againstRunning currentApp: URL) throws {
        let verify = try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", newAppURL.path])
        guard verify.status == 0 else {
            throw UpdateError.signatureVerificationFailed(
                "the downloaded app's code signature is not valid. "
                + verify.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let expected = try teamIdentifier(of: currentApp) else { return }
        guard let actual = try teamIdentifier(of: newAppURL) else {
            throw UpdateError.signatureVerificationFailed(
                "the downloaded app is not signed.")
        }
        guard actual == expected else {
            throw UpdateError.signatureVerificationFailed(
                "the downloaded app is signed by a different developer "
                + "(expected \(expected), found \(actual)).")
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
    case notAnAppBundle
    case signatureVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed:   return "Failed to extract the update archive."
        case .appBundleNotFound:  return "Could not locate TableRead.app inside the downloaded archive."
        case .notAnAppBundle:
            return "TableRead is not running from an .app bundle, so it cannot update itself in place. "
                 + "Download the new version from the Releases page instead."
        case .signatureVerificationFailed(let reason):
            return "Update cancelled: \(reason)"
        }
    }
}
