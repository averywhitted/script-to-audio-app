import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            EnginesSettingsTab()
                .tabItem { Label("Engines", systemImage: "waveform") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 520)
        .environmentObject(state)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @State private var contributionState: ContributionState = .idle

    private enum ContributionState { case idle, sending, sent, failed }

    var body: some View {
        Form {
            Section {
                Toggle("Auto-open output folder in Finder after render", isOn: $state.autoOpenFinderAfterRender)
                    .help("When a render completes without errors, the output folder opens automatically in Finder.")
            } header: {
                Text("Render")
            }

            Section {
                Toggle("Notify when a scene finishes rendering", isOn: $state.notifyOnSceneComplete)
                Toggle("Notify when the full render completes", isOn: $state.notifyOnRenderComplete)
                Toggle("Notify if the render finishes with errors", isOn: $state.notifyOnRenderFailed)
            } header: {
                Text("Notifications")
            } footer: {
                Text("macOS will ask for permission the first time a notification option is enabled. Notifications appear even when Table Read is in the background.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(state.outputDirectory?.abbreviatingWithTilde ?? "Next to the PDF (default)")
                        .foregroundStyle(state.outputDirectory == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseOutputFolder() }
                    if state.outputDirectory != nil {
                        Button("Reset to Default") {
                            state.outputDirectory = nil
                            UserDefaults.standard.removeObject(forKey: "lastOutputDirectory")
                        }
                        .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Default Output Folder")
            } footer: {
                Text("Audio files are saved here unless you change it during a session.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Contribute corrections anonymously", isOn: $state.contributeCorrections)
                HStack(spacing: 8) {
                    let count = state.corrections.count
                    let unsent = state.corrections.values.filter { !$0.uploaded }.count
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(count) correction\(count == 1 ? "" : "s") stored locally")
                            .foregroundStyle(.secondary)
                        if state.contributeCorrections && unsent > 0 {
                            Text("\(unsent) not yet contributed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if state.contributeCorrections {
                        Button("Contribute…") { contributeCorrections() }
                            .disabled(state.corrections.isEmpty || contributionState == .sending)
                        if contributionState == .sent {
                            Label("Sent", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    }
                    Button("Export…") { exportCorrections() }
                        .disabled(state.corrections.isEmpty)
                    Button("Clear All") { state.corrections.removeAll() }
                        .foregroundStyle(.red)
                        .disabled(state.corrections.isEmpty)
                }
            } header: {
                Text("Parser Corrections")
            } footer: {
                Text("Corrections you make in the Review step are stored locally. When you're ready, click Contribute to send them anonymously to the developer — they help improve the parser for everyone. Nothing is sent without your action.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Default Output Folder"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            state.setOutputDirectory(url)
        }
    }

    private func contributeCorrections() {
        contributionState = .sending
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let payload = state.corrections.values.map { $0.anonymized(appVersion: version) }
        let text = payload.map { c in
            """
            Scene \(c.sceneNumber) · \(c.originalKind)\(c.originalSpeaker.map { " (\($0))" } ?? "")
            Original:  \(c.originalText)
            \(c.correctedText.map    { "Text fix:  \($0)" } ?? "")
            \(c.correctedKind.map    { "Kind fix:  \($0)" } ?? "")
            \(c.correctedSpeaker.map { "Speaker:   \($0.isEmpty ? "(narrator)" : $0)" } ?? "")
            \(c.markedAsNoise        ? "Removed:   yes" : "")
            """
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")
        EmailReporter.send(
            subject: "Parser corrections v\(version) (\(payload.count) correction\(payload.count == 1 ? "" : "s"))",
            text: text,
            labels: ["correction", "user-report"]
        ) { [self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    for key in state.corrections.keys { state.corrections[key]?.uploaded = true }
                    contributionState = .sent
                case .failure:
                    contributionState = .failed
                }
            }
        }
    }

    private func exportCorrections() {
        guard let tempURL = state.exportCorrections() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tempURL.lastPathComponent
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(at: tempURL, to: dest)
        }
    }
}

// MARK: - Engines tab

private struct EnginesSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                OpenAIKeyStatusBadge()
                HStack(alignment: .top, spacing: 12) {
                    SecureField(state.hasStoredOpenAIKey ? "Enter new key to replace…" : "Paste your key here…",
                                text: $state.openAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { state.saveOpenAIAPIKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.openAIAPIKey.isEmpty)
                    if state.hasStoredOpenAIKey {
                        Button("Clear") { state.saveOpenAIAPIKey() }
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("OpenAI TTS")
            } footer: {
                Text("Your key is stored in Keychain and never sent anywhere except OpenAI's API. Type a new key and click Save to update, or Clear to remove it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(EngineKind.allCases.filter { $0 != .openAI && $0 != .macOS }) { engine in
                    EngineManagementRow(engine: engine)
                }
            } header: {
                Text("Local Engines")
            } footer: {
                Text("macOS Voices is always available with no setup required.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - OpenAI key status badge

private struct OpenAIKeyStatusBadge: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        switch state.openAIKeyStatus {
        case .idle:
            if state.hasStoredOpenAIKey {
                Label("API key saved in Keychain", systemImage: "key.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .checking:
            Label("Checking key…", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .valid:
            Label("API key verified — OpenAI TTS is active", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .invalid(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

private struct EngineManagementRow: View {
    @EnvironmentObject private var state: AppState
    let engine: EngineKind

    private var isInstalled: Bool { state.installedEngines.contains(engine) }
    private var isInstalling: Bool { state.installingEngine == engine }
    private var isUninstalling: Bool { state.uninstallingEngine == engine }
    private var isBusy: Bool { isInstalling || isUninstalling || state.installingEngine != nil || state.uninstallingEngine != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.title).font(.callout)
                Text(engine.subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isInstalling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption).foregroundStyle(.secondary)
                }
            } else if isUninstalling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Removing…").font(.caption).foregroundStyle(.secondary)
                }
            } else if !engine.isSupported {
                Text("Coming soon").font(.caption).foregroundStyle(.tertiary)
            } else if isInstalled {
                HStack(spacing: 8) {
                    if let status = state.engineStatuses[engine] {
                        Text(status.sizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Uninstall") { state.uninstallEngine(engine) }
                        .foregroundStyle(.red)
                        .disabled(isBusy)
                }
            } else {
                Button("Install") { state.startEngineInstall(engine) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - About tab

private struct AboutTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private let licenseText = """
        Table Read — Personal Use License
        Copyright © 2025 Avery Whitted. All rights reserved.

        Permission is granted to any individual to use this software for personal, non-commercial purposes, subject to the following conditions:

        1. NON-COMMERCIAL. You may not sell, license, sublicense, rent, or otherwise use this software or any portion of it for commercial gain or as part of a commercial product or service.

        2. NO MODIFICATIONS WITHOUT PERMISSION. You may not modify, adapt, translate, or create derivative works based on this software without prior written permission from the copyright holder.

        3. NO REDISTRIBUTION. You may not redistribute this software, in original or modified form, without prior written permission from the copyright holder.

        4. ATTRIBUTION. Any permitted use or distribution must retain this notice and the copyright statement above.

        5. SOURCE AVAILABLE. The source code is made available for inspection and personal study only. Viewing the source does not grant any rights beyond those stated here.

        THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED. IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY ARISING FROM USE OF THIS SOFTWARE.

        To request permission for uses not covered here, contact: averywhitted.com
        """

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 10) {
                // Use the real app icon so About, dock, and notifications all match.
                // Falls back to the SF Symbol when running un-bundled via swift run.
                if let icon = NSImage(named: NSImage.applicationIconName),
                   icon.size.width > 32 {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 17))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                } else {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(.tint)
                }

                Text("Table Read")
                    .font(.title.weight(.semibold))

                Text("Version \(appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("© 2025 Avery Whitted. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(licenseText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 130)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                HStack(spacing: 12) {
                    Button("View License on GitHub") {
                        if let url = URL(string: "https://github.com/averywhitted/table-read/blob/main/LICENSE") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Donate on Buy Me a Coffee") {
                        if let url = URL(string: "https://buymeacoffee.com/averywhitted") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 0)
    }
}
