import SwiftUI
import AppKit

extension Notification.Name {
    static let showOnboarding  = Notification.Name("TableRead.showOnboarding")
    static let showBugReport   = Notification.Name("TableRead.showBugReport")
}

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var isImporting = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var showBugReport  = false

    var body: some View {
        VStack(spacing: 0) {
            // The step bar has NO animation — it always snaps to the correct
            // state immediately. Animation lives on the ZStack below.
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
            // Animation is attached here (on the content ZStack) rather than
            // inside goTo()'s withAnimation, so the step bar is never caught
            // in a mid-animation state.
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: state.step)
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
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                hasSeenOnboarding = true
                showOnboarding = false
            }
        }
        .onAppear {
            if !hasSeenOnboarding {
                showOnboarding = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showOnboarding = true
        }
        .sheet(isPresented: $showBugReport) {
            BugReportSheet(isPresented: $showBugReport)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBugReport)) { _ in
            showBugReport = true
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

            // Right anchor: beta badge + bug report button + settings gear
            HStack(spacing: 8) {
                Text("BETA")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())

                Button {
                    NotificationCenter.default.post(name: .showBugReport, object: nil)
                } label: {
                    Label("Report a Bug", systemImage: "exclamationmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Report a bug (⌘⇧B)")

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

// MARK: - Onboarding sheet

struct OnboardingView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 40)

                Text("Welcome to Table Read")
                    .font(.largeTitle.weight(.bold))

                Text("Turn any screenplay PDF into a full cast audio drama —\neach character voiced differently, scene by scene.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 32)

            Divider()

            // Four-step explanation
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    OnboardingStep(
                        number: 1,
                        icon: "doc.badge.plus",
                        title: "Import a Script PDF",
                        description: "Click \"Choose PDF\" or drag a file in. Table Read parses the characters, dialog, and scene structure automatically."
                    )
                    OnboardingStep(
                        number: 2,
                        icon: "text.magnifyingglass",
                        title: "Review the Parse",
                        description: "Inspect every line. Fix any mis-attributed dialog, rename speakers, or mark lines as noise. Your corrections are saved and re-applied next time."
                    )
                    OnboardingStep(
                        number: 3,
                        icon: "person.wave.2",
                        title: "Cast Your Voices",
                        description: "Assign a macOS system voice to each character. Upgrade any role to Kokoro (local, free) or OpenAI (natural, API key required) in Settings."
                    )
                    OnboardingStep(
                        number: 4,
                        icon: "play.circle",
                        title: "Generate Audio",
                        description: "Select which scenes to render. Each scene becomes a standalone .m4a file ready for playback or editing. Pause and resume any time."
                    )

                    Divider().padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Tips", systemImage: "lightbulb")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("• Works best with standard US play and screenplay formats.")
                        Text("• For higher-quality voices, install Kokoro from Settings → Engines.")
                        Text("• Corrections you make are stored locally and re-applied whenever you re-import the same PDF.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 28)
            }

            Divider()

            // Footer button
            HStack {
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Text("Get Started")
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 20)
        }
        .frame(width: 560, height: 620)
    }
}

private struct OnboardingStep: View {
    var number: Int
    var icon: String
    var title: String
    var description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(number).")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Bug report sheet

struct BugReportSheet: View {
    @Binding var isPresented: Bool
    @State private var whatHappened = ""
    @State private var steps = ""
    @State private var submitState: SubmitState = .idle

    private enum SubmitState: Equatable { case idle, sending, sent, failed(String) }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (build \(b))"
    }
    private var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.red.opacity(0.7))
                    .padding(.top, 32)
                Text("Report a Bug")
                    .font(.title2.weight(.semibold))
                Text("Reports go directly to the developer. No account required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Auto-filled system info
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            infoRow(label: "App version", value: appVersion)
                            infoRow(label: "macOS",       value: osVersion)
                        }
                    } label: {
                        Label("System Info", systemImage: "info.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("What happened?")
                            .font(.callout.weight(.semibold))
                        TextEditor(text: $whatHappened)
                            .font(.callout)
                            .frame(minHeight: 80)
                            .padding(6)
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.12))
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Steps to reproduce")
                            .font(.callout.weight(.semibold))
                        Text("Optional — helps a lot if you can describe what you did before it happened.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $steps)
                            .font(.callout)
                            .frame(minHeight: 60)
                            .padding(6)
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.12))
                            )
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer
            HStack {
                if case .failed(let msg) = submitState {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if case .sent = submitState {
                    Label("Sent! Thank you.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)

                Button {
                    submit()
                } label: {
                    if case .sending = submitState {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send Report")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(whatHappened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || submitState == .sending || submitState == .sent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 520)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    private func submit() {
        submitState = .sending
        let text = """
        App version: \(appVersion)
        macOS: \(osVersion)

        What happened:
        \(whatHappened)

        Steps to reproduce:
        \(steps.isEmpty ? "(not provided)" : steps)
        """
        EmailReporter.send(subject: "Table Read Bug Report \(appVersion)", text: text) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    submitState = .sent
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isPresented = false }
                case .failure(let error):
                    submitState = .failed(error.localizedDescription)
                }
            }
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
