import Foundation

/// A named, reusable FormatProfile a user saved from a calibration session,
/// selectable as a starting point when calibrating a different project.
struct FormatTemplateLibraryItem: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var originProjectName: String
    var profile: FormatProfile
}

/// Cross-project store for saved format templates, modeled on ProjectStore's
/// atomic tmp-write/replace idiom but simpler (flat JSON, no PDF/zip). Lives
/// in its own "Format Templates" subfolder of the same projects base
/// directory — a sibling to project folders, never inside one, so a template
/// survives independently of any single project. ProjectStore.loadAllProjects()
/// only treats a subfolder as a project if it contains project.json, so this
/// folder is silently skipped by the project scanner.
@MainActor
final class FormatTemplateLibrary: ObservableObject {
    @Published var templates: [FormatTemplateLibraryItem] = []

    private let baseURLProvider: () -> URL

    var folderURL: URL {
        baseURLProvider().appendingPathComponent("Format Templates")
    }

    init(baseURLProvider: @escaping () -> URL) {
        self.baseURLProvider = baseURLProvider
        loadAll()
    }

    func loadAll() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folderURL.path) else {
            templates = []
            return
        }
        let contents = (try? fm.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        let loaded: [FormatTemplateLibraryItem] = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.projectDecoder.decode(FormatTemplateLibraryItem.self, from: data)
            }
        templates = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ item: FormatTemplateLibraryItem) throws -> FormatTemplateLibraryItem {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let fileURL = folderURL.appendingPathComponent("\(item.id.uuidString).json")
        let tempURL = folderURL.appendingPathComponent("\(item.id.uuidString).json.tmp")
        let data = try JSONEncoder.projectEncoder.encode(item)
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        if let idx = templates.firstIndex(where: { $0.id == item.id }) {
            templates[idx] = item
        } else {
            templates.insert(item, at: 0)
        }
        templates.sort { $0.createdAt > $1.createdAt }
        return item
    }

    func delete(_ id: UUID) {
        let fileURL = folderURL.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
        templates.removeAll { $0.id == id }
    }

    func rename(id: UUID, newName: String) {
        guard var item = templates.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        item.name = trimmed
        try? save(item)
    }
}
