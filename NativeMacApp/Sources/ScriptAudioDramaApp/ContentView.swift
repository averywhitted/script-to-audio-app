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
                HeaderBar(openImporter: { isImporting = true })
                Divider()
                StepContent(openImporter: { isImporting = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBar()
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
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.step },
            set: { state.step = $0 }
        )) {
            Section("Workflow") {
                ForEach(WorkflowStep.allCases) { step in
                    Label(step.rawValue, systemImage: symbol(for: step))
                        .tag(step)
                }
            }
        }
    }

    private func symbol(for step: WorkflowStep) -> String {
        switch step {
        case .importScript: "square.and.arrow.down"
        case .review: "doc.text.magnifyingglass"
        case .cast: "person.2.wave.2"
        case .generate: "waveform.badge.play"
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject private var state: AppState
    var openImporter: () -> Void

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

            Button {
                openImporter()
            } label: {
                Label("Open PDF", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.bar)
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
