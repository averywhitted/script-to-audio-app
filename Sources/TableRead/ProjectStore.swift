import Foundation
import AppKit

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
    @Published var pendingDeletion: Set<UUID> = []
    @Published var projectsBaseURL: URL

    // MARK: - Init

    init() {
        if let saved = UserDefaults.standard.string(forKey: "projectsBaseURL") {
            projectsBaseURL = URL(fileURLWithPath: saved)
        } else {
            projectsBaseURL = Self.defaultBaseURL
        }
        loadAllProjects()
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
            loaded.append(project)
        }
        projects = loaded
            .filter { !pendingDeletion.contains($0.id) }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    // MARK: - Create

    func createProject(name: String, at customURL: URL? = nil) throws -> Project {
        let folderURL = customURL ?? projectsBaseURL.appendingPathComponent(sanitizedName(name))
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let project = Project.new(name: name, folderURL: folderURL)
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

    // MARK: - Soft delete

    func deleteProject(_ project: Project) {
        pendingDeletion.insert(project.id)
        projects.removeAll { $0.id == project.id }
        if currentProject?.id == project.id {
            currentProject = nil
        }
    }

    func recoverProject(id: UUID) {
        pendingDeletion.remove(id)
        loadAllProjects()
    }

    /// Permanently trash all soft-deleted projects. Call on app quit or explicit user confirm.
    func confirmDeletion() {
        let fm = FileManager.default
        guard !pendingDeletion.isEmpty else { return }

        // Collect folder URLs from disk since they may not be in `projects` anymore
        let contents = (try? fm.contentsOfDirectory(
            at: projectsBaseURL, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []

        for folder in contents {
            let manifestURL = folder.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let project = try? JSONDecoder.projectDecoder.decode(Project.self, from: data),
                  pendingDeletion.contains(project.id)
            else { continue }
            NSWorkspace.shared.recycle([folder])
        }
        pendingDeletion = []
    }

    // MARK: - Projects folder

    func changeProjectsBaseURL(_ url: URL) {
        projectsBaseURL = url
        UserDefaults.standard.set(url.path, forKey: "projectsBaseURL")
        loadAllProjects()
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
