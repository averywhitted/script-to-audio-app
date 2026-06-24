import Foundation
import AppKit

struct DeletedProjectRecord {
    let project: Project
    let originalURL: URL
    let trashedURL: URL
}

struct ArchivedProjectMeta: Codable {
    var project: Project
    var zipFilename: String
    var originalFolderName: String
}

@MainActor
final class ProjectStore: ObservableObject {

    // MARK: - Default location

    static var defaultBaseURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Table Read")
    }

    // MARK: - Published state

    @Published var projects: [Project] = []
    @Published var currentProject: Project?
    @Published var recentlyDeleted: [DeletedProjectRecord] = []
    @Published var archivedProjects: [ArchivedProjectMeta] = []
    @Published var archivingIDs: Set<UUID> = []
    @Published var projectsBaseURL: URL

    // MARK: - Init

    init() {
        if let saved = UserDefaults.standard.string(forKey: "projectsBaseURL") {
            projectsBaseURL = URL(fileURLWithPath: saved)
        } else {
            projectsBaseURL = Self.defaultBaseURL
        }
        loadAllProjects()
        loadArchivedProjects()
    }

    // MARK: - Load

    func loadAllProjects() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsBaseURL.path) else { return }
        let contents = (try? fm.contentsOfDirectory(
            at: projectsBaseURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        var loaded: [Project] = []
        for folder in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = folder.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  var project = try? JSONDecoder.projectDecoder.decode(Project.self, from: data)
            else { continue }
            project.folderURL = folder
            // Reconcile stale renderedScenes: if the manifest says nothing is rendered
            // but .m4a files exist, parse their scene numbers and backfill.
            if project.renderedScenes.isEmpty {
                let audioFiles = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))
                    ?? []
                let sceneNumbers = audioFiles
                    .filter { $0.pathExtension == "m4a" }
                    .compactMap { url -> Int? in
                        // Filename pattern: Scene_NN_Title.m4a
                        let stem = url.deletingPathExtension().lastPathComponent
                        guard stem.hasPrefix("Scene_"),
                              let numStr = stem.dropFirst(6).split(separator: "_").first,
                              let num = Int(numStr) else { return nil }
                        return num
                    }
                    .sorted()
                if !sceneNumbers.isEmpty {
                    project.renderedScenes = sceneNumbers
                    try? saveProject(project)
                }
            }
            loaded.append(project)
        }
        projects = loaded.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    // MARK: - Create

    func createProject(name: String, at customURL: URL? = nil, engine: EngineKind = .macOS) throws -> Project {
        let folderURL = customURL ?? projectsBaseURL.appendingPathComponent(sanitizedName(name))
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let project = Project.new(name: name, folderURL: folderURL, engine: engine)
        try saveProject(project)
        projects.insert(project, at: 0)
        return project
    }

    // MARK: - Open

    @discardableResult
    func openProject(_ project: Project) -> Project {
        var updated = project
        updated.lastOpenedAt = Date()
        try? saveProject(updated)
        currentProject = updated
        if let idx = projects.firstIndex(where: { $0.id == updated.id }) {
            projects[idx] = updated
        }
        return updated
    }

    // MARK: - Save

    func saveProject(_ project: Project) throws {
        guard let folderURL = project.folderURL else { return }
        let manifestURL = folderURL.appendingPathComponent("project.json")
        let tempURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent("project.json.tmp")
        let data = try JSONEncoder.projectEncoder.encode(project)
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tempURL)
        // Update in-memory list
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        }
        if currentProject?.id == project.id {
            currentProject = project
        }
    }

    /// Sync in-memory AppState back into the current project and save to disk.
    func saveCurrentProject(_ appState: AppState) {
        guard var project = currentProject else { return }
        project = appState.syncToProject(project)
        try? saveProject(project)
        currentProject = project
    }

    // MARK: - Delete / Restore

    func deleteProject(_ project: Project) {
        guard let folderURL = project.folderURL else { return }
        projects.removeAll { $0.id == project.id }
        if currentProject?.id == project.id { currentProject = nil }
        NSWorkspace.shared.recycle([folderURL]) { [weak self] trashedItems, _ in
            guard let self, let trashedURL = trashedItems[folderURL] else { return }
            Task { @MainActor [weak self] in
                self?.recentlyDeleted.append(
                    DeletedProjectRecord(project: project, originalURL: folderURL, trashedURL: trashedURL)
                )
            }
        }
    }

    func restoreProject(id: UUID) {
        guard let record = recentlyDeleted.first(where: { $0.project.id == id }) else { return }
        var destination = record.originalURL
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = projectsBaseURL.appendingPathComponent(
                record.originalURL.lastPathComponent + "_restored"
            )
        }
        try? FileManager.default.moveItem(at: record.trashedURL, to: destination)
        recentlyDeleted.removeAll { $0.project.id == id }
        loadAllProjects()
    }

    // MARK: - Rename

    func renameProject(id: UUID, newName: String) {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty,
              var project = projects.first(where: { $0.id == id }) else { return }
        project.name = newName.trimmingCharacters(in: .whitespaces)
        try? saveProject(project)
    }

    // MARK: - Archive / Unarchive

    func loadArchivedProjects() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsBaseURL.path) else { return }
        let contents = (try? fm.contentsOfDirectory(
            at: projectsBaseURL, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        archivedProjects = contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".archive-meta.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.projectDecoder.decode(ArchivedProjectMeta.self, from: data)
            }
            .sorted { $0.project.lastOpenedAt > $1.project.lastOpenedAt }
    }

    func archiveProject(_ project: Project) async {
        guard let folderURL = project.folderURL else { return }
        let id = project.id
        let baseURL = projectsBaseURL
        let folderName = folderURL.lastPathComponent
        let zipFilename = "\(id.uuidString).zip"
        let zipURL = baseURL.appendingPathComponent(zipFilename)
        let metaURL = baseURL.appendingPathComponent("\(id.uuidString).archive-meta.json")

        archivingIDs.insert(id)

        // Write sidecar meta JSON before zipping so we can show it in the archived list
        let meta = ArchivedProjectMeta(project: project, zipFilename: zipFilename, originalFolderName: folderName)
        if let metaData = try? JSONEncoder.projectEncoder.encode(meta) {
            try? metaData.write(to: metaURL)
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                proc.arguments = ["-r", zipURL.path, folderName]
                proc.currentDirectoryURL = baseURL
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw NSError(domain: "Archive", code: Int(proc.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "zip exited with status \(proc.terminationStatus)"])
                }
            }.value

            try FileManager.default.removeItem(at: folderURL)
            projects.removeAll { $0.id == id }
            if currentProject?.id == id { currentProject = nil }
            loadArchivedProjects()
        } catch {
            // Roll back: remove the meta file, leave original folder intact
            try? FileManager.default.removeItem(at: metaURL)
            try? FileManager.default.removeItem(at: zipURL)
        }

        archivingIDs.remove(id)
    }

    func unarchiveProject(id: UUID) async {
        guard let meta = archivedProjects.first(where: { $0.project.id == id }) else { return }
        let baseURL = projectsBaseURL
        let zipURL = baseURL.appendingPathComponent(meta.zipFilename)
        let metaURL = baseURL.appendingPathComponent("\(id.uuidString).archive-meta.json")
        let restoredFolder = baseURL.appendingPathComponent(meta.originalFolderName)

        archivingIDs.insert(id)

        do {
            try await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", zipURL.path, "-d", baseURL.path]
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw NSError(domain: "Unarchive", code: Int(proc.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "unzip exited with status \(proc.terminationStatus)"])
                }
            }.value

            // Verify rendered audio files actually exist; clear stale renderedScenes if not
            verifyRenderedScenesAfterUnarchive(in: restoredFolder)

            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.removeItem(at: metaURL)
            archivedProjects.removeAll { $0.project.id == id }
            loadAllProjects()
        } catch {
            // Leave zip and meta in place; nothing changed on disk
        }

        archivingIDs.remove(id)
    }

    private func verifyRenderedScenesAfterUnarchive(in folder: URL) {
        let fm = FileManager.default
        let manifestURL = folder.appendingPathComponent("project.json")
        guard fm.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              var project = try? JSONDecoder.projectDecoder.decode(Project.self, from: data),
              !project.renderedScenes.isEmpty else { return }

        let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let hasAudioFiles = contents.contains { $0.pathExtension == "m4a" }

        if !hasAudioFiles {
            project.renderedScenes = []
            if let updated = try? JSONEncoder.projectEncoder.encode(project) {
                try? updated.write(to: manifestURL, options: .atomic)
            }
        }
    }

    // MARK: - Projects folder

    func changeProjectsBaseURL(_ url: URL) {
        projectsBaseURL = url
        UserDefaults.standard.set(url.path, forKey: "projectsBaseURL")
        loadAllProjects()
        loadArchivedProjects()
    }

    func ensureProjectsDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: projectsBaseURL, withIntermediateDirectories: true
        )
    }

    // MARK: - Helpers

    private func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let sanitized = name.unicodeScalars
            .filter { allowed.contains($0) }
            .map { Character($0) }
            .reduce("", { $0 + String($1) })
            .trimmingCharacters(in: .whitespaces)
        return sanitized.isEmpty ? "Untitled Project" : sanitized
    }
}
