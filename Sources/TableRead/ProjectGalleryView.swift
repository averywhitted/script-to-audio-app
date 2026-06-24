import SwiftUI
import AppKit

// MARK: - Enums

enum GalleryViewMode: String, CaseIterable {
    case grid, list
}

enum ProjectSortKey: String, CaseIterable {
    case recent, name, scenes, memorized

    var label: String {
        switch self {
        case .recent: return "Last Opened"
        case .name: return "Name"
        case .scenes: return "Scenes"
        case .memorized: return "Memorized"
        }
    }
}

enum GallerySortOrder { case ascending, descending }

// MARK: - Frame tracking for rubber-band selection

struct CardFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Main view

struct ProjectGalleryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var projectStore: ProjectStore

    // Navigation / sheet state
    @State private var isShowingNewProjectSheet = false
    @State private var isImportingPDF = false
    @State private var pendingProjectForPDF: Project?
    // Stored until PDF is picked — project folder is NOT created until then
    @State private var pendingProjectName: String = ""
    @State private var pendingProjectCustomURL: URL? = nil

    // Selection
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionAnchorID: UUID? = nil

    // View mode & archive
    @State private var viewMode: GalleryViewMode = .grid
    @State private var showArchived = false

    // Rename
    @State private var isRenamingID: UUID? = nil

    // Sort & filter
    @State private var sortKey: ProjectSortKey = .recent
    @State private var sortOrder: GallerySortOrder = .descending
    @State private var filterRendered = false
    @State private var filterHasScreenplay = false

    // Rubber-band selection
    @State private var dragAnchor: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var isDraggingSelection = false
    @State private var cardFrames: [UUID: CGRect] = [:]

    private let gridColumns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)]

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            galleryToolbar
            Divider()
            mainContent
        }
        .overlay(alignment: .bottom) {
            if !selectedIDs.isEmpty && !showArchived {
                ProjectSelectionActionsBar(
                    count: selectedIDs.count,
                    onArchive: { archiveSelected() },
                    onDelete: { deleteSelected() },
                    onClear: { withAnimation { selectedIDs = [] } }
                )
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: selectedIDs.isEmpty)
        .sheet(isPresented: $isShowingNewProjectSheet) {
            NewProjectSheet { name, customURL in createProject(name: name, at: customURL) }
        }
        .fileImporter(
            isPresented: $isImportingPDF,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                finishProjectCreation(pdfURL: url)
            }
            // On cancel: nothing to clean up — folder wasn't created yet.
            pendingProjectForPDF = nil
        }
        .onAppear { projectStore.loadAllProjects() }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if showArchived {
            ArchivedGalleryBody()
        } else if displayedProjects.isEmpty && projectStore.recentlyDeleted.isEmpty {
            emptyState
        } else {
            activeGalleryBody
        }
    }

    private var activeGalleryBody: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Rubber-band background layer
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(rubberBandGesture)

                VStack(spacing: 0) {
                    if viewMode == .list {
                        listColumnHeaders
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }

                    if viewMode == .grid {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(displayedProjects) { project in
                                ProjectGridCard(
                                    project: project,
                                    isSelected: selectedIDs.contains(project.id),
                                    isRenaming: isRenamingID == project.id,
                                    isArchiving: projectStore.archivingIDs.contains(project.id),
                                    onTap: { handleTap(project: project, modifiers: $0) },
                                    onDoubleTap: { openProject(project) },
                                    onDoubleTapName: { isRenamingID = project.id },
                                    onRenameCommit: { commitRename(id: project.id, name: $0) },
                                    onRenameCancel: { isRenamingID = nil }
                                )
                                .background(cardFrameReader(id: project.id))
                            }
                        }
                        .padding(24)
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(displayedProjects) { project in
                                ProjectListRow(
                                    project: project,
                                    isSelected: selectedIDs.contains(project.id),
                                    isRenaming: isRenamingID == project.id,
                                    isArchiving: projectStore.archivingIDs.contains(project.id),
                                    onTap: { handleTap(project: project, modifiers: $0) },
                                    onDoubleTap: { openProject(project) },
                                    onDoubleTapName: { isRenamingID = project.id },
                                    onRenameCommit: { commitRename(id: project.id, name: $0) },
                                    onRenameCancel: { isRenamingID = nil }
                                )
                                .background(cardFrameReader(id: project.id))
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }

                    if !projectStore.recentlyDeleted.isEmpty {
                        RecentlyDeletedSection()
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }

                // Rubber-band selection rectangle overlay
                if let rect = selectionRectangle {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "gallery")
            .onPreferenceChange(CardFramePreference.self) { cardFrames = $0 }
        }
        .scrollDisabled(isDraggingSelection)
    }

    // MARK: - Toolbar

    private var galleryToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Table Read")
                    .font(.title2.weight(.bold))
                Text("Projects")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Active / Archived toggle
            Picker("", selection: $showArchived) {
                Text("Active").tag(false)
                Text("Archived").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: showArchived) { _, _ in selectedIDs = [] }

            Divider().frame(height: 20)

            // Filters menu
            Menu {
                Toggle(isOn: $filterRendered) {
                    Label("Rendered", systemImage: filterRendered ? "checkmark" : "")
                }
                Toggle(isOn: $filterHasScreenplay) {
                    Label("Has Screenplay", systemImage: filterHasScreenplay ? "checkmark" : "")
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    if filterRendered || filterHasScreenplay {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Filter projects")

            // View mode toggle
            Picker("", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(GalleryViewMode.grid)
                Image(systemName: "list.bullet").tag(GalleryViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 64)

            // Sort menu (grid only — list has column headers)
            if viewMode == .grid {
                Menu {
                    ForEach(ProjectSortKey.allCases, id: \.self) { key in
                        Button {
                            if sortKey == key {
                                sortOrder = sortOrder == .ascending ? .descending : .ascending
                            } else {
                                sortKey = key
                                sortOrder = .descending
                            }
                        } label: {
                            HStack {
                                Text(key.label)
                                if sortKey == key {
                                    Image(systemName: sortOrder == .descending ? "arrow.down" : "arrow.up")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("Sort projects")
            }

            Divider().frame(height: 20)

            Button {
                isShowingNewProjectSheet = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - List column headers

    private var listColumnHeaders: some View {
        HStack(spacing: 0) {
            // Name column
            Button {
                toggleSort(.name)
            } label: {
                HStack(spacing: 4) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sortKey == .name ? .primary : .secondary)
                    sortIndicator(for: .name)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Scenes column
            Button {
                toggleSort(.scenes)
            } label: {
                HStack(spacing: 4) {
                    Text("Scenes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sortKey == .scenes ? .primary : .secondary)
                    sortIndicator(for: .scenes)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 70, alignment: .trailing)

            // Last Opened column
            Button {
                toggleSort(.recent)
            } label: {
                HStack(spacing: 4) {
                    Text("Last Opened")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sortKey == .recent ? .primary : .secondary)
                    sortIndicator(for: .recent)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.leading, 36)
        .padding(.trailing, 6)
    }

    @ViewBuilder
    private func sortIndicator(for key: ProjectSortKey) -> some View {
        if sortKey == key {
            Image(systemName: sortOrder == .descending ? "arrow.down" : "arrow.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func toggleSort(_ key: ProjectSortKey) {
        if sortKey == key {
            sortOrder = sortOrder == .ascending ? .descending : .ascending
        } else {
            sortKey = key
            sortOrder = .descending
        }
    }

    // MARK: - Computed project list

    var displayedProjects: [Project] {
        var list = projectStore.projects
        if filterRendered { list = list.filter { !$0.renderedScenes.isEmpty } }
        if filterHasScreenplay { list = list.filter { !$0.pdfFilename.isEmpty } }
        switch sortKey {
        case .recent:
            list.sort { sortOrder == .descending ? $0.lastOpenedAt > $1.lastOpenedAt : $0.lastOpenedAt < $1.lastOpenedAt }
        case .name:
            list.sort { sortOrder == .descending ? $0.name > $1.name : $0.name < $1.name }
        case .scenes:
            list.sort { sortOrder == .descending ? $0.renderedScenes.count > $1.renderedScenes.count : $0.renderedScenes.count < $1.renderedScenes.count }
        case .memorized:
            break // stub — no memorization data yet, preserve existing order
        }
        return list
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No projects yet")
                    .font(.title3.weight(.semibold))
                Text("Create a new project to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("New Project") { isShowingNewProjectSheet = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Actions

    private func openProject(_ project: Project) {
        // If a background render is running for a different project, block navigation
        if state.isGenerating,
           let bgID = state.backgroundRenderProjectID,
           bgID != project.id {
            state.errorMessage = "A render is in progress. Wait for it to finish before opening another project."
            return
        }
        isRenamingID = nil
        selectedIDs = []
        let opened = projectStore.openProject(project)
        state.loadFromProject(opened)
    }

    private func handleTap(project: Project, modifiers: EventModifiers) {
        isRenamingID = nil
        if modifiers.contains(.command) {
            // Cmd+click: toggle without clearing others
            if selectedIDs.contains(project.id) {
                selectedIDs.remove(project.id)
            } else {
                selectedIDs.insert(project.id)
                selectionAnchorID = project.id
            }
        } else if modifiers.contains(.shift), let anchor = selectionAnchorID {
            // Shift+click: range select
            rangeSelect(from: anchor, to: project.id)
        } else {
            // Plain click: exclusive select
            if selectedIDs == [project.id] {
                selectedIDs = []
                selectionAnchorID = nil
            } else {
                selectedIDs = [project.id]
                selectionAnchorID = project.id
            }
        }
    }

    private func rangeSelect(from anchorID: UUID, to targetID: UUID) {
        let list = displayedProjects
        guard let ai = list.firstIndex(where: { $0.id == anchorID }),
              let ti = list.firstIndex(where: { $0.id == targetID }) else { return }
        let range = min(ai, ti)...max(ai, ti)
        for i in range { selectedIDs.insert(list[i].id) }
    }

    private func commitRename(id: UUID, name: String) {
        projectStore.renameProject(id: id, newName: name)
        isRenamingID = nil
    }

    private func archiveSelected() {
        let ids = selectedIDs
        withAnimation { selectedIDs = [] }
        let toArchive = projectStore.projects.filter { ids.contains($0.id) }
        for project in toArchive {
            Task { await projectStore.archiveProject(project) }
        }
    }

    private func deleteSelected() {
        let ids = selectedIDs
        withAnimation { selectedIDs = [] }
        let toDelete = projectStore.projects.filter { ids.contains($0.id) }
        for project in toDelete { projectStore.deleteProject(project) }
    }

    private func createProject(name: String, at customURL: URL?) {
        // Defer folder/project creation until PDF is selected so canceling the
        // file picker leaves no orphan on disk or in the gallery list.
        pendingProjectName = name
        pendingProjectCustomURL = customURL
        pendingProjectForPDF = nil
        isImportingPDF = true
    }

    private func finishProjectCreation(pdfURL: URL) {
        projectStore.ensureProjectsDirectoryExists()
        guard var proj = (try? projectStore.createProject(
            name: pendingProjectName,
            at: pendingProjectCustomURL,
            engine: state.selectedEngine
        )), let folderURL = proj.folderURL else {
            state.errorMessage = "Could not create project folder."
            return
        }
        let destination = folderURL.appendingPathComponent(pdfURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: pdfURL, to: destination)
        } catch {
            state.errorMessage = "Could not copy PDF into project: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: folderURL)
            projectStore.projects.removeAll { $0.id == proj.id }
            return
        }
        proj.pdfFilename = pdfURL.lastPathComponent
        try? projectStore.saveProject(proj)
        let opened = projectStore.openProject(proj)
        state.loadFromProject(opened)
    }

    // MARK: - Rubber-band

    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("gallery"))
            .onChanged { value in
                if !isDraggingSelection {
                    dragAnchor = value.startLocation
                    isDraggingSelection = true
                }
                dragCurrent = value.location
                updateRubberBandSelection()
            }
            .onEnded { _ in
                dragAnchor = nil
                dragCurrent = nil
                isDraggingSelection = false
            }
    }

    private var selectionRectangle: CGRect? {
        guard let a = dragAnchor, let b = dragCurrent else { return nil }
        let x = min(a.x, b.x), y = min(a.y, b.y)
        let w = abs(a.x - b.x), h = abs(a.y - b.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func updateRubberBandSelection() {
        guard let rect = selectionRectangle else { return }
        selectedIDs = Set(cardFrames.compactMap { id, frame in
            frame.intersects(rect) ? id : nil
        })
    }

    // Helper to embed frame reader in a card's background
    private func cardFrameReader(id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CardFramePreference.self,
                value: [id: geo.frame(in: .named("gallery"))]
            )
        }
    }
}

// MARK: - Selection actions bar

private struct ProjectSelectionActionsBar: View {
    let count: Int
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(count) selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onArchive) {
                Label("Archive", systemImage: "archivebox")
                    .font(.callout)
            }
            .buttonStyle(GalleryPillButtonStyle(color: .secondary))

            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .font(.callout)
            }
            .buttonStyle(GalleryPillButtonStyle(color: .red))

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 24)
    }
}

private struct GalleryPillButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(configuration.isPressed ? 0.2 : 0.1), in: Capsule())
            .foregroundStyle(color == .red ? .red : .primary)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Grid card

private struct ProjectGridCard: View {
    let project: Project
    let isSelected: Bool
    let isRenaming: Bool
    let isArchiving: Bool
    let onTap: (EventModifiers) -> Void
    let onDoubleTap: () -> Void
    let onDoubleTapName: () -> Void
    let onRenameCommit: (String) -> Void
    let onRenameCancel: () -> Void

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false
    @State private var renameText = ""

    private var isBackgroundRendering: Bool {
        state.backgroundRenderProjectID == project.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: selection circle + name
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .opacity(isSelected || isHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isSelected || isHovered)

                VStack(alignment: .leading, spacing: 3) {
                    if isRenaming {
                        TextField("Project name", text: $renameText)
                            .font(.callout.weight(.semibold))
                            .textFieldStyle(.plain)
                            .onSubmit { onRenameCommit(renameText) }
                            .onExitCommand { onRenameCancel() }
                            .onAppear { renameText = project.name }
                    } else {
                        Text(project.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    if isSelected { onDoubleTapName() }
                                }
                            )
                    }
                }
            }

            Spacer(minLength: 0)

            // Status tags
            HStack(spacing: 6) {
                if !project.renderedScenes.isEmpty {
                    StatusTag(icon: "checkmark.circle.fill", label: "Rendered", color: .green)
                    StatusTag(
                        icon: nil,
                        label: "\(project.renderedScenes.count) scene\(project.renderedScenes.count == 1 ? "" : "s")",
                        color: Color(nsColor: .secondaryLabelColor)
                    )
                }
            }

            // Date
            Text(project.displayDate)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Background render progress bar
            if isBackgroundRendering {
                ProgressView(value: state.generationProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(height: 130)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isBackgroundRendering ? Color.accentColor.opacity(0.5) :
                    isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.07)
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.1 : 0.05), radius: isHovered ? 6 : 3, y: 2)
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .overlay {
            if isArchiving {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleTap() }
        )
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { onTap(.command) }
        )
        .simultaneousGesture(
            TapGesture().modifiers(.shift).onEnded { onTap(.shift) }
        )
        .simultaneousGesture(
            TapGesture().onEnded { onTap([]) }
        )
    }
}

// MARK: - List row

private struct ProjectListRow: View {
    let project: Project
    let isSelected: Bool
    let isRenaming: Bool
    let isArchiving: Bool
    let onTap: (EventModifiers) -> Void
    let onDoubleTap: () -> Void
    let onDoubleTapName: () -> Void
    let onRenameCommit: (String) -> Void
    let onRenameCancel: () -> Void

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false
    @State private var renameText = ""

    private var isBackgroundRendering: Bool {
        state.backgroundRenderProjectID == project.id
    }

    var body: some View {
        HStack(spacing: 10) {
            // Selection circle
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                .opacity(isSelected || isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isSelected || isHovered)
                .frame(width: 20)

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Project name", text: $renameText)
                        .font(.callout.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { onRenameCommit(renameText) }
                        .onExitCommand { onRenameCancel() }
                        .onAppear { renameText = project.name }
                } else {
                    Text(project.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                if isSelected { onDoubleTapName() }
                            }
                        )
                }
            }

            Spacer()

            // Status tags
            HStack(spacing: 6) {
                if !project.renderedScenes.isEmpty {
                    StatusTag(icon: "checkmark.circle.fill", label: "Rendered", color: .green)
                }
            }

            // Scene count column (~70pt)
            Text(project.renderedScenes.isEmpty ? "—" : "\(project.renderedScenes.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)

            // Last opened column (~100pt)
            Text(project.displayDate)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .trailing)

            // Hover chevron
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isBackgroundRendering ? Color.accentColor.opacity(0.4) :
                    isSelected ? Color.accentColor.opacity(0.3) : .clear
                )
        )
        .overlay(alignment: .bottom) {
            if isBackgroundRendering {
                ProgressView(value: state.generationProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            }
        }
        .overlay {
            if isArchiving {
                RoundedRectangle(cornerRadius: 8).fill(.regularMaterial)
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap() })
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { onTap(.command) })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { onTap(.shift) })
        .simultaneousGesture(TapGesture().onEnded { onTap([]) })
    }
}

