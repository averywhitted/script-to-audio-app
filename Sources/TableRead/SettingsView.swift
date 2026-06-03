import SwiftUI
#if os(macOS)
import AppKit
#endif

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
                HStack {
                    let count = state.corrections.count
                    Text("\(count) correction\(count == 1 ? "" : "s") stored locally")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Export…") { exportCorrections() }
                        .disabled(state.corrections.isEmpty)
                    Button("Clear All") { state.corrections.removeAll() }
                        .foregroundStyle(.red)
                        .disabled(state.corrections.isEmpty)
                }
            } header: {
                Text("Parser Corrections")
            } footer: {
                Text("When enabled, corrections you make in the Review step are flagged for contribution. Export saves them as JSON you can share to help improve the parser for everyone. Nothing is sent automatically — you stay in control.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseOutputFolder() {
        #if os(macOS)
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
        #endif
    }

    private func exportCorrections() {
        #if os(macOS)
        guard let tempURL = state.exportCorrections() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tempURL.lastPathComponent
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(at: tempURL, to: dest)
        }
        #endif
    }
}

// MARK: - Engines tab

private struct EnginesSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                if state.hasStoredOpenAIKey {
                    Label("API key saved in Keychain — OpenAI TTS is active.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                }
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

                Text("By Avery Whitted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Divider()

            VStack(spacing: 10) {
                Text("Table Read is free for personal use. Not for resale or commercial redistribution.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                HStack(spacing: 12) {
                    Button("Donate on Buy Me a Coffee") {
                        // placeholder — fill in real URL when ready
                        if let url = URL(string: "https://buymeacoffee.com") {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #else
                            UIApplication.shared.open(url)
                            #endif
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}
