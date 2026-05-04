import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var isImporting = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            VStack(spacing: 0) {
                HeaderBar()
                Divider()
                StepContent(openImporter: { isImporting = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBar()
            }
            .overlay {
                if state.isWorking && !state.isGenerating {
                    ProcessingOverlay()
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.importPDF(url)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert(item: $state.pendingDownload) { prompt in
            Alert(
                title: Text("Download \(prompt.engine.title)?"),
                message: Text("This engine needs local files before it can be used. The app will download and install what it needs here, then continue."),
                primaryButton: .default(Text("Download")) {
                    state.downloadPendingEngine()
                },
                secondaryButton: .cancel {
                    state.selectedEngine = .macOS
                }
            )
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.step },
            set: { state.goTo($0) }
        )) {
            Section("Workflow") {
                ForEach(WorkflowStep.allCases) { step in
                    StepSidebarRow(step: step, isEnabled: state.canNavigate(to: step))
                        .tag(step)
                }
            }
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.script?.title ?? "Script to Audio Drama")
                    .font(.title3.weight(.semibold))
                Text(state.selectedPDF?.lastPathComponent ?? "No script selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(state.selectedEngine.title, systemImage: state.selectedEngine.symbol)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct StepSidebarRow: View {
    var step: WorkflowStep
    var isEnabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(step.number)")
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(isEnabled ? Color.accentColor : Color.secondary.opacity(0.35), in: Circle())
            Text(step.rawValue)
                .foregroundStyle(isEnabled ? .primary : .secondary)
            Spacer()
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct ProcessingOverlay: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(state.status)
                    .font(.headline)
                Text("This can take a moment for large PDFs or voice downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 18)
        }
    }
}

private struct StepContent: View {
    @EnvironmentObject private var state: AppState
    var openImporter: () -> Void

    var body: some View {
        switch state.step {
        case .importScript:
            ImportView(openImporter: openImporter)
        case .review:
            ReviewView()
        case .cast:
            CastView()
        case .generate:
            GenerateView()
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack {
            if state.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(state.selectedEngine.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
