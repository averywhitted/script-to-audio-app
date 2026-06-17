import SwiftUI
import AppKit

struct ProjectGalleryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var isShowingNewProjectSheet = false
    @State private var isImportingPDF = false
    @State private var pendingProjectForPDF: Project?
    @State private var recentlyDeletedProject: Project?
    @State private var showUndoToast = false

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            galleryToolbar
            Divider()
            if projectStore.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(projectStore.projects) { project in
                            ProjectCard(project: project) {
                                openProject(project)
                            } onDelete: {
                                softDelete(project)
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showUndoToast, let deleted = recentlyDeletedProject {
                undoToast(project: deleted)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .animation(.spring(response: 0.3), value: showUndoToast)
        .sheet(isPresented: $isShowingNewProjectSheet) {
            NewProjectSheet { name, customURL in
                createProject(name: name, at: customURL)
            }
        }
        .fileImporter(
            isPresented: $isImportingPDF,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                finishProjectCreation(project: pendingProjectForPDF, pdfURL: url)
            } else {
                // User cancelled — clean up the empty project
                if let project = pendingProjectForPDF {
                    projectStore.deleteProject(project)
                    projectStore.confirmDeletion()
                }
                pendingProjectForPDF = nil
            }
        }
        .onAppear {
            projectStore.loadAllProjects()
        }
    }

    // MARK: - Toolbar

    private var galleryToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Table Read")
                    .font(.title2.weight(.bold))
                Text("Your Projects")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isShowingNewProjectSheet = true
            } label: {
                Label("New Project", systemImage: "plus")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
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
            Button("New Project") {
                isShowingNewProjectSheet = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Actions

    private func openProject(_ project: Project) {
        let opened = projectStore.openProject(project)
        state.loadFromProject(opened)
    }

    private func createProject(name: String, at customURL: URL?) {
        projectStore.ensureProjectsDirectoryExists()
        guard let project = try? projectStore.createProject(name: name, at: customURL) else { return }
        pendingProjectForPDF = project
        isImportingPDF = true
    }

    private func finishProjectCreation(project: Project?, pdfURL: URL) {
        guard var proj = project, let folderURL = proj.folderURL else { return }
        let destination = folderURL.appendingPathComponent(pdfURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: pdfURL, to: destination)
        } catch {
            state.errorMessage = "Could not copy PDF into project: \(error.localizedDescription)"
            projectStore.deleteProject(proj)
            projectStore.confirmDeletion()
            pendingProjectForPDF = nil
            return
        }
        proj.pdfFilename = pdfURL.lastPathComponent
        try? projectStore.saveProject(proj)
        pendingProjectForPDF = nil
        let opened = projectStore.openProject(proj)
        state.loadFromProject(opened)
    }

    private func softDelete(_ project: Project) {
        recentlyDeletedProject = project
        projectStore.deleteProject(project)
        showUndoToast = true
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation { showUndoToast = false }
        }
    }

    // MARK: - Undo toast

    private func undoToast(project: Project) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("\u{201C}\(project.name)\u{201D} will be deleted when you quit.")
                .font(.callout)
            Spacer()
            Button("Undo") {
                projectStore.recoverProject(id: project.id)
                withAnimation { showUndoToast = false }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6)
        .padding(.horizontal, 24)
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    let project: Project
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                // Icon / thumbnail area
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(height: 100)
                    .overlay {
                        Image(systemName: "film.stack")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Color.accentColor.opacity(0.6))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if !project.scriptTitle.isEmpty {
                        Text(project.scriptTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text(project.displayDate)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if !project.renderedScenes.isEmpty {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("\(project.renderedScenes.count) rendered")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Show in Finder") {
                if let url = project.folderURL {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - New project sheet

struct NewProjectSheet: View {
    let onCreate: (String, URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var projectName = ""
    @State private var useCustomLocation = false
    @State private var customLocationURL: URL?
    @State private var isChoosingLocation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
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
                                Text(custom.lastPathComponent)
                                    .font(.callout)
                                Text(custom.deletingLastPathComponent().path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("~/Documents/Table Read/")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("Default location")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Choose…") { isChoosingLocation = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                    }
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                }
            }
            .padding(28)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
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
        .fileImporter(
            isPresented: $isChoosingLocation,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                customLocationURL = url
            }
        }
    }
}
