import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            WorkflowStepBar()
            Divider()
            ZStack {
                if state.step == .importScript {
                    ImportView(openImporter: { isImporting = true })
                        .transition(stepTransition)
                }
                if state.step == .review {
                    ReviewView()
                        .transition(stepTransition)
                }
                if state.step == .cast {
                    CastView()
                        .transition(stepTransition)
                }
                if state.step == .generate {
                    GenerateView()
                        .transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay {
                if state.isWorking && !state.isGenerating {
                    ProcessingOverlay()
                }
            }
        }
        .background(FirstMouseAcceptingView())
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

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: state.navigatingForward
                ? .move(edge: .trailing).combined(with: .opacity)
                : .move(edge: .leading).combined(with: .opacity),
            removal: state.navigatingForward
                ? .move(edge: .leading).combined(with: .opacity)
                : .move(edge: .trailing).combined(with: .opacity)
        )
    }
}

// MARK: - Horizontal step bar

private struct WorkflowStepBar: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            // Script context (left anchor) — only shown once a script is loaded
            VStack(alignment: .leading, spacing: 1) {
                if let title = state.script?.title {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                if let pdf = state.selectedPDF {
                    Text(pdf.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minWidth: 140, alignment: .leading)

            Spacer()

            // Step pills
            HStack(spacing: 4) {
                ForEach(Array(WorkflowStep.allCases.enumerated()), id: \.element.id) { idx, step in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)
                    }
                    StepPill(step: step)
                }
            }

            Spacer()

            // Right anchor: engine badge (only after import) + settings gear
            HStack(spacing: 10) {
                if state.selectedPDF != nil {
                    Label(state.selectedEngine.title, systemImage: state.selectedEngine.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button { openSettings() } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .frame(minWidth: 140, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(.bar)
    }
}

private struct StepPill: View {
    @EnvironmentObject private var state: AppState
    var step: WorkflowStep

    private var steps: [WorkflowStep] { WorkflowStep.allCases }
    private var currentIdx: Int { steps.firstIndex(of: state.step) ?? 0 }
    private var stepIdx: Int    { steps.firstIndex(of: step) ?? 0 }

    private var isCurrent: Bool { state.step == step }
    private var isPast: Bool    { stepIdx < currentIdx }
    private var isEnabled: Bool { state.canNavigate(to: step) }

    var body: some View {
        Button { state.goTo(step) } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(badgeFill)
                        .frame(width: 18, height: 18)
                    if isPast {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text("\(step.number)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(isCurrent ? .white : .secondary)
                    }
                }
                Text(step.rawValue)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : (isEnabled ? .secondary : .tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear,
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var badgeFill: Color {
        if isCurrent { return .accentColor }
        if isPast    { return .accentColor.opacity(0.18) }
        return .secondary.opacity(0.15)
    }
}

// MARK: - Processing overlay

private struct ProcessingOverlay: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
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

// MARK: - First-mouse fix
// Makes buttons respond on the first click even when the window isn't the key window.

private struct FirstMouseAcceptingView: NSViewRepresentable {
    func makeNSView(context: Context) -> _FirstMouseNSView { _FirstMouseNSView() }
    func updateNSView(_ nsView: _FirstMouseNSView, context: Context) {}
}

private class _FirstMouseNSView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