// MARK: - Status tag pill

private struct StatusTag: View {
    let icon: String?
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Recently deleted section

private struct RecentlyDeletedSection: View {
    @EnvironmentObject private var projectStore: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 14)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recently Deleted")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("In your Trash — recoverable this session")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.bottom, 10)

            VStack(spacing: 4) {
                ForEach(projectStore.recentlyDeleted, id: \.project.id) { record in
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(width: 20)
                        Text(record.project.name)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore") { projectStore.restoreProject(id: record.project.id) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                            .font(.callout)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

// MARK: - Archived gallery body

private struct ArchivedGalleryBody: View {
    @EnvironmentObject private var projectStore: ProjectStore

    var body: some View {
        if projectStore.archivedProjects.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "archivebox")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No archived projects")
                    .font(.title3.weight(.semibold))
                Text("Archive projects to compress them and free up space.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(projectStore.archivedProjects, id: \.project.id) { meta in
                        ArchivedProjectRow(meta: meta)
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct ArchivedProjectRow: View {
    @EnvironmentObject private var projectStore: ProjectStore
    let meta: ArchivedProjectMeta
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(meta.project.name)
                    .font(.callout.weight(.semibold))
                if !meta.project.scriptTitle.isEmpty {
                    Text(meta.project.scriptTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            Spacer()

            if !meta.project.renderedScenes.isEmpty {
                StatusTag(icon: "checkmark.circle.fill", label: "Rendered", color: .green)
            }

            Text(meta.project.displayDate)
                .font(.caption)
                .foregroundStyle(.tertiary)

            if projectStore.archivingIDs.contains(meta.project.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Unarchive") {
                    Task { await projectStore.unarchiveProject(id: meta.project.id) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.04) : .clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - New project sheet

struct NewProjectSheet: View {
    let onCreate: (String, URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var projectName = ""
    @State private var customLocationURL: URL?
    @State private var isChoosingLocation = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)
                Text("New Project")
                    .font(.title2.weight(.semibold))
                Text("Give your project a name, then choose a screenplay PDF.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Project Name")
                        .font(.callout.weight(.semibold))
                    TextField("e.g. Hamlet, The Godfather…", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Save Location")
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            if let custom = customLocationURL {
                                Text(custom.lastPathComponent).font(.callout)
                                Text(custom.deletingLastPathComponent().path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("~/Documents/Table Read/")
                                    .font(.callout).foregroundStyle(.secondary)
                                Text("Default location")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Choose…") { isChoosingLocation = true }
                            .buttonStyle(.borderless).foregroundStyle(.tint)
                    }
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                }
            }
            .padding(28)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.borderless)
                Spacer()
                Button("Create & Choose PDF…") {
                    dismiss()
                    onCreate(projectName.isEmpty ? "Untitled Project" : projectName, customLocationURL)
                }
                .buttonStyle(.borderedProminent)
                .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: 440)
        .fileImporter(isPresented: $isChoosingLocation, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { customLocationURL = url }
        }
    }
}
